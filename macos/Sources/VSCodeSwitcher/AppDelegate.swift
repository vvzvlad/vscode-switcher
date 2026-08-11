import AppKit
import Combine
import Foundation

/// Menu bar agent: owns the model cache, the edge trigger and the panel, and
/// hosts the status item menu.
///
/// The app is an `LSUIElement`, so there is no dock icon, no main menu and no
/// window on launch; everything is driven from the status item and the pointer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let config: Config
    private let store: SnapshotStore
    private let trigger: EdgeTrigger
    private let panel: PanelController
    private var statusItem: NSStatusItem?
    private var screenObserver: (any NSObjectProtocol)?
    private var cancellables = Set<AnyCancellable>()

    /// Remembers that the one-shot system prompt has already been shown, so
    /// later requests go to the settings pane instead of doing nothing.
    private static let promptShownKey = "accessibilityPromptShown"

    init(config: Config) {
        self.config = config
        store = SnapshotStore(config: config)
        trigger = EdgeTrigger(config: config)
        panel = PanelController(config: config, store: store)
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()

        trigger.onEdgeDwell = { [weak self] screen in
            guard let self, !self.panel.isVisible else { return }
            self.panel.show(on: screen)
        }
        trigger.onPointerLeft = { [weak self] in
            self?.panel.hide()
        }
        panel.onVisibilityChanged = { [weak self] visible, frame in
            guard let self else { return }
            if visible {
                self.trigger.panelDidShow(frame: frame)
            } else {
                self.trigger.panelDidHide()
            }
        }
        panel.onGrantAccessibility = { [weak self] in self?.requestAccessibility() }
        observeScreenParameters()
        observeAccessibilityGrant()

        store.start()
        trigger.start()

        if !VSCodeWindows.isAccessibilityTrusted() {
            // The system prompt is non-blocking and is what registers the app in
            // the Accessibility list. No alert: the panel must never steal focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.promptForAccessibilityIfNeeded()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        trigger.stop()
        store.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    /// A resolution change, a display being plugged in or the Dock moving all
    /// invalidate the panel's frame — and the edge trigger's copy of it, which
    /// is what decides when the panel auto-hides. Re-showing on the screen under
    /// the pointer recomputes both.
    private func observeScreenParameters() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                guard let screen = EdgeTrigger.screen(containing: NSEvent.mouseLocation) else { return }
                self.panel.show(on: screen)
            }
        }
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusItemImage()
        item.button?.toolTip = "VSCode Switcher"

        let menu = NSMenu()
        menu.addItem(menuItem("Показать панель", #selector(showPanel), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("Открыть конфиг", #selector(openConfig), key: ""))
        menu.addItem(menuItem("Установить хуки", #selector(installHooks), key: ""))
        menu.addItem(menuItem("Проверить разрешения", #selector(checkPermissions), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("Выход", #selector(quit), key: "q"))
        item.menu = menu
        statusItem = item
    }

    /// The status item glyph: `MenuBarIconTemplate.png` / `@2x` from the bundle.
    ///
    /// The `Template` suffix already makes AppKit tint the image for the current
    /// menu bar appearance, but `isTemplate` is set explicitly so a renamed file
    /// cannot silently turn it into a flat black blob. The binary can also be
    /// run straight out of `.build` with no bundle around it, hence the SF
    /// Symbol fallback.
    private static func statusItemImage() -> NSImage? {
        let image = NSImage(named: "MenuBarIconTemplate")
            ?? NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "VSCode Switcher")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = "VSCode Switcher"
        return image
    }

    private func menuItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Menu actions

    @objc private func showPanel() {
        // Showing an already visible panel would clear a search the user is in
        // the middle of typing.
        guard !panel.isVisible else { return }
        let screen = EdgeTrigger.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        guard let screen else { return }
        panel.show(on: screen)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Opens `~/.config/vscode-switcher/config.json`, writing the current
    /// effective values first when the file does not exist yet. The data layer
    /// deliberately never creates the file on its own, so this is the one place
    /// where an explicit user action may.
    @objc private func openConfig() {
        let url = Config.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let contents: [String: Any] = [
                "projectRoots": config.projectRoots,
                "scanDepth": config.scanDepth,
                "dwellMilliseconds": config.dwellMilliseconds,
                "panelWidth": config.panelWidth,
                "panelHeightFraction": config.panelHeightFraction,
                "subagentActiveSeconds": config.subagentActiveSeconds,
                "transcriptTailBytes": config.transcriptTailBytes,
                "editorBundleID": config.editorBundleID
            ]
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: contents,
                                                      options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url, options: .atomic)
            } catch {
                presentAlert(title: "Не удалось создать конфиг",
                             message: "\(url.path)\n\n\(error.localizedDescription)")
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkPermissions() {
        guard VSCodeWindows.isAccessibilityTrusted() else {
            requestAccessibility()
            return
        }
        // Enumerating the windows is four Accessibility reads per window with a
        // one second timeout each, so it never runs on the main thread: a hung
        // extension host would freeze the whole UI — and the 60 Hz edge trigger
        // with it — for seconds. §6 has no exception for menu actions.
        let bundleID = config.editorBundleID
        DispatchQueue.global(qos: .userInitiated).async {
            let count = VSCodeWindows.listWindows(bundleID: bundleID).count
            DispatchQueue.main.async { [weak self] in
                self?.presentAlert(title: "Accessibility выдан",
                                   message: "Видно окон \(bundleID): \(count).")
            }
        }
    }

    /// Launch-time permission handling: the system prompt, and nothing else.
    ///
    /// `AXIsProcessTrustedWithOptions` shows its dialog asynchronously and
    /// returns the *current* (still false) status immediately, so there is no
    /// point waiting for an answer. macOS shows it only once per bundle, so a
    /// second call is a harmless no-op — which is exactly what is wanted here.
    /// Opening System Settings instead, as this used to do once the flag was
    /// set, meant that an app in the login items popped a settings window and
    /// stole the focus at every login where the permission had gone stale, with
    /// the user having done nothing at all. Going to the settings pane is now
    /// reserved for an explicit click — see `requestAccessibility`.
    private func promptForAccessibilityIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.promptShownKey) else { return }
        defaults.set(true, forKey: Self.promptShownKey)
        VSCodeWindows.requestAccessibilityPermission()
        store.refresh()
    }

    /// The user asked for the permission — the banner in the panel or the menu
    /// item. The system prompt is always attempted, and the settings pane opens
    /// on top of it once the prompt is known to have been used up.
    ///
    /// The prompt is asked for unconditionally on purpose. It is a no-op while a
    /// TCC entry exists, and the remembered flag is not a reliable statement
    /// about whether one does: `tccutil reset` — the way to clear the dead entry
    /// an ad-hoc signature leaves behind after a rebuild — removes the entry
    /// without telling the app, and a flag left over from months ago would then
    /// send the user to a settings pane that no longer lists the app at all.
    private func requestAccessibility() {
        let defaults = UserDefaults.standard
        let promptUsed = defaults.bool(forKey: Self.promptShownKey)
        defaults.set(true, forKey: Self.promptShownKey)
        VSCodeWindows.requestAccessibilityPermission()
        if promptUsed,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // `accessibilityTrusted` is recomputed inside every snapshot, so one
        // extra rebuild makes the banner disappear as soon as access is granted.
        store.refresh()
    }

    /// Forgets the remembered prompt as soon as the permission is actually
    /// there.
    ///
    /// Without this the flag is set once and never cleared, so the app is stuck
    /// on "open the settings pane" forever — including after `tccutil reset`,
    /// which wipes the TCC entry and makes the one-shot prompt work again. The
    /// snapshot recomputes the trust flag every second, so this catches the
    /// grant whenever it happens.
    private func observeAccessibilityGrant() {
        store.$snapshot
            .map(\.accessibilityTrusted)
            .removeDuplicates()
            .sink { trusted in
                guard trusted else { return }
                UserDefaults.standard.removeObject(forKey: AppDelegate.promptShownKey)
            }
            .store(in: &cancellables)
    }

    @objc private func installHooks() {
        guard let script = Self.installHooksScriptURL() else {
            presentAlert(title: "Скрипт не найден",
                         message: "install-hooks.sh нет ни в бандле, ни рядом с бинарником. "
                                + "Запустите scripts/install-hooks.sh из репозитория вручную.")
            return
        }
        // The script shells out to jq and rewrites ~/.claude/settings.json, so
        // it runs off the main thread and reports back with its own output.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.run(script: script)
            DispatchQueue.main.async { [weak self] in
                self?.presentAlert(title: result.status == 0 ? "Хуки установлены" : "Установка не удалась",
                                   message: result.output.isEmpty ? "Код возврата \(result.status)." : result.output)
            }
        }
    }

    // MARK: - Hook installer

    /// Finds `install-hooks.sh`, preferring a source checkout over the copy
    /// inside the bundle.
    ///
    /// The script writes absolute paths into `~/.claude/settings.json`, so the
    /// copy it is run from is the copy the hooks will point at forever after. A
    /// checkout outlives `make clean`; a bundle sitting inside that checkout
    /// does not.
    static func installHooksScriptURL() -> URL? {
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            var directory = executable.deletingLastPathComponent()
            for _ in 0..<6 {
                candidates.append(directory.appendingPathComponent("scripts/install-hooks.sh"))
                directory = directory.deletingLastPathComponent()
            }
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("scripts/install-hooks.sh"))
        }
        return candidates.first { candidate in
            let root = candidate.deletingLastPathComponent().deletingLastPathComponent()
            return FileManager.default.isReadableFile(atPath: candidate.path)
                && FileManager.default.fileExists(atPath: root.appendingPathComponent("hooks").path)
        }
    }

    nonisolated private static func run(script: URL) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]

        // A GUI app inherits a bare PATH, and the script needs jq — which lives
        // in a Homebrew prefix on this kind of machine.
        var environment = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin"]
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (extra + [path]).joined(separator: ":")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Alerts

    /// Only ever used for actions the user started from the status item menu,
    /// where the panel is already down and a modal is harmless.
    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
