import AppKit
import Combine
import Foundation
import SwiftUI

/// The press that took the usage popover down, kept only long enough to tell it
/// apart from the next press.
///
/// A `.transient` popover is dismissed from the mouse-*down*, while the status
/// item's action is sent on the mouse-*up* (`sendAction(on:)` in
/// `installStatusItem`). Measured on a bench of synthesised `NSEvent`s posted
/// into the app's own queue, with the down and the up 300 ms apart:
/// `popoverDidClose` arrives 1–6 ms after the down, `NSApp.currentEvent` at that
/// instant being the down itself. So the two halves of one press are 300 ms
/// apart with nothing but the moment shared between them, and `isShown` — false
/// by the time the action runs — cannot tell that press from the next one.
///
/// Two things decide it here instead, and neither is the length of the press:
///
/// - **A button was still down when the popover went away.** That is the mark of
///   a press in flight, and it is `NSEvent.pressedMouseButtons`, the hardware
///   state at that instant rather than anything remembered. Measured: 1 at a
///   close a real press caused (three of them, from clicks that landed on the
///   machine while the bench was running), 0 at a `performClose` called from a
///   timer. Which is what keeps a dismissal by Esc, and `showStatusMenu`'s own
///   `performClose`, from arming anything. Not `NSApp.currentEvent`: it is the
///   last event *retrieved from the queue* and goes stale — at a programmatic
///   close it named an `appKitDefined` event 1.4 s old.
/// - **One press, one answer.** The mark is spent by the first click that asks,
///   whatever the answer, so a press whose second half never arrives can cost
///   at most that one click: the click after it is somebody's first half either
///   way.
///
/// The window is what is left over: the backstop for exactly that second half
/// never arriving. What it *bounds*, though, is not the length of that press,
/// and the measurement is what says so. On the bench the dismissing left press
/// never reached the action at all — its mouse-down is swallowed by the
/// popover's own dismissal monitor, and a status item sends no action for an up
/// whose down it never saw (`toggleUsagePopover` has the whole of it). So the
/// mark is not spent by the press that left it: it is spent by whichever click
/// comes next, and the interval measured against the window is the pause
/// between two clicks.
///
/// Which gives the window a price, and the price is one click. An ordinary
/// double click on the status item — `down#1 → up#2`, 200–350 ms — has its
/// second half swallowed if that half lands inside the window: the popover
/// closes on the first click and does not come back on the second. At the 0.4 s
/// this replaces, the whole of that range was inside. 0.25 s is about as narrow
/// as the band can be made while still leaving room for the case the guard is
/// here for: a press whose action does arrive, ending the press that began it.
///
/// That case is also why the guard stands at all, and why "it never fires on
/// the bench" is not grounds for taking it out: the live HID path is not
/// reachable from a test. A status item put up while the menu bar is full parks
/// off screen (x = -14322), and clicking the running app's own item means a
/// rebuilt bundle, which revokes its Accessibility grant (README).
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
    /// Utilisation over time for the popover's chart. **This object** fetches
    /// only while the popover is open — the endpoint behind it is not that
    /// exclusive, `usage` above reads the same histories every ten minutes for
    /// the load figure (`UsageClient.history`).
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
    /// Light and dark are an input to the picture now that it is not a template
    /// (`MenuBarIcon`), so a change of them is a reason to redraw it.
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
    /// The status item's picture is redrawn for a related reason: it is a bitmap
    /// rasterised once, at the scale in force when it was drawn (see
    /// `MenuBarIcon.image`), and otherwise only redrawn when the figure behind it
    /// changes — which can be hours. A display of a different backing scale
    /// arriving is exactly the event that invalidates it. Unlike the panel's
    /// half this one is reasoned, not observed: there is one screen on the
    /// machine this was written on, so what a mismatched scale looks like is
    /// untested. It costs one bitmap on an event that happens by hand.
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

    /// The menu bar going from light to dark is the other event that invalidates
    /// the picture, and it is not the figure changing — nothing in the snapshot
    /// moves, so `observeUsage` below never fires and the icon would keep its old
    /// ink until the next poll that happened to say something new. Which can be
    /// hours: the figure is a rounded percentage and mostly repeats.
    ///
    /// Since the picture stopped being a template it is drawn against one
    /// appearance and holds it (`MenuBarIcon.image`), so a stale one is dark ink
    /// on a dark menu bar.
    ///
    /// The button's own appearance and not `NSApp`'s, which is what stood here
    /// under the reasoning that the two are "a dependency for no difference on a
    /// machine where the menu bar and the app share an appearance". They do not
    /// share one: measured 2026-08-18, `NSApp.effectiveAppearance` is
    /// `NSAppearanceNameDarkAqua` while the status item's button is
    /// `NSAppearanceNameVibrantDark`, and forcing `NSApp.appearance` to `aqua`
    /// leaves the button on `VibrantDark` — the menu bar follows the wallpaper,
    /// not the system theme (`MenuBarIcon.appearance(ofButton:system:)` records
    /// the whole measurement). Both halves failed together: the picture resolved
    /// its ink against the wrong appearance, and the theme it watched had not
    /// changed, so nothing redrew it.
    ///
    /// `effectiveAppearance` is KVO-compliant on the button too, which is not a
    /// thing to assume of a derived property — measured in the same scratch
    /// process, three changes of the button's own `appearance` (to `darkAqua`,
    /// to `aqua`, back to inherited) delivered three notifications, while the
    /// three changes of `NSApp.appearance` delivered none, the button's
    /// effective appearance not having moved.
    ///
    /// No fallback branch to `NSApp`: with no button there is no picture to
    /// redraw, and an observer that watched the app in that case would be
    /// keeping a bitmap nobody is showing up to date.
    private func observeAppearance() {
        guard let button = statusItem?.button else { return }
        appearanceObserver = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.redrawStatusItemImage() }
        }
    }

    /// Draws the status item's picture for what it is showing right now.
    ///
    /// `MenuBarIcon.reading` rather than a remembered value: the picture is a
    /// pure function of the snapshot and the clock, so asking again cannot
    /// disagree with what `observeUsage` last drew.
    private func redrawStatusItemImage() {
        statusItem?.button?.image = MenuBarIcon.image(for: MenuBarIcon.reading(for: usage.snapshot),
                                                      appearance: iconAppearance)
    }

    /// The appearance the status item's picture is resolved against. See
    /// `observeAppearance` above for why it is the button's and not the app's.
    private var iconAppearance: NSAppearance {
        MenuBarIcon.appearance(ofButton: statusItem?.button, system: NSApp.effectiveAppearance)
    }

    // MARK: - Status item

    /// The status item: a picture that carries the fleet's weekly quota, a left
    /// click that opens the popover and a right click that opens the menu.
    ///
    /// The menu is deliberately *not* left sitting on `item.menu`. A status item
    /// with a menu attached hands both mouse buttons to it and never sends its
    /// action at all, so the left click could not do anything else. It is
    /// attached for the length of one `performClick` instead, which is what
    /// keeps the button highlighted while the menu is down.
    private func installStatusItem() {
        // Not `squareLength`: the picture is a bar and a number, and it is wider
        // than it is tall. No app glyph in front of them — that one was thrown
        // out on sight (`MenuBarIcon`).
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Against the button's own appearance from the very first picture, and
        // that one is asked of `item` rather than of the property: the property
        // is assigned further down, and a first picture drawn against the app's
        // appearance would be the wrong ink until something happened to redraw it.
        item.button?.image = MenuBarIcon.image(
            for: MenuBarIcon.Reading(),
            appearance: MenuBarIcon.appearance(ofButton: item.button,
                                               system: NSApp.effectiveAppearance))
        // No `toolTip` on purpose: the tag popped up on every pass of the
        // pointer over the menu bar and was asked for gone. The picture and the
        // popover behind the click are how the item explains itself.
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
        // popover down with it. That is one of the four states `canHideApp`
        // knows about, and the only one it has to ask this delegate for — the
        // popover is AppKit's, not the panel controller's.
        panel.isPopoverOpen = { [weak self] in self?.popover.isShown ?? false }

        observeUsage()
    }

    /// Redraws the picture when — and only when — what it is drawn from changes.
    ///
    /// `removeDuplicates` over the whole reason for the drawing, not over the
    /// snapshot: a poll lands once a minute and mostly says the same thing, and
    /// the picture is a pure function of one `MenuBarIcon.Reading`, so two equal
    /// values cannot produce two different pictures. No timer of its own — the
    /// store's poll is the whole schedule.
    ///
    /// The reading is a pair now, and the second half moves on a schedule of its
    /// own: the load figure is refetched every ten minutes, so most passes leave
    /// it exactly where it was and change nothing here. It also has an age
    /// ceiling, which is why the reading is worked out here rather than carried
    /// in the snapshot — a load nobody has confirmed for twenty minutes drops out
    /// of the picture on the next pass that publishes anything, and the poll
    /// publishes every minute whatever the gateway says.
    private func observeUsage() {
        usage.$snapshot
            .map { MenuBarIcon.reading(for: $0) }
            .removeDuplicates()
            .sink { [weak self] reading in
                guard let self else { return }
                self.statusItem?.button?.image = MenuBarIcon.image(for: reading,
                                                                   appearance: self.iconAppearance)
            }
            .store(in: &cancellables)
    }

    /// Left click opens the popover, right click (and control-click, which is
    /// the same gesture on a one-button mouse) opens the menu.
    ///
    /// Only the popover's half asks `PopoverDismissal` anything, and that is not
    /// an oversight. Measured: a right press over an open popover takes it down
    /// on its own mouse-down and then *does* deliver the action on the mouse-up,
    /// about a millisecond later — the left button's does not, its down being
    /// swallowed. A guard on this path would therefore swallow the menu itself,
    /// every time it is asked for over an open popover.
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
    /// `popUp(positioning:at:in:)` would work too, but leaving the menu on the
    /// item for the duration of one `performClick` is what makes AppKit draw the
    /// button highlighted while the menu is open, exactly as it did when the
    /// menu lived there permanently.
    private func showStatusMenu() {
        guard let item = statusItem, let menu = statusMenu else { return }
        // Declared before anything else happens, because the very next line can
        // hide the app: closing the popover hands the keyboard back, and a
        // hand-back with nothing left in front of it calls `NSApp.hide`, which
        // cancels menu tracking — here, the tracking that has not begun yet, one
        // instruction before it does. `canHideApp` reads the flag and answers no
        // meanwhile. Standing the close far enough from the click would not be a
        // defence: it holds only as long as AppKit delivers that close
        // synchronously, which is nobody's promise and which `animates = false`
        // makes likelier rather than certain.
        panel.menuWillOpen()
        // A menu opening over an open popover would leave two things up at once.
        // Measured, that is belt and braces rather than the working part: the
        // right button's mouse-*down* dismisses a transient popover just as the
        // left one's does, ~300 ms before this action runs, so what this closes
        // is almost always a popover that is already down. Kept because it costs
        // nothing on an already-closed popover and because "almost always" is
        // measured over one bench, not proved.
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
        // The click that dismissed the popover must not open it again — the user
        // asked for a close and saw a blink. `isShown` cannot tell the two
        // presses apart: it is false here either way, because `.transient` took
        // the popover down on the mouse-down of whichever press this is. What
        // can is `PopoverDismissal`, and every word of its rule was measured on
        // the bench described there.
        //
        // The branch that used to stand here — `if popover.isShown { close }` —
        // was removed rather than kept as the fix: it could not run. Its
        // documented entrance was a programmatic `performClick`, and the only
        // one in this app is made with `item.menu` already attached, which is
        // exactly the state in which a status item sends no action at all.
        //
        // What the bench could not reproduce is a real mouse: the status item it
        // put up landed off screen (a full menu bar parks the overflow at
        // x = -14322), so a click posted at its own coordinates would have gone
        // somewhere else, and clicking the running app's item needs a rebuilt
        // bundle — which revokes the Accessibility grant of the copy the user is
        // running (README). With synthesised events the dismissing *left* press
        // never reached this method at all: its mouse-down is swallowed by the
        // popover's own dismissal monitor, and a status item button sends no
        // action for an up whose down it never saw (checked with a lone up,
        // which produces nothing, and with the press after, which works). So on
        // that bench this guard has nothing to catch — it stands for the case
        // the bench cannot show, and costs one ignored click in a 0.25 s window
        // after a dismissal it did not catch.
        guard !dismissal.shouldIgnoreClick(at: Date()) else { return }
        // Same reasoning as the panel's search field (§4): this app is an
        // `LSUIElement` that never activates on its own, so without this the
        // first click inside the popover is spent activating the app instead of
        // hitting the period picker it landed on. Probed: right after `show`
        // the app is not yet active, half a second later it is and the popover's
        // window is key — which is what the picker needs.
        //
        // Through the panel controller, because the hand-back is accounted for
        // there and an activation off that account is one nobody gives back —
        // see `PanelController.activateAppForOwnWindow`. This call is also what
        // undoes the `NSApp.hide` that settles it: probed from the hidden state,
        // `activate` plus `show` brings the popover back up with `isHidden`
        // cleared, so there is no `unhide` to remember — the same arrangement
        // the panel has with `orderFrontRegardless`.
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
    /// effective values first when the file does not exist yet. The data layer
    /// deliberately never creates the file on its own, so this is the one place
    /// where an explicit user action may.
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
    /// item. Both the system prompt and the settings pane, every time.
    ///
    /// The prompt is asked for unconditionally on purpose. It is a no-op while a
    /// TCC entry exists, and the remembered flag is not a reliable statement
    /// about whether one does: `tccutil reset` — the way to clear the dead entry
    /// an ad-hoc signature leaves behind after a rebuild — removes the entry
    /// without telling the app.
    ///
    /// So is the settings pane, and that is the difference from the launch path.
    /// Opening it only once the prompt was known to be used up left the click
    /// doing nothing at all in the one case that matters: the permission
    /// switched off while the app was running. The TCC entry survives that with
    /// `allowed = 0`, so the prompt stays silent, while the flag had been
    /// cleared the last time access was seen — the orange banner swallowed the
    /// first click and only reacted to the second. A click on it is the explicit
    /// action this branch was kept for.
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
    /// The activation goes on the same account as the popover's and the search
    /// field's, and the debt is settled when the modal ends. Done here with a
    /// bare `NSApp.activate`, this was the third activator of an app that has no
    /// window of its own once the alert is dismissed — §4's defect by the
    /// shortest route there is: press "Check permissions", read the answer,
    /// click OK, and the app stays frontmost with nothing on screen while the
    /// keystrokes go nowhere. No exception for a modal was found: hiding is
    /// unsafe *during* `runModal` (`canHideApp` answers no while
    /// `NSApp.modalWindow` stands), and by the line after it there is nothing
    /// left of ours to hide.
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
    /// Both halves are the popover's side of a bargain made elsewhere. The
    /// fetching is tied to the popover being open, which is what makes "closed,
    /// no requests" a fact rather than a hope — `NSPopover` keeps its content
    /// view controller alive between showings, so a SwiftUI `onDisappear` is not
    /// a promise this can be hung on.
    ///
    /// The hand-back is the same defect `PanelController.releaseKeyboardFocus`
    /// exists for (§4): this app is an `.accessory` with no window of its own
    /// once the popover is down, and activating it is not undone by closing
    /// that popover. A transient popover dismissed with Esc leaves the app
    /// frontmost with nothing to type into, and the user's next keystrokes go
    /// nowhere while their editor looks perfectly alive.
    ///
    /// Which is why it is asked of the panel controller rather than decided
    /// here. Decided here, it could only settle the debt on the spot: a popover
    /// dismissed over a *visible* panel had to be let go, and nothing then
    /// picked the debt up when the panel slid away a moment later — the app
    /// stayed frontmost with nothing on screen, the very defect above. Over
    /// there the debt outlives both, and the postponed hand-back carries its own
    /// retry for a menu or a modal standing in the way.
    func popoverDidClose(_ notification: Notification) {
        // Before anything else: the press that dismissed it may still be in
        // flight, its second half due as this app's own action. Whether it is
        // one is asked of the hardware here and nowhere else — see
        // `PopoverDismissal`. This is also the one place the answer is available
        // at all: a moment later the button is up and the state says nothing.
        dismissal.popoverClosed(at: Date(), midPress: NSEvent.pressedMouseButtons != 0)
        history.close()
        panel.popoverDidClose()
    }
}
