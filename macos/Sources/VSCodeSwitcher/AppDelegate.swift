import AppKit
import Combine
import Foundation
import SwiftUI

/// The press that took the usage popover down, kept only long enough to tell it
/// apart from the next press.
///
/// A `.transient` popover is dismissed on the mouse-down, while the status
/// item's action arrives on the mouse-up, so `isShown` is false either way and
/// cannot tell the dismissing press from a new one. Two rules decide instead:
///
/// - The mark is set only if a mouse button was still down when the popover
///   closed (`NSEvent.pressedMouseButtons`, the hardware state; not
///   `NSApp.currentEvent`, which goes stale). Esc and programmatic
///   `performClose` arm nothing.
/// - The mark is spent by the first click that asks, whatever the answer, so a
///   press whose second half never arrives costs at most one click.
///
/// With synthesised events the dismissing left press never reaches the action
/// at all, so the window effectively bounds the pause before the next click; it
/// is kept narrow (0.25 s) so an ordinary double click is rarely swallowed. The
/// guard stays for the live HID path, which cannot be reproduced in a test.
struct PopoverDismissal: Equatable {

    /// How long after such a close a click is still taken to be the second half
    /// of the press that caused it.
    static let suppressionWindow: TimeInterval = 0.25

    /// When the popover was taken down by a press still in flight, or `nil`:
    /// either the last close was not one of those, or its click has come and
    /// gone.
    private var closedAt: Date?

    /// The popover went away. `midPress` is whether a mouse button was still
    /// down at that moment — see above.
    mutating func popoverClosed(at moment: Date, midPress: Bool) {
        closedAt = midPress ? moment : nil
    }

    /// A click on the status item arrived: is it the second half of the press
    /// that dismissed the popover, rather than a new request to open it?
    ///
    /// Answering forgets that press, whichever way the answer goes.
    mutating func shouldIgnoreClick(at moment: Date) -> Bool {
        guard let closedAt else { return false }
        self.closedAt = nil
        return moment.timeIntervalSince(closedAt) < Self.suppressionWindow
    }
}

/// Menu bar agent: owns the model cache, the edge trigger and the panel, and
/// hosts the status item menu.
///
/// The app is an `LSUIElement`, so there is no dock icon, no main menu and no
/// window on launch; everything is driven from the status item and the pointer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let config: Config
    private let store: SnapshotStore
    /// Token spend from the gateway. It lives beside the snapshot store rather
    /// than inside it: one is disk-bound and runs every second, the other talks
    /// to the network once a minute. They meet in `UsageCache`.
    private let usage: UsageStore
    /// Utilisation over time for the popover's chart, fetched only while the
    /// popover is open. `usage` above also reads the same histories every ten
    /// minutes for the burn ratio (`UsageClient.history`).
    private let history: UsageHistoryModel
    private let trigger: EdgeTrigger
    private let panel: PanelController
    private var statusItem: NSStatusItem?
    /// The left click's answer. Built once and reused, so reopening it does not
    /// rebuild the SwiftUI tree.
    private let popover = NSPopover()
    /// The press that last took the popover down, if it was a press. See
    /// `PopoverDismissal`.
    private var dismissal = PopoverDismissal()
    /// The menu the right click puts up. Attached to the status item only for
    /// the instant it is being shown — see `showStatusMenu`.
    private var statusMenu: NSMenu?
    private var screenObserver: (any NSObjectProtocol)?
    /// The picture is not a template (`MenuBarIcon`), so a light/dark change
    /// requires a redraw.
    private var appearanceObserver: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()

    /// Remembers that the one-shot system prompt has already been shown, so
    /// later requests go to the settings pane instead of doing nothing.
    private static let promptShownKey = "accessibilityPromptShown"

    init(config: Config) {
        self.config = config
        let usageCache = UsageCache()
        store = SnapshotStore(config: config, usage: usageCache)
        usage = UsageStore(config: config, cache: usageCache)
        history = UsageHistoryModel(config: config)
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
        panel.onPanelMoved = { [weak self] frame in self?.trigger.panelDidMove(frame: frame) }
        panel.onGrantAccessibility = { [weak self] in self?.requestAccessibility() }
        observeScreenParameters()
        observeAppearance()
        observeAccessibilityGrant()

        store.start()
        usage.start()
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
        usage.stop()
        history.close()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        appearanceObserver?.invalidate()
        appearanceObserver = nil
    }

    /// A resolution change, a display being plugged in or the Dock moving all
    /// invalidate the panel's frame — and the edge trigger's copy of it, which
    /// is what decides when the panel auto-hides. Re-showing on the screen under
    /// the pointer recomputes both; the trigger learns about it through
    /// `panelDidMove`, which refreshes the frame without disarming an auto-hide
    /// that may already be counting down.
    ///
    /// The status item's picture is redrawn too: it is a bitmap rasterised at
    /// the backing scale in force when drawn (`MenuBarIcon.image`), and a
    /// display with a different scale invalidates it. This part is untested on
    /// a multi-display setup.
    private func observeScreenParameters() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.redrawStatusItemImage()
                guard self.panel.isVisible else { return }
                guard let screen = EdgeTrigger.screen(containing: NSEvent.mouseLocation) else { return }
                self.panel.show(on: screen)
            }
        }
    }

    /// The menu bar switching between light and dark also invalidates the
    /// picture: it is not a template, so it is drawn against one appearance
    /// (`MenuBarIcon.image`), and `observeUsage` does not fire because the
    /// figure has not changed.
    ///
    /// The button's own appearance is observed, not `NSApp`'s: the menu bar
    /// follows the wallpaper, so the button can be `VibrantDark` while the app
    /// is `aqua` (`MenuBarIcon.appearance(ofButton:system:)`). The button's
    /// `effectiveAppearance` is KVO-compliant (measured). With no button there
    /// is nothing to redraw, so there is no fallback to `NSApp`.
    private func observeAppearance() {
        guard let button = statusItem?.button else { return }
        appearanceObserver = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.redrawStatusItemImage() }
        }
    }

    /// Draws the status item's picture for what it is showing right now.
    ///
    /// `MenuBarIcon.ratio` rather than a remembered value: the picture is a
    /// pure function of the snapshot and the clock, so asking again cannot
    /// disagree with what `observeUsage` last drew.
    private func redrawStatusItemImage() {
        statusItem?.button?.image = MenuBarIcon.image(for: MenuBarIcon.ratio(for: usage.snapshot),
                                                      appearance: iconAppearance)
    }

    /// The appearance the status item's picture is resolved against. See
    /// `observeAppearance` above for why it is the button's and not the app's.
    private var iconAppearance: NSAppearance {
        MenuBarIcon.appearance(ofButton: statusItem?.button, system: NSApp.effectiveAppearance)
    }

    // MARK: - Status item

    /// The status item: a picture that carries the fleet's burn ratio, a left
    /// click that opens the popover and a right click that opens the menu.
    ///
    /// The menu is not left on `item.menu`: a status item with a menu sends no
    /// action for either button. It is attached for one `performClick` instead,
    /// which keeps the button highlighted while the menu is down.
    private func installStatusItem() {
        // Not `squareLength`: the picture is a bar and a number, wider than tall.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Uses `item.button` directly: `statusItem` is assigned further down,
        // and the first picture must already use the button's appearance.
        item.button?.image = MenuBarIcon.image(
            for: nil,
            appearance: MenuBarIcon.appearance(ofButton: item.button,
                                               system: NSApp.effectiveAppearance))
        // No `toolTip` on purpose: it pops up on every pass over the menu bar.
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        // Both buttons have to reach the action for it to be able to tell them
        // apart. `NSApp.currentEvent` inside the action is the click itself.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let menu = NSMenu()
        menu.addItem(menuItem("Show panel", #selector(showPanel), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("Open config", #selector(openConfig), key: ""))
        menu.addItem(menuItem("Install hooks", #selector(installHooks), key: ""))
        menu.addItem(menuItem("Check permissions", #selector(checkPermissions), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit", #selector(quit), key: "q"))
        statusMenu = menu
        statusItem = item

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView(usage: usage, history: history))

        // The panel's auto-hide can call `NSApp.hide`, which would take an open
        // popover down with it; `canHideApp` asks this delegate about it.
        panel.isPopoverOpen = { [weak self] in self?.popover.isShown ?? false }

        observeUsage()
    }

    /// Redraws the picture when — and only when — what it is drawn from changes.
    ///
    /// The picture is a pure function of the ratio, so duplicates are removed on
    /// the ratio, not the snapshot. No timer of its own: the store polls every
    /// minute. The ratio is computed here rather than carried in the snapshot
    /// because it has an age ceiling: a ratio unconfirmed for twenty minutes
    /// drops out on the next published poll.
    private func observeUsage() {
        usage.$snapshot
            .map { MenuBarIcon.ratio(for: $0) }
            .removeDuplicates()
            .sink { [weak self] ratio in
                guard let self else { return }
                self.statusItem?.button?.image = MenuBarIcon.image(for: ratio,
                                                                   appearance: self.iconAppearance)
            }
            .store(in: &cancellables)
    }

    /// Left click opens the popover, right click (and control-click, which is
    /// the same gesture on a one-button mouse) opens the menu.
    ///
    /// Only the popover path asks `PopoverDismissal`: a right press over an open
    /// popover dismisses it and still delivers the action, so a guard here would
    /// swallow the menu.
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else {
            toggleUsagePopover()
            return
        }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showStatusMenu()
        } else {
            toggleUsagePopover()
        }
    }

    /// Puts the menu up under the status item, then takes it off again.
    ///
    /// Attaching the menu for one `performClick`, rather than
    /// `popUp(positioning:at:in:)`, makes AppKit draw the button highlighted.
    private func showStatusMenu() {
        guard let item = statusItem, let menu = statusMenu else { return }
        // First: closing the popover hands the keyboard back, which can call
        // `NSApp.hide` and cancel the menu tracking about to start. `canHideApp`
        // reads this flag and refuses meanwhile.
        panel.menuWillOpen()
        // Usually a no-op (the right mouse-down already dismissed the transient
        // popover), but it guarantees the menu never opens over the popover.
        popover.performClose(nil)
        item.menu = menu
        // Returns when the tracking is over — the menu runs its own loop — so
        // the flag is dropped here whether it was tracked or not.
        item.button?.performClick(nil)
        item.menu = nil
        panel.menuOpeningDidFinish()
    }

    private func toggleUsagePopover() {
        guard let button = statusItem?.button else { return }
        // The click that dismissed the popover must not reopen it; `isShown` is
        // false either way, so `PopoverDismissal` decides.
        guard !dismissal.shouldIgnoreClick(at: Date()) else { return }
        // An `LSUIElement` never activates on its own, so without this the first
        // click inside the popover only activates the app (§4). It goes through
        // the panel controller, which accounts for the later hand-back, and it
        // also clears a previous `NSApp.hide`, so no `unhide` is needed.
        panel.activateAppForOwnWindow()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        history.open(labels: usage.snapshot.accounts.map(\.label))
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
    /// effective values first when the file does not exist yet. This explicit
    /// user action is the only place the file is ever created.
    @objc private func openConfig() {
        let url = Config.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let contents: [String: Any] = [
                "projectRoots": config.projectRoots,
                "scanDepth": config.scanDepth,
                "activityWindowDays": config.activityWindowDays,
                "dwellMilliseconds": config.dwellMilliseconds,
                "panelWidth": config.panelWidth,
                "panelHeightFraction": config.panelHeightFraction,
                "subagentActiveSeconds": config.subagentActiveSeconds,
                "transcriptTailBytes": config.transcriptTailBytes,
                "editorBundleID": config.editorBundleID,
                "usageBaseURL": config.usageBaseURL
            ]
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: contents,
                                                      options: [.prettyPrinted, .sortedKeys])
                try data.write(to: url, options: .atomic)
            } catch {
                presentAlert(title: "Could not create config",
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
                self?.presentAlert(title: "Accessibility granted",
                                   message: "Windows visible for \(bundleID): \(count).")
            }
        }
    }

    /// Launch-time permission handling: the system prompt, and nothing else.
    ///
    /// `AXIsProcessTrustedWithOptions` shows its dialog asynchronously and
    /// returns the current (still false) status immediately; macOS shows it only
    /// once per bundle. The settings pane is never opened at launch, so a login
    /// item does not steal focus; that is reserved for an explicit click
    /// (`requestAccessibility`).
    private func promptForAccessibilityIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.promptShownKey) else { return }
        defaults.set(true, forKey: Self.promptShownKey)
        VSCodeWindows.requestAccessibilityPermission()
        store.refresh()
    }

    /// The user asked for the permission — the banner in the panel or the menu
    /// item. Both the system prompt and the settings pane, every time.
    ///
    /// The prompt is requested unconditionally: it is a no-op while a TCC entry
    /// exists, and the remembered flag cannot tell, since `tccutil reset`
    /// removes the entry without telling the app.
    ///
    /// The settings pane is opened unconditionally too: when the permission is
    /// switched off while running, the TCC entry stays with `allowed = 0` and the
    /// prompt is silent, so the pane is the only thing the click can do.
    private func requestAccessibility() {
        UserDefaults.standard.set(true, forKey: Self.promptShownKey)
        VSCodeWindows.requestAccessibilityPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // `accessibilityTrusted` is recomputed inside every snapshot, so one
        // extra rebuild makes the banner disappear as soon as access is granted.
        store.refresh()
    }

    /// Forgets the remembered prompt as soon as the permission is actually
    /// there.
    ///
    /// Clearing the flag lets the one-shot prompt work again after
    /// `tccutil reset`. The snapshot recomputes the trust flag every second.
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
            presentAlert(title: "Script not found",
                         message: "install-hooks.sh is neither in the bundle nor beside the binary. "
                                + "Run scripts/install-hooks.sh from the repository by hand.")
            return
        }
        // The script shells out to jq and rewrites ~/.claude/settings.json, so
        // it runs off the main thread and reports back with its own output.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.run(script: script)
            DispatchQueue.main.async { [weak self] in
                self?.presentAlert(title: result.status == 0 ? "Hooks installed" : "Install failed",
                                   message: result.output.isEmpty ? "Exit code \(result.status)." : result.output)
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
    ///
    /// The activation goes through the panel controller like the popover's and
    /// the search field's, and the keyboard is handed back when the modal ends;
    /// otherwise the app stays frontmost with nothing on screen (§4).
    /// `canHideApp` refuses while `NSApp.modalWindow` is set.
    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        panel.activateAppForOwnWindow()
        alert.runModal()
        panel.modalDidFinish()
    }
}

// MARK: - Popover lifecycle

extension AppDelegate: NSPopoverDelegate {

    /// The popover went away: stop asking the gateway for history, and give the
    /// keyboard back.
    ///
    /// Fetching is tied to this delegate call rather than SwiftUI `onDisappear`,
    /// because `NSPopover` keeps its content view controller alive between
    /// showings.
    ///
    /// Closing the popover does not undo the activation, so without a hand-back
    /// an `.accessory` app stays frontmost with nothing to type into (§4). The
    /// panel controller decides when, so a popover closed over a visible panel
    /// is handed back once the panel hides too.
    func popoverDidClose(_ notification: Notification) {
        // First: whether the dismissing press is still in flight is only
        // observable now, while the button is down (`PopoverDismissal`).
        dismissal.popoverClosed(at: Date(), midPress: NSEvent.pressedMouseButtons != 0)
        history.close()
        panel.popoverDidClose()
    }
}
