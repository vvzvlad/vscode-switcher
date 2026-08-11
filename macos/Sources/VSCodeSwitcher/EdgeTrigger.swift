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
    private var leftAt: TimeInterval?
    private var needsRearm = false

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
        edgeEnteredAt = nil
        leftAt = nil
    }

    /// The panel closed. The trigger stays disarmed until the pointer moves
    /// clear of the edge.
    func panelDidHide() {
        panelFrame = nil
        edgeEnteredAt = nil
        leftAt = nil
        needsRearm = true
    }

    // MARK: - Polling

    private func tick() {
        let point = NSEvent.mouseLocation
        guard let screen = Self.screen(containing: point) else { return }
        let now = ProcessInfo.processInfo.systemUptime

        if let panelFrame {
            edgeEnteredAt = nil
            // The panel covers only part of the screen height, so leaving it
            // upwards or downwards is just as ordinary as leaving it to the
            // right; testing a single axis would keep it open forever.
            let keepOpen = panelFrame.insetBy(dx: -Self.leaveMargin, dy: -Self.leaveMargin)
            guard !NSPointInRect(point, keepOpen) else {
                leftAt = nil
                return
            }
            if let leftAt {
                if now - leftAt >= Self.leaveDelay { onPointerLeft?() }
            } else {
                leftAt = now
            }
            return
        }

        leftAt = nil

        if needsRearm {
            edgeEnteredAt = nil
            if point.x > screen.frame.minX + Self.rearmDistance { needsRearm = false }
            return
        }

        guard point.x <= screen.frame.minX + Self.edgeTolerance else {
            edgeEnteredAt = nil
            return
        }

        // Only the stretch of the edge the panel itself will cover arms the
        // trigger, so the panel always appears right where the pointer already
        // is; the free strips above and below let the pointer run along the edge
        // without summoning it. The rect comes from the panel's own geometry —
        // and from the current screen's `visibleFrame`, not the main screen's —
        // so the strip cannot drift away from what it opens. Only `edgeEnteredAt`
        // is reset here: the auto-hide timer lives in the branch above and never
        // reaches this code.
        let strip = PanelController.frame(on: screen, config: config)
        guard point.y >= strip.minY, point.y <= strip.maxY else {
            edgeEnteredAt = nil
            return
        }

        guard let enteredAt = edgeEnteredAt else {
            edgeEnteredAt = now
            // A zero dwell has to fire on the very first sample, not on the next.
            if dwell <= 0 {
                edgeEnteredAt = nil
                onEdgeDwell?(screen)
            }
            return
        }
        if now - enteredAt >= dwell {
            edgeEnteredAt = nil
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
