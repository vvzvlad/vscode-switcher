import AppKit
import SwiftUI

/// The status item's picture: one bar for the ratio the popover leads with —
/// percentage points of quota burned over the trailing
/// `FleetCapacity.burnWindowHours` against the points the week refills over the
/// same hours — and that ratio as a number under it.
///
/// Stacked rather than side by side, at the user's request: side by side the
/// item was 57 points wide. No app glyph in front of it — the bar and the
/// number are the whole reason this item exists. One bar, not two: the weekly
/// quota, the five-hour windows and the per-account figures are one click away.
///
/// Drawn rather than composed out of views, because a status item takes an
/// `NSImage` and nothing else.
///
/// **The picture is not a template, and owning the colour is the point**: the
/// bar's fill says how hard the week is being pushed, readable at a glance
/// without opening anything. The colour is one continuous ramp — cold blue,
/// cyan, green where the fleet is burning exactly what its week refills, then
/// yellow, orange, red — written once in `UsagePopoverView.ratioColor` and used
/// by this picture and the popover both.
///
/// **The number, the fill and the colour are one quantity** — the burn ratio.
/// A reader takes the shade for a reading of the number it is painted on, so
/// they may not carry different figures (the weekly quota and the ratio pull
/// apart on any working afternoon). It is the same rule the popover's lead
/// follows (`UsagePopoverView.headlineFigureColor`); the quota is the supporting
/// reading in the popover.
///
/// **Past the refill rate the frame and the number are coloured as well.** The
/// fill is clamped at the refill rate, so past it the length is constant but
/// the fill goes on carrying the whole ramp, and the frame and the number take
/// the fill's own colour. Measured mean colour of each part at scale 4 on the
/// light plate:
///
///                 fill                 frame                number
///      99.999%    0.091 0.455 0.145    ink                  ink
///     100.000%    0.091 0.455 0.145    0.091 0.455 0.146    0.091 0.455 0.146
///     105.000%    0.161 0.451 0.087    0.161 0.451 0.087    0.161 0.451 0.087
///     900.000%    0.745 0.173 0.141    0.745 0.173 0.142    0.745 0.173 0.141
///
/// What only the frame and number can say is the first row: at 99.999% they
/// are ink, at 100.000% they are the ramp. The fill cannot mark that step — a
/// thousandth below the anchor it is already full and already that green. That
/// is why the boundary is a step about whether to paint and not about what to
/// paint with (`warningColor`). Inside the refill rate the frame and the number
/// stay `labelColor` — the loud state has to be the one that means something.
///
/// Leaving `isTemplate` means doing the system's work: nothing that stands for
/// *ink* may be drawn in a fixed colour, because black ink vanishes on a dark
/// menu bar. `labelColor` is dynamic and everything is drawn inside
/// `performAsCurrentDrawingAppearance`, so the picture has to be redrawn when
/// the appearance changes and not only when the figure does
/// (`AppDelegate.observeAppearance`). The ramp's own colours are fixed — they
/// are a reading, not ink — but each is held to a contrast floor against the
/// plate it will sit on (`UsagePopoverView.contrastFloor(on:)`, and the plate
/// is `background(for:)`), which is a second reason to redraw when the
/// appearance moves.
@MainActor
enum MenuBarIcon {

    // MARK: - Geometry

    /// The height a status item image is drawn at.
    static let height: CGFloat = 18
    /// How tall the bar is drawn. Six points rather than five, because the fill
    /// *is* the reading: `insetBy(dy: 1.5)` leaves 3 pt of it at six and 2 pt at
    /// five, a third of the ink for nothing — the stack fits either way
    /// (`6 + 1 + 11 = 18`, exactly the height).
    static let barHeight: CGFloat = 6
    /// Between the bar and the number under it.
    static let gap: CGFloat = 1

    /// The number's own column, measured off the widest string the picture can
    /// ever draw, and reserved whether or not there is a number to put in it.
    ///
    /// A status item that resizes itself drags every item to its left along with
    /// it. Sized to the current string, this one would twitch on every change of
    /// a digit; sized to the current *state*, it would twitch again every time
    /// the gateway went away and came back. So the width is a constant, and the
    /// number is set flush with its right edge, which keeps the `%` in one place
    /// as the digits in front of it come and go.
    ///
    /// The ratio has no top of its own, and in this font `1000%` is 32.75 pt:
    /// drawn flush right in a 27 pt picture its leading digit is clipped and it
    /// reads as `000%`, the loudest reading turned into the calmest. So the
    /// figure is capped (`ceilingPercent`), and this column is measured on the
    /// string that cap produces — `999%`, 27 pt.
    static let numberColumnWidth: CGFloat = ceil(ceilingLabel.size().width)

    /// The whole picture, always this wide: the number's column, with the bar
    /// drawn across all of it. There is no second candidate — a floor of 20 pt
    /// stood here and could never win against a column of 27.
    static var width: CGFloat { numberColumnWidth }

    /// The line the number occupies, as the font lays it out.
    static var numberHeight: CGFloat { ceil(ceilingLabel.size().height) }

    /// Bar, gap, number — what has to fit inside `height`, and at these constants
    /// fills it exactly. Which is why there is no centring inset in this layout:
    /// there is no spare row to centre in, and each of the two things drawn is
    /// pinned to the edge it belongs to — the number to the bottom, the bar to the
    /// top. The gap between them is what is left over, and the only part of the
    /// stack that can afford to lose a point.
    static var contentHeight: CGFloat { barHeight + gap + numberHeight }

    /// Where the bar sits: on top, across the whole width.
    ///
    /// Measured down from the top edge rather than up from the number: if the
    /// system font ever lays the number out a point taller, the extra point
    /// comes out of the gap instead of clipping bar *fill*, of which
    /// `insetBy(dy: 1.5)` leaves only 3 points. At today's figures the two are
    /// the same rect (`18 - 6 == 11 + 1`), and `contentHeight == height` is the
    /// test that notices when they stop being.
    static var barRect: NSRect {
        NSRect(x: 0, y: height - barHeight, width: width, height: barHeight)
    }

    /// Where the number may draw, and nowhere else — in points from the *bottom*
    /// edge, which is the way this picture is drawn (`lockFocusFlipped(false)`).
    static var numberRows: ClosedRange<CGFloat> { 0...numberHeight }

    /// Inside the frame: where the fill is allowed, one and a half points in
    /// from the bar on every side so the stroke is not painted over.
    static var barFillBounds: NSRect { barRect.insetBy(dx: 1.5, dy: 1.5) }

    /// How wide the fill comes out for a reading — nought when there is none.
    ///
    /// **The bar stops at the refill rate**, exactly as the popover's lead bar
    /// does and for the reason written over that one: a scale stretched to three
    /// times the refill would put the point everything turns on a third of the way
    /// along. Past it the length says nothing more and the figure printed under
    /// it says the rest.
    ///
    /// The clamp is here rather than in `HeadlineRatio.ratio`, which is
    /// deliberately unclamped so the surfaces can still say by how much the
    /// refill rate was passed. That makes this the second clamp of the same kind
    /// in the app — `QuotaBar` holds the other — and both are facts about a
    /// drawing.
    static func fillWidth(for ratio: UsagePopoverView.HeadlineRatio?) -> CGFloat {
        guard let ratio else { return 0 }
        return barFillBounds.width * CGFloat(min(1, max(0, ratio.ratio)))
    }

    /// The narrowest fill worth drawing: a quarter of a point, which is half a
    /// pixel on a 2x display — narrower than that the shape cannot cover a device
    /// pixel and what lands on screen is its own antialiasing.
    ///
    /// Measured off the bitmap at scale 4, the fill's coloured ink inside the
    /// bar: 0.00 pt² at a reading of 0, **0.19 pt² at 1%** — a shape 0.24 pt
    /// across — and **1.69 pt² at 2%**, at 0.48 pt. Ninefold between two
    /// neighbouring figures is where a smudge becomes a mark, and the threshold
    /// goes in that gap; for scale, 3% is 1.94 pt² and 50% is 34.50. One figure
    /// is refused by it and no more. The ink figures depend on the colour (a 1%
    /// ratio is at the blue end of the ramp), so they are only valid with the
    /// fixture and filter they were taken with.
    ///
    /// On the width and not on the figure, because the width is what is seen: the
    /// bar is 24 pt wide inside its frame today, so a percentage point is 0.24 pt
    /// — and it is a different number of points the day the picture is a
    /// different size.
    static let minimumVisibleFillWidth: CGFloat = 0.25

    // MARK: - Labels

    /// 9 pt is what makes the stack fit: three digits and a `%` at 11 pt are
    /// 33 points wide, at 9 pt they are 27, and the width of the picture is the
    /// width of that string.
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    /// `labelColor` and not `black`: it is a dynamic colour, so the very same
    /// laid-out strings below come out dark on a light menu bar and light on a
    /// dark one, resolved at the moment they are drawn against whatever
    /// appearance `image` made current. Black ink was invisible on a dark menu
    /// bar the instant the picture stopped being a template.
    private static let attributes: [NSAttributedString.Key: Any] = attributes(in: .labelColor)

    private static func attributes(in color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    /// The highest ratio the picture prints, and the top of the drawn scale.
    ///
    /// Not a ceiling on the reading — the colour, the fill and everything the
    /// popover writes take the ratio as it is — a ceiling on the *string*, which
    /// this column has to hold whole. The figure has no top of its own (see
    /// `numberColumnWidth`), and the alternative to capping it is the leading
    /// digit falling off the left edge, which turns 1000% into `000%`.
    ///
    /// Three digits: a fourth would cost 5.97 pt of menu bar — 22% of this item —
    /// permanently, for a state whose reading is "further over than this picture
    /// can say" either way.
    ///
    /// **What is lost at the cap is stated rather than hidden**: at 1000% and at
    /// any figure above it the picture prints `999%`, which is a floor and not
    /// the reading. It is the loudest number the column can hold, over a full bar
    /// at the far end of the ramp, so the *verdict* is not capped with it; the
    /// figure survives **uncapped** — not exact — in the accessibility
    /// description, which has no width to run out of, and in `--dump`. Both of
    /// those round to a whole per cent, exactly as this column does; what is
    /// exact is the pair of rates `--dump` prints beside it, points an hour
    /// burned against points an hour refilled.
    static let ceilingPercent = 999

    /// The widest string the number can be, laid out once: what the column is
    /// measured on and what the row's height comes from.
    ///
    /// Every three-digit figure is this wide — the font is
    /// `monospacedDigitSystemFont`, so digits advance equally — and it is built
    /// from the cap rather than written out, so that moving the cap moves the
    /// column with it instead of quietly overflowing it.
    private static let ceilingLabel = NSAttributedString(string: "\(ceilingPercent)%",
                                                         attributes: attributes)

    /// The label for a ratio: the figure rounded, clamped into the drawn scale,
    /// and laid out on demand.
    ///
    /// Laid out rather than looked up: a ratio picks one value out of a
    /// continuum, so there is no table to index. Building and sizing the string
    /// costs about 3 µs (Apple M4, `-O`), and the picture is redrawn only when
    /// its reading changes.
    ///
    /// The clamp is done in `Double` and before the conversion, which is not
    /// tidiness: `Int(1e300)` traps. Where such a number comes from is a span the
    /// gateway's own stamps made short — a burn per hour divides by it — and the
    /// arithmetic is written out over `UsagePopoverView.ratioLabel`, which meets
    /// the same hazard on the description's path and cannot clamp its way out of
    /// it.
    ///
    /// `≥` is not printed here, though the ratio can be a floor
    /// (`HeadlineRatio.isLowerBound`) — see `describe`, which does print it.
    static func label(for ratio: UsagePopoverView.HeadlineRatio,
                      in colour: NSColor? = nil) -> NSAttributedString {
        let value = Int(min(Double(ceilingPercent), max(0, ratio.percent.rounded())))
        return NSAttributedString(string: "\(value)%",
                                  attributes: colour.map { attributes(in: $0) } ?? attributes)
    }

    // MARK: - Value

    /// The ratio the whole picture is drawn from, or `nil` for a bar with nothing
    /// to say at all.
    ///
    /// One rule for both surfaces, asked of the popover rather than written out
    /// again — the same arrangement as `fillColor` below and for the same
    /// reason: two surfaces deciding separately when a figure has stopped
    /// standing for now would drift the day one of them was tuned. What the rule
    /// is, and why it has an age in it, is spelled out over
    /// `UsagePopoverView.headlineRatio`.
    ///
    /// **Where it answers `nil` the two surfaces part.** The popover falls back
    /// to the weekly quota as its lead, with a caption saying which quantity it
    /// is; this one draws the empty dashed bar and no number, because there is no
    /// room for a caption in 27 points. A `54%` that is sometimes the ratio and
    /// sometimes the quota would be read as whatever the item usually shows —
    /// and the wrong reading of the two is the calm one.
    ///
    /// The age half matters up here: a `/gw/usage` outage skips the whole
    /// histories block (`UsageStore.poll`), so nothing is refreshed and no
    /// `historiesFailure` is set, and a guard on the failure alone would leave
    /// a red frame nothing could clear over a figure last confirmed hours ago.
    /// Up here there is no room to write "as of a while ago", so the reading has
    /// to go rather than get a caveat — and since the reading is the whole
    /// picture, what goes is the whole picture.
    static func ratio(for snapshot: UsageSnapshot,
                      now: Date = Date()) -> UsagePopoverView.HeadlineRatio? {
        UsagePopoverView.headlineRatio(for: snapshot, now: now)
    }

    /// The bar's fill colour.
    ///
    /// Asked of the popover rather than written out again, and that is the whole
    /// of "matching the popover": the two surfaces cannot drift into two ramps,
    /// because there is one and this is a conversion of it. `labelColor` when
    /// there is no ratio — a bar drawn in a colour that meant something would be
    /// answering a question nobody could answer.
    ///
    /// The plate goes with the question because the rule needs it: hue and
    /// saturation are the same on both, and how dark the colour has to be drawn
    /// is a fact about what it sits on
    /// (`UsagePopoverView.ratioColor(atPercent:on:)`).
    static func fillColor(for ratio: UsagePopoverView.HeadlineRatio?,
                          on background: UsagePopoverView.RampBackground) -> NSColor {
        guard let ratio else { return .labelColor }
        return NSColor(UsagePopoverView.ratioColor(atPercent: ratio.percent, on: background))
    }

    /// The ramp's colour for a reading the picture has to warn about, or `nil`
    /// while it does not — which is what the frame and the number are drawn in
    /// past the refill rate, and the one place a colour rule here is still a step.
    ///
    /// **It is a step about whether to paint rather than about what to paint
    /// with.** Everything else on both surfaces takes the ramp at any figure
    /// (§4); this cannot, because the calm state has to stay calm — a menu bar
    /// that changed colour on every reading would be saying nothing with all of
    /// them. So the boundary stays where `HeadlineRatio.isOverRefill` puts it,
    /// which is the ramp's own green anchor, and the colour on the far side of it
    /// comes out of the ramp.
    ///
    /// What the far side looks like, measured off the drawn picture
    /// (`testTheWarningIsNeverQuieterThanTheCalmStateItReplaces` prints the whole
    /// table), on a **light** menu bar: green at capacity,
    /// `rgb(0.091, 0.455, 0.146)`; a darkened yellow with a green cast at 115%,
    /// `rgb(0.381, 0.416, 0.079)` at hue 66.2 degrees; a darkened amber at 120%,
    /// `rgb(0.479, 0.384, 0.091)` at 45.2 degrees; red at 130%,
    /// `rgb(0.745, 0.173, 0.142)`. On a **dark** menu bar the middle of the band
    /// is the ramp as written — 115% is its own yellow, `rgb(0.827, 0.902, 0.173)`
    /// — and only the hot end is moved, the floor lifting the red at 130% to
    /// `rgb(1.000, 0.506, 0.478)`, which is red with white in it rather than a
    /// darker red. Which way a plate moves a colour is the plate's own answer
    /// (`UsagePopoverView.legible(_:on:)`). Orange itself — hue 30 degrees —
    /// arrives at 123.61% on both plates, where the line interpolated between
    /// green and red crosses it.
    ///
    /// Named once because the frame and the number read the same boundary and
    /// may not come apart.
    private static func warningColor(for ratio: UsagePopoverView.HeadlineRatio?,
                                     on background: UsagePopoverView.RampBackground) -> NSColor? {
        guard let ratio, ratio.isOverRefill else { return nil }
        return NSColor(UsagePopoverView.ratioColor(atPercent: ratio.percent, on: background))
    }

    // MARK: - Drawing

    /// The appearance this picture has to be resolved against: the status item
    /// button's own, and the application's only while there is no button to ask.
    ///
    /// They are two different appearances, and the menu bar follows the button's
    /// one. Measured on a status item made in a scratch process:
    ///
    ///     system NSApp.effectiveAppearance : NSAppearanceNameDarkAqua
    ///     status button effectiveAppearance: NSAppearanceNameVibrantDark
    ///     --- after forcing NSApp.appearance = aqua ---
    ///     NSApp.effectiveAppearance : NSAppearanceNameAqua
    ///     status button effectiveAppearance: NSAppearanceNameVibrantDark
    ///
    /// The second half is the failure in miniature: `labelColor` resolves to
    /// black in `aqua`, the picture is rasterised through `lockFocus` and holds
    /// it, and black ink lands on a dark menu bar. In life the two come apart
    /// because the menu bar follows the *wallpaper*: a light system theme over a
    /// dark desktop picture gives a dark menu bar while
    /// `NSApp.effectiveAppearance` says `aqua`. And they differ in their colours
    /// even when they agree in kind — `labelColor` is alpha 0.898 in
    /// `NSAppearanceNameVibrantDark` against 0.847 in `NSAppearanceNameDarkAqua`.
    ///
    /// `NSView?` rather than the button's own type, because the rule is about
    /// having an appearance of one's own and a test can then hold it with any
    /// view.
    static func appearance(ofButton button: NSView?, system: NSAppearance) -> NSAppearance {
        button?.effectiveAppearance ?? system
    }

    /// Which plate this picture will be composited onto, told from the appearance
    /// it is drawn against — and what the ramp's contrast floor is computed
    /// against (`UsagePopoverView.RampBackground`).
    ///
    /// `bestMatch` rather than the name itself, and the measurement above is
    /// exactly why: the status item's button reports `NSAppearanceNameVibrantDark`
    /// on this machine, which is neither of the two names the plates are written
    /// in terms of, and a comparison against `.darkAqua` would answer "light" for
    /// the darkest menu bar there is.
    static func background(for appearance: NSAppearance) -> UsagePopoverView.RampBackground {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

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
    /// `nil` draws against the application's own appearance, which is the
    /// second-best answer and only a fallback — the picture belongs to the
    /// status item's button and the button has an appearance of its own
    /// (`appearance(ofButton:system:)`). A parameter at all so a test can ask
    /// for either without changing the machine it runs on — and the fallback is
    /// resolved *inside* this function rather than as a default value, because a
    /// default is evaluated at the call site and `NSApplication.shared` is
    /// main-actor isolated: written there it would put the isolation on every
    /// caller.
    static func image(for ratio: UsagePopoverView.HeadlineRatio?,
                      appearance: NSAppearance? = nil) -> NSImage {
        let appearance = appearance ?? NSApplication.shared.effectiveAppearance
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocusFlipped(false)
        // Every colour in `draw` is dynamic, and a dynamic colour resolves
        // against `NSAppearance.current` at the moment it is used — not when it
        // was written down, which for the number's attributes was at type
        // initialisation. Without this the picture takes whatever appearance
        // happened to be current on this thread.
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.current?.imageInterpolation = .high
            draw(ratio, on: background(for: appearance))
        }
        image.unlockFocus()
        // Not a template: the fill's colour is the reading (see the
        // note at the top of this file), and the system would tint it away.
        image.isTemplate = false
        image.accessibilityDescription = describe(ratio)
        return image
    }

    /// What the picture says, for a reader who cannot see it. It names the
    /// ratio — the same number the picture draws — so one `nil` check answers
    /// for the whole picture.
    ///
    /// Two things are said here that the drawing cannot say, and both are the
    /// same fact about a description having no width. `≥` — the ratio is a floor
    /// when the burn was measured over a partly blocked fleet, and a picture
    /// 27 points wide has no glyph to spare for it (`ceilingPercent`, and §4
    /// refuses a new mark on a surface without measured need). And the figure
    /// itself is uncapped, so where the drawing prints its `999%` this reads out
    /// the number that was measured.
    static func describe(_ ratio: UsagePopoverView.HeadlineRatio?) -> String {
        guard let ratio else { return "Weekly burn: no data" }
        return UsagePopoverView.ratioLabel(for: ratio) + " " + UsagePopoverView.ratioCaption
    }

    private static func draw(_ ratio: UsagePopoverView.HeadlineRatio?,
                             on background: UsagePopoverView.RampBackground) {
        drawBar(ratio, on: background)
        guard let ratio else { return }
        let label = label(for: ratio, in: warningColor(for: ratio, on: background))
        let size = label.size()
        // Flush with the right edge of the picture, which is the right edge of
        // the column: the digits grow leftwards and the `%` never moves. And on
        // the bottom row of the stack, under the bar.
        label.draw(at: NSPoint(x: width - size.width, y: 0))
    }

    /// The bar. Filled in proportion when there is a reading, empty and dashed
    /// when there is not — a shape that reads as "nothing measured" rather than
    /// as a fleet that is spending nothing.
    private static func drawBar(_ ratio: UsagePopoverView.HeadlineRatio?,
                                on background: UsagePopoverView.RampBackground) {
        let rect = barRect
        let radius = barHeight / 2
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: radius, yRadius: radius)
        outline.lineWidth = 1
        if ratio == nil { outline.setLineDash([2, 2], count: 2, phase: 0) }
        // Ink below capacity: the frame is the shape of the reading rather than
        // the reading, and a coloured outline around an empty bar would be saying
        // something about a fleet nobody measured. Above it the frame is the
        // only thing certain to be drawn, so it is where the warning has to go.
        //
        // **And the warning is drawn at full strength while the calm frame keeps
        // its softening.** The 0.55 belongs to a shape that stands for a reading;
        // a colour that *is* the warning cannot afford it. On the light plate the
        // same colours at 0.55 come out at 2.11 to 2.34 to 1 against 4.49 opaque —
        // under the 3 to 1 that graphics need at every point on the ramp — and
        // darkening cannot rescue them: composited at 0.55 over a plate of 0.883,
        // even black reaches only 4.44, which is under the floor the number holds
        // this colour to.
        //
        // The opacity is read from the ramp's own file rather than written here,
        // because what this line draws *is* the calm state the floor is derived
        // from (`UsagePopoverView.contrastFloor`). Two copies of it would let the
        // rule and the drawing disagree about what the warning is being compared
        // against.
        (warningColor(for: ratio, on: background)
            ?? NSColor.labelColor.withAlphaComponent(UsagePopoverView.calmFrameOpacity)).setStroke()
        outline.stroke()

        let inner = barFillBounds
        let filled = fillWidth(for: ratio)
        // Narrower than a pixel is not a smaller reading, it is a mark nobody
        // can see. It costs nothing that has to be said elsewhere: the figure is
        // printed under the bar at any width, and a fleet whose fill is this
        // narrow is burning one per cent of what its week refills.
        guard filled >= minimumVisibleFillWidth else { return }
        fillColor(for: ratio, on: background).setFill()
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY,
                                         width: filled, height: inner.height),
                     xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }

}
