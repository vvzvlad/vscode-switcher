import AppKit
import Combine
import SwiftUI

/// The panel itself.
///
/// A borderless window refuses key status by default, so `canBecomeKey` has to
/// be overridden — but the panel must not grab the keyboard merely by appearing.
/// The two are reconciled by `becomesKeyOnlyIfNeeded`: the panel is only ever
/// ordered in, never made key, so it becomes key exactly when the user clicks
/// something that needs to be first responder — the search field. Returning a
/// constant `false` instead does not work at all: a window that cannot become
/// key also swallows the first click, because the SwiftUI views inside it do not
/// accept a first mouse, and the clicks the panel exists for never arrive.
final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// An activation this app performed for itself, and whether the keyboard is
/// still owed back.
///
/// This app is an `.accessory` with no window of its own, so an activation that
/// is never given back leaves it frontmost with nothing to type into: the user
/// goes back to their editor, types, and the keystrokes go nowhere while the
/// editor looks perfectly alive (§4). Three things activate — the panel's search
/// field, the status item's popover and the alerts its menu items put up — and
/// only all of them together are the answer to "may the app hide now": whichever
/// is dismissed first, another may still legitimately need the app in front.
/// Which is why they share one account instead of each minding its own: the
/// alert was the one that did mind its own, activating with a bare `NSApp`
/// call, and it left the app frontmost over nothing every time it was dismissed.
///
/// A value type, and the whole rule in one place, because the sequence that
/// broke it cannot be reached from a test through `NSApp`: the popover activates,
/// the popover is dismissed while the panel is up (nothing owed — the panel is in
/// front for its own sake), and the panel then goes away with the debt still
/// standing. Kept as two flags on the controller, that middle step used to lose
/// the debt or never record it at all.
struct ActivationDebt: Equatable {

    /// What the caller should do about the debt right now.
    enum Action: Equatable {
        /// Hand the keyboard back — `NSApp.hide`. Settles the debt.
        case hide
        /// Something of this app's own is in the way (a modal, a menu being
        /// tracked, the popover). Ask again shortly; the debt stands.
        case retry
        /// Nothing to do: nothing owed, something of ours is legitimately in
        /// front, or the front slot has already gone elsewhere.
        case nothing
    }

    private(set) var isOwed = false

    /// The app was activated by us, for whatever reason.
    mutating func activated() { isOwed = true }

    /// What to do now, given what is on screen.
    mutating func settle(panelVisible: Bool, appActive: Bool, canHide: Bool) -> Action {
        // The panel is up: the app is in front for its sake, and the debt waits
        // for the panel's own hide rather than being settled or forgotten here.
        guard !panelVisible else { return .nothing }
        guard isOwed else { return .nothing }
        // Not active any more: a row click already handed the front slot to the
        // editor, so there is nothing left to give back.
        guard appActive else {
            isOwed = false
            return .nothing
        }
        guard canHide else { return .retry }
        isOwed = false
        return .hide
    }
}

/// Owns the sliding panel: geometry, the show/hide animation and the dismissal
/// rules.
///
/// The panel is a mouse-only surface. Clicking a row acts on it and leaves the
/// panel up, because the point of the panel is stepping through several windows
/// in a row; it goes away when the pointer leaves it or a click lands elsewhere.
@MainActor
final class PanelController {

    private static let cornerRadius: CGFloat = 12
    private static let showDuration: TimeInterval = 0.14
    private static let hideDuration: TimeInterval = 0.10

    private(set) var isVisible = false

    /// Reported after every show/hide so the edge trigger knows the panel's
    /// frame and can apply the auto-hide rule.
    var onVisibilityChanged: ((Bool, NSRect) -> Void)?
    /// The panel stayed up and only changed shape — a display was plugged in,
    /// the resolution changed, the Dock moved. Kept apart from
    /// `onVisibilityChanged` because everything an appearance resets — the
    /// auto-hide countdown above all — must survive a mere reframe.
    var onPanelMoved: ((NSRect) -> Void)?
    /// The user asked for the Accessibility permission from the panel.
    var onGrantAccessibility: (() -> Void)?
    /// Whether the status item's usage popover is on screen. Asked afresh every
    /// time rather than mirrored into a flag here: `NSPopover.isShown` is the
    /// truth, and a copy of it is one more thing that can be left behind.
    /// See `canHideApp`.
    var isPopoverOpen: (() -> Bool)?

    private let config: Config
    private let store: SnapshotStore
    private let model = SwitcherViewModel()
    private let panel: SwitcherPanel
    private let visualEffect = NSVisualEffectView()

    /// Where the panel is going, as opposed to where it is drawn right now.
    ///
    /// The slide-in takes 0.14 s, during which `panel.frame` is still somewhere
    /// off screen while the panel is already visible under the pointer. Deciding
    /// "the click landed outside" from the animating frame therefore dismissed
    /// the panel on a click that visibly hit it.
    private var targetFrame: NSRect = .zero

    private var clickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    /// This app activated itself and has not handed the keyboard back yet. See
    /// `releaseKeyboardFocus`.
    private var debt = ActivationDebt()
    /// How many of this app's menus are being tracked right now — the status
    /// item's, in practice. Counted rather than flagged so a submenu cannot
    /// close the count while its parent is still up.
    ///
    /// A count is a guess about the world, and one that drifts upwards never
    /// comes back down on its own, so it is reconciled with reality in
    /// `scheduleKeyboardReleaseRetry`.
    private var menuTrackingDepth = 0
    /// A menu of ours has been asked for and is not over yet. See
    /// `menuWillOpen`.
    ///
    /// Readable from outside, unlike the count beside it, because it is the one
    /// of the four `canHideApp` states with no way back: the tracking count is
    /// reconciled with reality before every retry, a modal is asked of the
    /// system anew each time, the popover answers for itself — and this is a
    /// flag set and cleared by two calls of ours, which stops the hand-back for
    /// good if the second one is ever missed. A test can hold that pair only if
    /// it can see the flag.
    private(set) var menuOpening = false
    /// Retries a hand-back that had to wait. See `releaseKeyboardFocus`.
    private var keyboardReleaseRetry: Timer?

    init(config: Config, store: SnapshotStore) {
        self.config = config
        self.store = store

        panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: config.panelWidth, height: 400),
                              styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered,
                              defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovable = false
        // The panel takes the keyboard only when a view inside it needs to be
        // first responder — that is, when the search field is clicked. Rows are
        // plain click targets and leave the focus where it was.
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = true
        // AppKit's own fade would fight the slide-in animation below.
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        visualEffect.material = .sidebar
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = Self.cornerRadius
        visualEffect.layer?.cornerCurve = .continuous
        // Only the two right corners are rounded: the left side is flush with
        // the screen edge.
        visualEffect.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        visualEffect.layer?.masksToBounds = true
        panel.contentView = visualEffect

        let hosting = NSHostingView(rootView: SwitcherView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor)
        ])

        model.onActivate = { [weak self] row in self?.activate(row) }
        model.onSearchFieldTap = { [weak self] in self?.takeKeyboardFocus() }
        model.onGrantAccessibility = { [weak self] in self?.onGrantAccessibility?() }
        // `DispatchQueue.main`, not `RunLoop.main`: the latter only delivers in
        // the default run loop mode, while every timer here runs in `.common`.
        // Dragging the scroller put the run loop into the tracking mode, and the
        // updates piled up until the drag ended and then arrived in one batch.
        store.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in self?.model.update(snapshot: snapshot) }
            .store(in: &cancellables)

        observeMenuTracking()
    }

    /// Follows the tracking of every menu this app puts up, because
    /// `releaseKeyboardFocus` must not run while one is open — see `canHideApp`.
    /// Observed with `object: nil`: the only menu here belongs to the status
    /// item, which `AppDelegate` owns, and the rule is about menus in general
    /// rather than that one.
    private func observeMenuTracking() {
        let center = NotificationCenter.default
        _ = center.addObserver(forName: NSMenu.didBeginTrackingNotification,
                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTrackingDepth += 1
            }
        }
        _ = center.addObserver(forName: NSMenu.didEndTrackingNotification,
                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTrackingDepth = max(0, self.menuTrackingDepth - 1)
            }
        }
    }

    // MARK: - Show / hide

    func show(on screen: NSScreen) {
        let target = Self.frame(on: screen, config: config)
        targetFrame = target

        if isVisible {
            // A plain `setFrame` does not stop an animation that is still
            // running. A screen change landing inside the 0.14 s slide-in below
            // therefore let the animator finish on the *old* target while
            // `targetFrame` and the edge trigger already held the new one: the
            // panel drawn in one place, the "click landed outside" test and the
            // keep-open zone in another. A zero-duration group replaces the
            // running animation for the same key instead of racing it.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel.animator().setFrame(target, display: true)
            }
            panel.orderFrontRegardless()
            onPanelMoved?(target)
            return
        }
        isVisible = true
        model.panelDidShow()

        var start = target
        start.origin.x = target.minX - target.width
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        // Lay the list out at its final size before a single frame is on screen.
        // Without this the first layout pass happened while the window was
        // already sliding, the scroll view learned its content height in
        // instalments and flashed its indicator at every step — the scrollbar
        // that danced in and out on every open.
        visualEffect.layoutSubtreeIfNeeded()
        // Not `makeKeyAndOrderFront`: showing the panel must never pull the
        // keyboard away from whatever the user was working in.
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.showDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            // `display: false`: the slide only changes the origin, so there is
            // nothing to redraw, and asking for a display forced a full layout
            // pass of the SwiftUI content on every animation step.
            panel.animator().setFrame(target, display: false)
            panel.animator().alphaValue = 1
        }

        installMonitors()
        store.setPanelVisible(true)
        onVisibilityChanged?(true, target)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        model.searchFieldFocused = false
        // Told at the start of the hide, not in the completion handler: the
        // panel is still on screen for the 0.10 s the slide-out takes, so the
        // update is certain to be processed, whereas a view tree in an
        // ordered-out window has no reason to be. The pulse stopping a tenth of
        // a second early is invisible; see `SwitcherViewModel.panelVisible`.
        model.panelDidHide()
        removeMonitors()

        var target = panel.frame
        target.origin.x = panel.frame.minX - panel.frame.width
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.hideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: false)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
                self.releaseKeyboardFocus()
            }
        })

        store.setPanelVisible(false)
        onVisibilityChanged?(false, .zero)
    }

    /// Panel geometry: flush with the left edge of the screen's usable area,
    /// vertically centred, `config.panelHeightFraction` of that area tall.
    ///
    /// The single source of truth for where the panel lands: `EdgeTrigger` sizes
    /// its trigger strip from the very same rect, so the strip cannot drift away
    /// from the panel it opens.
    static func frame(on screen: NSScreen, config: Config) -> NSRect {
        frame(in: screen.visibleFrame, config: config)
    }

    /// The geometry itself, free of `NSScreen` so it can be checked directly.
    static func frame(in usable: NSRect, config: Config) -> NSRect {
        let height = (usable.height * CGFloat(config.panelHeightFraction)).rounded()
        let y = (usable.midY - height / 2).rounded()
        return NSRect(x: usable.minX.rounded(), y: y,
                      width: CGFloat(config.panelWidth).rounded(), height: height)
    }

    // MARK: - Keyboard focus

    /// Claims the keyboard for as long as the search field is in use. Called
    /// from the field's own click handler, never on show.
    ///
    /// `makeKey()` alone is not enough, and that is not a subtlety: key status
    /// only decides which window of the *active* application receives the
    /// keystrokes. This app is an `LSUIElement` that never activates, and the
    /// panel is a `.nonactivatingPanel`, so clicking the field drew a caret in
    /// it while the system keyboard focus stayed in the editor — everything the
    /// user typed went into their source file and the field stayed empty, with
    /// no way back because the click catcher over the field was already gone.
    /// So the app is activated here and only here: the show path still must not
    /// touch activation.
    ///
    /// `hidesOnDeactivate` is false, so the panel survives the deactivation that
    /// follows. The one visible side effect is that `frontmostApplication` stops
    /// being the editor, and `update(snapshot:)` only assigns the highlight when
    /// it can name a frontmost window — so the highlight stays where it was.
    /// The activation is remembered, because it has to be given back when the
    /// panel goes away — see `releaseKeyboardFocus`.
    private func takeKeyboardFocus() {
        guard isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        debt.activated()
        panel.makeKey()
        model.searchFieldFocused = true
    }

    /// Activates the app for something of ours that needs the app in front: the
    /// status item's popover, and the alerts the menu items put up. An
    /// `LSUIElement` that never activates spends the first click inside such a
    /// window on becoming active instead of on the control it landed on, and an
    /// alert behind every other window is worse still.
    ///
    /// It goes through here rather than through `NSApp.activate` at the call
    /// site so that every activation lands on the same account. Kept apart, an
    /// activation is one nobody is owed back: the popover hands it over only in
    /// `popoverDidClose` and only with the panel down, so "clicked the status
    /// item, then went to the panel, then dismissed the popover" left the app
    /// frontmost with no window — §4's defect exactly, and the user typing into
    /// nowhere until they clicked something. The alert reached the same end by a
    /// shorter road: it activated for itself, was dismissed, and left nothing on
    /// screen and nobody counting.
    func activateAppForOwnWindow() {
        NSApp.activate(ignoringOtherApps: true)
        debt.activated()
    }

    /// A menu of ours is about to be put up.
    ///
    /// Held from the decision until the menu is over, because the stretch
    /// before tracking begins is a window in which `NSApp.hide` cancels a
    /// tracking that has not started yet — and the caller's own first step is
    /// closing the popover, which hands the keyboard back and may hide the app
    /// on the spot. Ordering the two lines the other way round would only work
    /// as long as AppKit delivers the close synchronously, which is nobody's
    /// promise; this closes the gap instead of stepping over it.
    ///
    /// Dropping the flag the moment tracking begins — a third writer, in
    /// `didBeginTracking` — was removed rather than kept: from that moment
    /// until `menuOpeningDidFinish` the tracking count answers no on its own,
    /// in the same conjunction, so the only interval the early clear could
    /// change is the sliver between `didEndTracking` and the call below, where
    /// it *permits* a hide this flag would otherwise postpone.
    func menuWillOpen() {
        menuOpening = true
    }

    /// The menu has been put up and taken down again — or was never tracked at
    /// all. Either way there is nothing left to stand in for.
    func menuOpeningDidFinish() {
        menuOpening = false
    }

    /// A modal of ours has finished. The same question the popover's close asks,
    /// and asked in the same place for the same reason: the app was activated
    /// for the alert, the alert is gone, and this is the moment the debt can be
    /// settled — or postponed, if the panel is up or a menu is in the way.
    func modalDidFinish() {
        releaseKeyboardFocus()
    }

    /// The popover went away. Whether that means handing the keyboard back is
    /// the same question the panel's own hide asks, so it is asked in the same
    /// place: the panel may still be up (nothing owed yet), a menu or a modal
    /// may be in the way (retry), or this may be the last of ours on screen.
    ///
    /// Whether `NSPopover.isShown` has already turned false by the time its
    /// delegate is told needs no assumption here: if it has not, `canHideApp`
    /// answers no, and the retry settles it a fifth of a second later.
    func popoverDidClose() {
        releaseKeyboardFocus()
    }

    /// Hands the keyboard back once nothing of ours needs the app in front.
    /// Called when the panel has finished hiding, when the popover closes, when
    /// a modal ends, and from the retry below — once per thing that can be the
    /// last of ours to go away.
    ///
    /// This app is an `.accessory` with no window of its own once the panel is
    /// ordered out, and activating it is not undone by hiding that panel: it
    /// stays the frontmost application, with nothing to type into. "Searched and
    /// walked away without clicking a row" ended there — the user went back to
    /// their editor, typed, and the keystrokes went nowhere while the editor
    /// looked perfectly alive; only a click anywhere fixed it. Clicking a row
    /// hid the defect, because that path activates the editor itself.
    ///
    /// `NSApp.deactivate()` does not do it — probed: the app is still frontmost
    /// afterwards. `NSApp.hide(nil)` does, and the next `orderFrontRegardless`
    /// clears the hidden state on its own, so there is nothing to undo on the
    /// show path. It runs only when the app really is active: a row click has
    /// already handed the front slot to the editor by then, and hiding is the
    /// last thing that should happen to it.
    ///
    /// When `canHideApp` says no, the hand-back is postponed rather than
    /// dropped: the app would otherwise stay frontmost with no window and
    /// swallow every keystroke, which is the whole defect this method exists
    /// for.
    ///
    /// Every rule of it lives in `ActivationDebt`; this only supplies the state
    /// of the world and carries out the answer.
    private func releaseKeyboardFocus() {
        // Only once the panel is actually off screen. A panel that came back up
        // while a hand-back was still pending is legitimately active for the new
        // search, and clearing the caret under the user's typing would be worse
        // than the stale flag.
        if !isVisible { model.searchFieldFocused = false }
        switch debt.settle(panelVisible: isVisible,
                           appActive: NSApp.isActive,
                           canHide: canHideApp) {
        case .hide:
            cancelKeyboardReleaseRetry()
            NSApp.hide(nil)
        case .retry:
            scheduleKeyboardReleaseRetry()
        case .nothing:
            cancelKeyboardReleaseRetry()
        }
    }

    /// Whether `NSApp.hide` is safe to call at all right now.
    ///
    /// Four states of this app's own make it destructive. The first three are
    /// reachable from the ordinary "clicked the search field, then walked away"
    /// path, because the auto-hide fires 400 ms after the pointer leaves and its
    /// timer runs in `.common`:
    ///
    /// - **A modal session.** `hide` orders the `NSAlert`'s window out, but
    ///   `runModal` keeps spinning on the main thread. The app is then stuck in
    ///   a modal loop with no window on screen: the status item menu stops
    ///   responding, the panel cannot open, and only Force Quit gets out of it.
    ///   Probed — `modalWindow=true, canHide=true` before, `isHidden=true,
    ///   visible=false` after, and the app never came back.
    /// - **Menu tracking.** `hide` cancels it, so the status item menu collapsed
    ///   under the pointer while the user was reading it — probed: `popUp`
    ///   returned 0.26 s after the hide that was scheduled during the tracking.
    /// - **An open usage popover.** `hide` takes every window of the app down,
    ///   the popover among them: it closed under the pointer while the user was
    ///   reading the accounts. Probed the same way as the two above — an open
    ///   popover reported `isShown=false` after `NSApp.hide(nil)` and did not
    ///   come back on unhide. Unlike them it needs no retry of its own: the
    ///   popover's own close hands the keyboard back (`popoverDidClose`), so the
    ///   postponed hand-back happens at the moment the obstacle goes away.
    ///
    /// The fourth is the same menu one instruction earlier. Putting the status
    /// menu up begins by closing the popover, and that close hands the keyboard
    /// back — with the menu not yet tracked, nothing then answered no, and the
    /// hide landed in the gap and cancelled a tracking that was about to start.
    /// It is not reached from the auto-hide but from our own call order, which
    /// is why it is a flag we set rather than a state we read: see
    /// `menuWillOpen`.
    private var canHideApp: Bool {
        Self.canHideApp(modal: NSApp.modalWindow != nil,
                        menuTrackingDepth: menuTrackingDepth,
                        menuOpening: menuOpening,
                        popoverOpen: isPopoverOpen?() ?? false)
    }

    /// The rule itself, free of `NSApp`, so all four of its states can be
    /// checked. Every one of them was a defect before it was a clause.
    static func canHideApp(modal: Bool,
                           menuTrackingDepth: Int,
                           menuOpening: Bool,
                           popoverOpen: Bool) -> Bool {
        !modal && menuTrackingDepth == 0 && !menuOpening && !popoverOpen
    }

    /// Retries a postponed hand-back.
    ///
    /// Deliberately scheduled in `.default` only, unlike every other timer here:
    /// that is precisely the mode a menu tracking loop and a modal session do
    /// *not* run, so the retry cannot fire inside either of those two. The
    /// guards in `canHideApp` are still the ones that make it safe; the mode
    /// only keeps the timer quiet meanwhile.
    ///
    /// The other two states are not like that. A popover spins no loop of its
    /// own, so the retry does fire while one is up, five times a second, and
    /// finds `canHideApp` false every time. Harmless, and it ends by itself:
    /// `popoverDidClose` hands the keyboard back at the same instant the
    /// obstacle goes away, and the next tick then sees `NSApp.isActive` false
    /// and cancels itself. `menuOpening` is bounded by one straight-line
    /// stretch of our own code — set before the popover is closed, cleared once
    /// the tracking has returned — so it stands for as long as the menu does. A
    /// tick can still only land inside it in the two instructions before that
    /// tracking begins, the loop itself not running in the default mode; if
    /// AppKit spins a run loop in the middle of closing the popover, the answer
    /// is no, which is exactly what the flag is there for.
    ///
    /// Which also makes this the one place the tracking count can be checked
    /// against reality: the timer firing at all means the run loop is in the
    /// default mode, so no menu of this app is being tracked, so a count still
    /// above zero is a `didEndTracking` that went missing — the notifications
    /// are observed with `object: nil`, for every menu the process puts up.
    /// Left to stick, it makes `canHideApp` answer no for the rest of the run:
    /// the keyboard is never handed back again, silently, which is the "typing
    /// into nowhere" defect returning — and this timer goes on waking the
    /// process five times a second forever. The count is therefore cleared
    /// before every attempt; if that reasoning is ever wrong the cost is a
    /// status menu closing under the pointer once, against a permanently broken
    /// hand-back. `NSApp.modalWindow` needs no such repair — it is asked of the
    /// system anew each time.
    private func scheduleKeyboardReleaseRetry() {
        guard keyboardReleaseRetry == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuTrackingDepth = 0
                self.releaseKeyboardFocus()
            }
        }
        RunLoop.main.add(timer, forMode: .default)
        keyboardReleaseRetry = timer
    }

    private func cancelKeyboardReleaseRetry() {
        keyboardReleaseRetry?.invalidate()
        keyboardReleaseRetry = nil
    }

    // MARK: - Activation

    /// Acts on a clicked row and leaves the panel up.
    ///
    /// Focusing a window is two separate steps in a fixed order. Bringing the
    /// process forward is an AppKit call and stays on the main thread; raising
    /// the window inside it is Accessibility, which can block for as long as the
    /// messaging timeout when the editor is busy, so it goes to a background
    /// queue. Raising first would be undone by the activation that follows.
    ///
    /// The row is handed to `raise` exactly as the snapshot built it: it carries
    /// the window's `CGWindowID`, which no raise reshuffles, so a row clicked a
    /// second ago still names the same window. Looking the window up again by
    /// `pid` + project — as this used to do — picked an arbitrary one of the two
    /// windows a project can have open, which is the very "clicking row 2 raises
    /// window 4" defect the stable identity removed.
    private func activate(_ row: SwitcherRow) {
        let config = config
        model.rowActivated(row)
        if let window = row.window {
            VSCodeWindows.activate(pid: window.pid)
            DispatchQueue.global(qos: .userInitiated).async {
                VSCodeWindows.raise(window)
            }
        } else if let project = row.project ?? Self.syntheticProject(for: row) {
            DispatchQueue.global(qos: .userInitiated).async {
                VSCodeWindows.openProject(project, config: config)
            }
        }
        // The z-order has just changed; pull a fresh snapshot rather than wait
        // out the poll interval.
        store.refresh()
    }

    /// A project stand-in for an orphan `cwd:` row — a live session running
    /// outside every scan root, so the index knows nothing about it.
    ///
    /// The row looks exactly as clickable as any other and used to do nothing at
    /// all. It still names a real directory, and `openProject` already has the
    /// "open the folder when there is no workspace file" branch, so the row can
    /// open like every other project.
    static func syntheticProject(for row: SwitcherRow) -> ProjectInfo? {
        guard row.window == nil, row.project == nil else { return nil }
        guard let cwd = row.sessions.first?.cwd, !cwd.isEmpty else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return ProjectInfo(path: cwd,
                           displayName: name,
                           rootName: name,
                           colorHex: row.colorHex,
                           workspaceFile: nil,
                           mtime: .distantPast)
    }

    // MARK: - Event monitors

    private func installMonitors() {
        removeMonitors()
        // The app spends its whole life in the background, and a global monitor
        // in that state also reports the clicks that land on our own panel — so
        // the dismissal is decided by where the click was, not by the fact that
        // the monitor fired at all.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                guard !NSPointInRect(NSEvent.mouseLocation, self.targetFrame) else { return }
                self.hide()
            }
        }
    }

    private func removeMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}
