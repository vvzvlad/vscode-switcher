import AppKit
import Foundation

/// Watches the pointer for the two gestures that drive the panel: resting
/// against the left screen edge next to where the panel will appear, and
/// walking away from an open panel.
///
/// The pointer is polled at 60 Hz through `NSEvent.mouseLocation`. A global
/// event tap would be the obvious alternative but needs the Accessibility (and
/// on some systems Input Monitoring) permission, and the panel has to work even
/// when that permission is missing — polling needs none.
@MainActor
final class EdgeTrigger {

    /// The pointer rested against the left edge of this screen long enough.
    var onEdgeDwell: ((NSScreen) -> Void)?
    /// The pointer walked away from the open panel and stayed away.
    var onPointerLeft: (() -> Void)?

    /// Poll rate. 60 Hz keeps the dwell measurement within one frame.
    private static let pollInterval: TimeInterval = 1.0 / 60.0
    /// How close to the edge counts as touching it.
    private static let edgeTolerance: CGFloat = 1.0
    /// After a dismissal the pointer has to get this far from the edge before
    /// the trigger arms again, so the panel cannot flicker back open.
    private static let rearmDistance: CGFloat = 100
    /// How far outside the panel the pointer has to be for an auto-hide.
    private static let leaveMargin: CGFloat = 60
    /// And for how long it has to stay there.
    private static let leaveDelay: TimeInterval = 0.4

    private let dwell: TimeInterval
    /// Kept whole because the trigger strip is derived from the panel geometry,
    /// which needs more than one field of it.
    private let config: Config

    private var timer: Timer?
    /// Frame of the panel while it is on screen, `nil` when it is hidden.
    private var panelFrame: NSRect?
    private var edgeEnteredAt: TimeInterval?
    /// Which screen's edge `edgeEnteredAt` was measured against. Without it a
    /// dwell begun on one display counted towards the dwell on another: 100 ms
    /// at the edge of A, then a jump to B, and B opened after 50 ms.
    private var edgeScreenFrame: NSRect?
    private var leftAt: TimeInterval?
    private var needsRearm = false
    /// The pointer has been inside the open panel's keep-open zone at least
    /// once. Until then the auto-hide countdown does not start.
    private var pointerWasInside = false

    init(config: Config) {
        self.config = config
        dwell = Double(config.dwellMilliseconds) / 1000.0
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Panel state

    /// The panel opened at `frame`; from now on only the auto-hide rule applies.
    func panelDidShow(frame: NSRect) {
        panelFrame = frame
        resetDwell()
        leftAt = nil
        // The panel can also be opened from the status item menu, and the
        // pointer is then in the opposite corner of the screen — outside the
        // keep-open zone from the very first tick, so the panel used to slide
        // back out 400 ms later. The countdown is armed only once the pointer
        // has actually been inside.
        pointerWasInside = false
    }

    /// The panel is still up and only moved or resized — a display was plugged
    /// in, the resolution or the Dock changed.
    ///
    /// Deliberately not `panelDidShow`: that one disarms the auto-hide by
    /// clearing `pointerWasInside`, and a screen notification landing while the
    /// pointer is already outside — the 400 ms are ticking — would zero a
    /// countdown that then never starts again, because the pointer never
    /// re-enters. The panel stayed on screen until a click landed elsewhere.
    /// `didChangeScreenParameters` arrives for a plugged-in display and a Dock
    /// setting too, not only for a resolution change.
    func panelDidMove(frame: NSRect) {
        guard panelFrame != nil else { return }
        panelFrame = frame
    }

    /// The panel closed. The trigger stays disarmed until the pointer moves
    /// clear of the edge.
    func panelDidHide() {
        panelFrame = nil
        resetDwell()
        leftAt = nil
        pointerWasInside = false
        needsRearm = true
    }

    private func resetDwell() {
        edgeEnteredAt = nil
        edgeScreenFrame = nil
    }

    // MARK: - Polling

    private func tick() {
        let point = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime

        // Checked before the screen is resolved: the auto-hide rule needs only
        // the panel's own frame, and an empty `NSScreen.screens` — which happens
        // while displays are being reconfigured — must not leave the panel stuck
        // on screen.
        if let panelFrame {
            resetDwell()
            // The panel covers only part of the screen height, so leaving it
            // upwards or downwards is just as ordinary as leaving it to the
            // right; testing a single axis would keep it open forever.
            let keepOpen = panelFrame.insetBy(dx: -Self.leaveMargin, dy: -Self.leaveMargin)
            guard !NSPointInRect(point, keepOpen) else {
                pointerWasInside = true
                leftAt = nil
                return
            }
            guard pointerWasInside else { return }
            if let leftAt {
                if now - leftAt >= Self.leaveDelay { onPointerLeft?() }
            } else {
                leftAt = now
            }
            return
        }

        leftAt = nil
        guard let screen = Self.screen(containing: point) else { return }

        // Only the stretch of the edge the panel itself will cover arms the
        // trigger, so the panel always appears right where the pointer already
        // is; the free strips above and below let the pointer run along the edge
        // without summoning it. The rect comes from the panel's own geometry —
        // and from the current screen's `visibleFrame`, not the main screen's —
        // so the strip cannot drift away from what it opens. That includes the
        // horizontal edge: the panel is placed against `visibleFrame.minX`, so
        // measuring the edge from `frame.minX` would bury the trigger strip
        // under a left-hand Dock while the panel came out to the right of it.
        let strip = PanelController.frame(on: screen, config: config)

        if needsRearm {
            resetDwell()
            if point.x > strip.minX + Self.rearmDistance { needsRearm = false }
            return
        }

        guard point.x <= strip.minX + Self.edgeTolerance else {
            resetDwell()
            return
        }

        // Only the dwell is reset on a vertical miss: the auto-hide timer lives
        // in the branch above and never reaches this code.
        guard point.y >= strip.minY, point.y <= strip.maxY else {
            resetDwell()
            return
        }

        guard let enteredAt = edgeEnteredAt, edgeScreenFrame == screen.frame else {
            edgeEnteredAt = now
            edgeScreenFrame = screen.frame
            // A zero dwell has to fire on the very first sample, not on the next.
            if dwell <= 0 {
                resetDwell()
                onEdgeDwell?(screen)
            }
            return
        }
        if now - enteredAt >= dwell {
            resetDwell()
            onEdgeDwell?(screen)
        }
    }

    /// The screen the pointer is on, with the main screen as a fallback for the
    /// gaps between differently sized displays.
    static func screen(containing point: NSPoint) -> NSScreen? {
        if let hit = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            return hit
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
