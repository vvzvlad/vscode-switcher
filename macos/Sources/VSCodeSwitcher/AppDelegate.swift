import AppKit
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

        store.start()
        trigger.start()

        if !VSCodeWindows.isAccessibilityTrusted() {
            // The system prompt is non-blocking and is what registers the app in
            // the Accessibility list. No alert: the panel must never steal focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.requestAccessibility()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        trigger.stop()
        store.stop()
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "VSCode Switcher")
        image?.isTemplate = true
        item.button?.image = image
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
        let windows = VSCodeWindows.listWindows(bundleID: config.editorBundleID)
        presentAlert(title: "Accessibility выдан",
                     message: "Видно окон \(config.editorBundleID): \(windows.count).")
    }

    /// Asks for the Accessibility permission without ever blocking the UI.
    ///
    /// `AXIsProcessTrustedWithOptions` shows its dialog asynchronously and
    /// returns the *current* (still false) status immediately, so there is no
    /// point waiting for an answer. macOS also shows that dialog only once per
    /// bundle, and an ad-hoc signed build loses its granted entry on every
    /// rebuild — which leaves a checked but dead entry in the list. Hence the
    /// remembered flag: the first attempt prompts, every later one goes straight
    /// to the settings pane where the user can re-tick the box.
    private func requestAccessibility() {
        let promptShownKey = "accessibilityPromptShown"
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: promptShownKey) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else {
            defaults.set(true, forKey: promptShownKey)
            VSCodeWindows.requestAccessibilityPermission()
        }
        // `accessibilityTrusted` is recomputed inside every snapshot, so one
        // extra rebuild makes the banner disappear as soon as access is granted.
        store.refresh()
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
