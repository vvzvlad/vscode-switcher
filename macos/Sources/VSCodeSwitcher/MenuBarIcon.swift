import AppKit

/// The status item's picture: one bar for the fleet's weekly quota, and that
/// quota as a number.
///
/// No app glyph in front of it. There was one, and the user threw it out on
/// sight: an icon identifying the app says nothing a menu bar full of icons
/// does not already say, while the bar and the number are the whole reason
/// this item exists. Its 15 points went back to the menu bar.
///
/// Drawn rather than composed out of views, because a status item takes an
/// `NSImage` and nothing else — and because `isTemplate` is the whole colour
/// policy here. The system tints a template picture for the current menu bar
/// appearance (light, dark, "reduce transparency", a coloured desktop showing
/// through), and a colour of our own would be fighting it every time. The fill
/// colour that says how bad 90% is lives in the popover, where there is room to
/// read it.
///
/// One bar, not two: the user asked for the fleet's seven-day mean and nothing
/// else in the menu bar. The five-hour windows and the per-account figures are
/// one click away.
@MainActor
enum MenuBarIcon {

    // MARK: - Geometry

    /// The height a status item image is drawn at.
    static let height: CGFloat = 18
    static let barWidth: CGFloat = 20
    static let barHeight: CGFloat = 6
    /// Between the bar and the number.
    static let gap: CGFloat = 4

    /// The number's own column, measured off `100%` — the widest string it can
    /// ever hold — and reserved whether or not there is a number to put in it.
    ///
    /// A status item that resizes itself drags every item to its left along with
    /// it. Sized to the current string, this one would twitch on every change of
    /// a digit; sized to the current *state*, it would twitch again every time
    /// the gateway went away and came back. So the width is a constant, and the
    /// number is set flush with its right edge, which keeps the `%` in one place
    /// as the digits in front of it come and go.
    static let numberColumnWidth: CGFloat = ceil(NSAttributedString(string: "100%",
                                                                   attributes: attributes).size().width)

    /// The whole picture, always this wide.
    static var width: CGFloat { barWidth + gap + numberColumnWidth }

    /// Where the bar sits, vertically centred.
    static var barRect: NSRect {
        NSRect(x: 0, y: ((height - barHeight) / 2).rounded(),
               width: barWidth, height: barHeight)
    }

    /// Where the number may draw, and nowhere else.
    static var numberColumn: ClosedRange<CGFloat> { (width - numberColumnWidth)...width }

    // MARK: - Labels

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.black
    ]

    /// Every percentage the icon can ever draw, laid out once.
    ///
    /// The icon is redrawn whenever the figure changes, and laying a string out
    /// is the expensive half of drawing one. An array rather than a dictionary
    /// keyed by the same integer: the index is clamped into range before the
    /// lookup, so there is no absent case to invent an answer for.
    private static let labels: [NSAttributedString] = (0...100).map {
        NSAttributedString(string: "\($0)%", attributes: attributes)
    }

    /// The label for a percentage, clamped into the range the table covers.
    /// Above 100 the quota is spent, and `100%` says exactly that.
    static func label(forPercent value: Int) -> NSAttributedString {
        labels[min(100, max(0, value))]
    }

    // MARK: - Value

    /// What the icon should show for a poll, or `nil` when it must show no
    /// number at all.
    ///
    /// Two holes answer `nil`, and the second is the one worth spelling out: a
    /// poll that failed carries the *previous* figures, kept on purpose so the
    /// popover can show slightly stale numbers rather than a blank. In the menu
    /// bar there is no room to say "as of a while ago", and a percentage with no
    /// such caveat is read as the truth right now — the same objection §2.4
    /// makes to a guessed context limit. An empty dashed bar says "no reading"
    /// without claiming one.
    ///
    /// `quotaFailure`, not any failure: this figure comes from `/gw/usage` and
    /// from nowhere else, while `/gw/sessions` — a different endpoint, feeding
    /// the per-project spend — used to blank out a quota reading that had just
    /// arrived intact.
    ///
    /// The rounding is not done here: `UsageSnapshot.fleetSevenDayPercent` is
    /// the figure, and the popover's headline reads the very same property. This
    /// function is that figure plus the one rule that belongs to the menu bar
    /// alone — which is exactly the difference between the two surfaces, and the
    /// only one there is.
    static func percent(for snapshot: UsageSnapshot) -> Int? {
        guard snapshot.quotaFailure == nil else { return nil }
        return snapshot.fleetSevenDayPercent
    }

    // MARK: - Drawing

    /// The status item image for one figure. `nil` draws the bar empty and
    /// dashed, with the number's column left blank.
    ///
    /// Rasterised here and now, rather than through
    /// `NSImage(size:flipped:drawingHandler:)`, which is otherwise the better
    /// API — it redraws itself at whatever scale the display needs. Its handler
    /// carries no promise about the thread it is called on, and everything this
    /// enum draws with (the laid-out labels, the font) is main-actor state. An
    /// eager rasterisation at the deepest screen's scale is one picture on one
    /// known thread, and the icon is redrawn on every change of the figure
    /// anyway.
    static func image(forPercent percent: Int?) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocusFlipped(false)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(percent: percent)
        image.unlockFocus()
        // Both halves matter. The `Template` suffix on a bundled file is what
        // usually sets this; an image built here has no name to carry it, and a
        // status item picture that is not a template is a flat black blob on a
        // dark menu bar.
        image.isTemplate = true
        image.accessibilityDescription = percent.map { "Недельная квота: \($0)%" }
            ?? "Недельная квота: нет данных"
        return image
    }

    private static func draw(percent: Int?) {
        drawBar(percent: percent)
        guard let percent else { return }
        let label = label(forPercent: percent)
        let size = label.size()
        // Flush with the right edge of the picture, which is the right edge of
        // the column: the digits grow leftwards and the `%` never moves.
        label.draw(at: NSPoint(x: width - size.width, y: ((height - size.height) / 2).rounded()))
    }

    /// The bar. Filled in proportion when there is a reading, empty and dashed
    /// when there is not — a shape that reads as "nothing measured" rather than
    /// as a quota nobody has touched.
    private static func drawBar(percent: Int?) {
        let rect = barRect
        let radius = barHeight / 2
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: radius, yRadius: radius)
        outline.lineWidth = 1
        if percent == nil { outline.setLineDash([2, 2], count: 2, phase: 0) }
        NSColor.black.withAlphaComponent(0.55).setStroke()
        outline.stroke()

        guard let percent else { return }
        let inner = rect.insetBy(dx: 1.5, dy: 1.5)
        let filled = inner.width * CGFloat(min(100, max(0, percent))) / 100
        guard filled > 0 else { return }
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY,
                                         width: filled, height: inner.height),
                     xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }

}
