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

/// Owns the sliding panel: geometry, the show/hide animation and the dismissal
/// rules.
///
/// The panel is a mouse-only surface. Clicking a row acts on it and leaves the
/// panel up, because the point of the panel is stepping through several windows
/// in a row; it goes away when the pointer leaves it or a click lands elsewhere.
@MainActor
final class PanelController {

    /// Fraction of the screen's usable height the panel occupies.
    private static let heightFraction: CGFloat = 0.7
    private static let cornerRadius: CGFloat = 12
    private static let showDuration: TimeInterval = 0.14
    private static let hideDuration: TimeInterval = 0.10

    private(set) var isVisible = false

    /// Reported after every show/hide so the edge trigger knows the panel's
    /// frame and can apply the auto-hide rule.
    var onVisibilityChanged: ((Bool, NSRect) -> Void)?
    /// The user asked for the Accessibility permission from the panel.
    var onGrantAccessibility: (() -> Void)?

    private let config: Config
    private let store: SnapshotStore
    private let model = SwitcherViewModel()
    private let panel: SwitcherPanel
    private let visualEffect = NSVisualEffectView()

    private var clickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

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
        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in self?.model.update(snapshot: snapshot) }
            .store(in: &cancellables)
    }

    // MARK: - Show / hide

    func show(on screen: NSScreen) {
        let target = Self.frame(on: screen, width: config.panelWidth)

        if isVisible {
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
            onVisibilityChanged?(true, target)
            return
        }
        isVisible = true
        model.resetQuery()

        var start = target
        start.origin.x = target.minX - target.width
        panel.setFrame(start, display: false)
        panel.alphaValue = 0
        // Not `makeKeyAndOrderFront`: showing the panel must never pull the
        // keyboard away from whatever the user was working in.
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.showDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }

        installMonitors()
        store.setPanelVisible(true)
        onVisibilityChanged?(true, target)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        releaseKeyboardFocus()
        removeMonitors()

        var target = panel.frame
        target.origin.x = panel.frame.minX - panel.frame.width
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.hideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
            }
        })

        store.setPanelVisible(false)
        onVisibilityChanged?(false, .zero)
    }

    /// Panel geometry: flush with the left edge of the screen's usable area,
    /// vertically centred, `heightFraction` of that area tall.
    static func frame(on screen: NSScreen, width: CGFloat) -> NSRect {
        let usable = screen.visibleFrame
        let height = (usable.height * heightFraction).rounded()
        let y = (usable.midY - height / 2).rounded()
        return NSRect(x: usable.minX.rounded(), y: y, width: width.rounded(), height: height)
    }

    // MARK: - Keyboard focus

    /// Claims key status for as long as the search field is in use. Called from
    /// the field's own click handler, never on show.
    private func takeKeyboardFocus() {
        guard isVisible else { return }
        panel.makeKey()
        model.searchFieldFocused = true
    }

    private func releaseKeyboardFocus() {
        model.searchFieldFocused = false
    }

    // MARK: - Activation

    /// Acts on a clicked row and leaves the panel up.
    private func activate(_ row: SwitcherRow) {
        let config = config
        if let window = row.window {
            model.markFrontmost(row)
            // Activation is an AppKit call and stays on the main thread; only
            // the Accessibility round trip, which can block for seconds if the
            // editor is busy, goes to a background queue.
            NSRunningApplication(processIdentifier: window.pid)?.activate()
            DispatchQueue.global(qos: .userInitiated).async {
                VSCodeWindows.focus(Self.reresolve(window, bundleID: config.editorBundleID))
            }
        } else if let project = row.project {
            DispatchQueue.global(qos: .userInitiated).async {
                VSCodeWindows.openProject(project, config: config)
            }
        }
        // The z-order has just changed; pull a fresh snapshot rather than wait
        // out the poll interval.
        store.refresh()
    }

    /// Looks the clicked window up again immediately before focusing it.
    ///
    /// A row carries the window as it was up to a second ago, and both fields
    /// `VSCodeWindows.focus` matches on have moved by then: the title tracks the
    /// active editor and the chat topic, and the index is the z-order that the
    /// previous click reshuffled. Stepping through several windows in a row —
    /// the whole point of leaving the panel up — would otherwise raise whatever
    /// had slid into the remembered slot.
    nonisolated private static func reresolve(_ window: VSCodeWindowInfo,
                                              bundleID: String) -> VSCodeWindowInfo {
        guard let rootName = window.rootName else { return window }
        let current = VSCodeWindows.listWindows(bundleID: bundleID)
        return current.first { $0.pid == window.pid && $0.rootName == rootName } ?? window
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
                guard !NSPointInRect(NSEvent.mouseLocation, self.panel.frame) else { return }
                self.hide()
            }
        }
    }

    private func removeMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }
}
