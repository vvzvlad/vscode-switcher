import AppKit
import SwiftUI

/// The status item's picture: one bar for the ratio the popover leads with —
/// percentage points of quota burned over the last two days against the points
/// the week refills over the same two days — and that ratio as a number under it.
///
/// Stacked rather than side by side, and that is the user's call: side by side
/// the item was 57 points wide and took a visible slice of a menu bar it shares
/// with a dozen others. The number stays — it is the reading; only its place
/// changed, which costs two points of the font size and buys thirty points of
/// menu bar.
///
/// No app glyph in front of it. There was one, and the user threw it out on
/// sight: an icon identifying the app says nothing a menu bar full of icons
/// does not already say, while the bar and the number are the whole reason
/// this item exists. Its 15 points went back to the menu bar.
///
/// Drawn rather than composed out of views, because a status item takes an
/// `NSImage` and nothing else.
///
/// **The picture is not a template, and owning the colour is the point.** A
/// template picture is tinted by the system for whatever the menu bar currently
/// is (light, dark, "reduce transparency", a coloured desktop showing through),
/// and a colour of our own would be fighting that every time — which is why the
/// colour used to live in the popover alone, where there is room to read it.
/// The owner gave that up deliberately: the bar's fill says how hard the week is
/// being pushed, and a glance at the menu bar without opening anything is the
/// whole reason for having the figure at all.
///
/// **What it says is a ramp and not two states.** Green while the week holds and
/// red once it does not was the first rule here, and it made a fleet at 40% look
/// like a fleet at 95%; the colour is now one continuous scale — cold blue, cyan,
/// green where the fleet is burning exactly what its week refills, then yellow,
/// orange, red — written once in `UsagePopoverView.ratioColor` and used by this
/// picture and the popover both.
///
/// **The number, the fill and the colour are one quantity, and that is this
/// round.** They were two: the number and the fill's length were the weekly
/// quota — the mean already spent, 0…100 — while the colour came off the spend
/// ratio, which crosses 100 in ordinary use. Two readings in a picture 27 points
/// wide, and a reader takes the shade for a reading of the number it is painted
/// on: the owner saw 54% of the week spent wearing the colour of a rate running
/// at 197% of what the week sustains, and asked for the ratio instead. The pair
/// pulls apart on any working afternoon — `--dump` on this machine two hours
/// apart, 2026-08-24: 55% of the week against a ratio of 54%, then 56% against
/// 145%. The quota barely moved and the verdict changed sides. It is the same correction the popover's lead took one
/// level up (`UsagePopoverView.headlineFigureColor`), and the quota did not
/// vanish with it — it is the supporting reading in the popover, one click away.
///
/// Before that the colour was a third quantity again — a week's demand,
/// estimated here rather than measured — and it could disagree with the
/// popover's own reading about the verdict and not only the shade: measured
/// 2026-08-24 the estimate answered 92.3% while the figures in the popover
/// answered 174.9%, so this picture would have been calm over a fleet the
/// popover called red. One reading is now painted in one place, and printed
/// there too.
///
/// **Past the refill rate the frame and the number are coloured as well**, which
/// survives the change but not the argument it used to stand on. That argument
/// was about a fill that might not be there to colour: the length was the mean,
/// and a mean near zero is what the fleet looks like just after its windows turn
/// over — exactly when a 300% burn is worth knowing — so the colour had to go on
/// what is always drawn. With the length now the ratio itself that case is gone
/// by construction: the fill is clamped at the refill rate, so anything the
/// boundary calls a warning has a *full* bar under it.
///
/// **What they buy instead is the crossing, and only a rendering can say so.**
/// The mean colour of each part, measured 2026-08-24 at scale 4 on the light
/// plate (the dark one is the same shape, in its own colours):
///
///                 fill                 frame                number
///      99.999%    0.091 0.455 0.145    ink                  ink
///     100.000%    0.091 0.455 0.145    0.091 0.455 0.146    0.091 0.455 0.146
///     105.000%    0.161 0.451 0.087    0.161 0.451 0.087    0.161 0.451 0.087
///     900.000%    0.745 0.173 0.141    0.745 0.173 0.142    0.745 0.173 0.141
///
/// The sentence that used to stand here — "105% and 900% are the same full
/// capsule, and the figure printed under it is the whole of what separates
/// them" — is refuted by both halves of that table. They are the same *length*
/// and not the same capsule: past the clamp the fill goes on carrying the whole
/// ramp, so one of the two is olive-green and the other is red, and the colour
/// separates them before any figure is read. And past the anchor the frame and
/// the number take the fill's own colour to within a thousandth in every
/// channel — the three means are over different pixel counts, so the last digit
/// need not agree — which is to say they repeat what the fill has already said.
///
/// What only they can say is the first row: at 99.999% they are ink, at
/// 100.000% they are the ramp. The fill cannot mark that step, because a
/// thousandth below the anchor it is already full *and* already that same
/// green — the crossing has no width in the length and none in the colour
/// either, and the frame and the number are the only parts of the picture that
/// change across it. Which is also why the boundary is a step about whether to
/// paint and not about what to paint with (`warningColor`).
/// Inside the refill rate the frame and the number stay `labelColor` — the loud
/// state has to be the one that means something, and a picture that changed
/// colour on every reading would be saying nothing with all of them.
///
/// The price of leaving `isTemplate` behind is the work the system used to do:
/// nothing that stands for *ink* may be drawn in a fixed colour, because black
/// ink vanishes on a dark menu bar. `labelColor` is dynamic and everything is
/// drawn inside `performAsCurrentDrawingAppearance`, and since the appearance is
/// now an input the picture has to be redrawn when *it* changes and not only when
/// the figure does — which is `AppDelegate.observeAppearance`. The ramp's own
/// colours are fixed rather than dynamic, and that is not the same hazard: they
/// are a reading and not ink, and they are the figures this project's system
/// greens and reds already resolve to on both menu bar appearances. What the
/// appearance does decide about them is how light or dark they have to be
/// drawn: each is held to a contrast floor against the plate it will sit on
/// (`UsagePopoverView.contrastFloor(on:)`, and the plate is `background(for:)`),
/// which is a second reason the picture is redrawn when the appearance moves.
///
/// One bar, not two: the user asked for one reading in the menu bar and nothing
/// else. The weekly quota, the five-hour windows and the per-account figures are
/// one click away.
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
    /// **What "the widest string" is came out of a measurement and not out of the
    /// old constant.** It used to be `100%`, and that was a fact about the quota:
    /// the figure had a top and the top was three digits. A ratio has none — the
    /// burn is a difference of percentage points over a span the gateway's own
    /// stamps set, so a short enough span makes it arbitrarily large — and a fixed
    /// column with an unbounded figure in it is not a layout question but a
    /// correctness one. Measured 2026-08-24 in this font: a digit advances 5.9729 pt and `%`
    /// 8.8588, so `999%` is 26.7776 pt and `1000%` is 32.7505. Drawn flush right
    /// in a 27 pt picture the four-digit string starts at −5.75 and the leading
    /// digit is clipped off by the image bounds — and what lands is, pixel for
    /// pixel, the drawing of `000%` (1947 inked pixels either way against 2085
    /// for `999%`, measured at scale 4), which is the loudest reading this item
    /// has turning into the calmest one it can draw.
    /// So the figure is capped instead (`ceilingPercent`), and this column is
    /// measured on the string that cap produces — `999%`, the same 27 pt the
    /// picture has always been, because three digits and a `%` are what it always
    /// held. The item does not grow, and nothing to its left moves.
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
    /// Measured down from the top edge rather than up from the number, and the
    /// difference is what happens the day the system font lays the number's
    /// widest string out one point taller. Stacked from the bottom (`numberHeight + gap`) the bar's top
    /// would be at 19 in a picture 18 points tall, and the row clipped off is
    /// bar *fill* — the reading itself, of which `insetBy(dy: 1.5)` leaves only
    /// 3 points. From the top edge the extra point comes out of the gap instead,
    /// which is the one part of the stack that is there to be spent. At today's
    /// figures the two are the same rect (`18 - 6 == 11 + 1`), and
    /// `contentHeight == height` is the test that notices when they stop being.
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
    /// Where the line goes is measured and not reasoned, off the bitmap at
    /// scale 4 with the threshold taken off (re-measured 2026-08-24, the fill's
    /// own coloured ink inside the bar): 0.00 pt² at a reading of 0, **0.19 pt²
    /// at 1%** — a shape 0.24 pt across — and **1.69 pt² at 2%**, at 0.48 pt.
    /// Ninefold between two neighbouring figures is where a smudge becomes a
    /// mark, and the threshold goes in that gap; for scale, 3% is 1.94 pt² and
    /// 50% is 34.50. One figure is refused by it and no more, which is the point
    /// — a wider threshold would be throwing away readings that can be seen.
    ///
    /// **The small figures moved at that re-measurement and the change of what
    /// fills the bar is not why.** The 2026-08-18 table read 0.25, 1.88 and 2.12
    /// where this one reads 0.19, 1.69 and 1.94; the widths are identical (0.24,
    /// 0.48, 0.72, 12.00 pt) and 50% reproduces exactly. What differs is the
    /// colour the ink was counted in: the old small readings were taken with the
    /// bar red, which is what a 300% *load* painted over a 1% mean, and a 1%
    /// ratio is at the cold end of the ramp — how much of a blue edge survives a
    /// chroma filter is not how much of a red one does. Numbers belong to their
    /// measurement whole, fixture and filter included; carrying them across a
    /// change in any of it is how "re-measured, same figures" gets written down
    /// without being true.
    ///
    /// On the width and not on the figure, because the width is what is seen: the
    /// bar is 24 pt wide inside its frame today, so a percentage point is 0.24 pt
    /// — and it is a different number of points the day the picture is a
    /// different size.
    static let minimumVisibleFillWidth: CGFloat = 0.25

    // MARK: - Labels

    /// Two points smaller than the row beside it used to be, and that is what
    /// makes the stack fit: three digits and a `%` at 11 pt are 33 points wide,
    /// at 9 pt they are 27, and the width of the picture is the width of that
    /// string.
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
    /// Three digits, because that is what the column already held: `999%` is
    /// 26.7776 pt against the 26.7776 of the `100%` it replaces (2026-08-24), so
    /// the cap is free and a fourth digit would cost 5.9729 pt of menu bar — 22%
    /// of this item — permanently, for the sake of a state whose reading is
    /// "further over than this picture can say" either way.
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
    /// **Laid out rather than looked up, and that is what the ratio costs.** A
    /// table of 101 strings stood here while the number was the quota, which has
    /// exactly 101 values; a ratio picks one out of a continuum and a table of a
    /// thousand strings per colour is not a table.
    ///
    /// What the swap costs is the difference between two *drawing* paths, and
    /// both of them size the string: the old one indexed the table and then
    /// called `size()` on what came back, exactly as `draw` still does.
    /// Re-measured 2026-08-24 on this machine (Apple M4, `-O`, 200 000
    /// iterations, this font and these attributes, three runs):
    ///
    ///     table lookup, no size()            0.006 µs
    ///     table lookup + size()  (old path)  1.97 µs
    ///     build + size           (new path)  3.16 µs
    ///     build only                         0.84 µs
    ///     building the 101-string table     84 µs
    ///
    /// So the ratio costs about 1.2 µs a redraw and not the thirtyfold the first
    /// row suggests — 0.006 µs is the price of indexing an array and nothing
    /// else, and setting it against the new path compares a lookup with a
    /// layout. The conclusion is unchanged either way: the picture is redrawn
    /// when its reading changes and the poll lands once a minute. It is the
    /// comparison that had to be between the two paths that existed.
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
    /// **This is now the whole of the picture and not only its colour, and the
    /// state where it answers `nil` is where the two surfaces part.** The popover
    /// falls back to the weekly quota as its lead; this one draws the empty
    /// dashed bar and no number. It is the rule this file has always applied to
    /// a figure it cannot qualify, one qualification along: the popover can put a
    /// caption under a figure saying which quantity it is, and there is no room
    /// for one in 27 points. A `54%` that is sometimes the ratio and sometimes
    /// the quota, with nothing on screen to say which, is read as whatever the
    /// item usually shows — and the wrong reading of the two is the calm one,
    /// since a week 92% spent would be wearing the colour of a fleet burning 92%
    /// of what its week refills. The quota is one click away, captioned, in the
    /// popover.
    ///
    /// The age half is not ceremony up here, and the argument that used to stand
    /// in this comment — "the figure is an average over two days, refreshed
    /// every ten minutes on purpose, and ten minutes cannot move it enough to
    /// matter" — assumed the refreshing. A `/gw/usage` outage skips the whole
    /// histories block (`UsageStore.poll`), so nothing is refreshed at all, no
    /// `historiesFailure` is set, and a guard on the failure alone left this
    /// picture with a red frame nothing could clear over a figure last confirmed
    /// hours ago. Up here there is no room to write "as of a while ago", so the
    /// reading has to go rather than get a caveat — and since the reading is now
    /// the whole picture, what goes is the whole picture.
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
    /// comes out of the ramp, where before it was one red the moment it was
    /// anything.
    ///
    /// What the far side actually looks like is a rendering and not a name.
    /// Measured off the drawn picture 2026-08-18
    /// (`testTheWarningIsNeverQuieterThanTheCalmStateItReplaces` prints the whole
    /// table), on a **light** menu bar: green at capacity,
    /// `rgb(0.091, 0.455, 0.146)`; a darkened yellow with a green cast at 115%,
    /// `rgb(0.381, 0.416, 0.079)` at hue 66.2 degrees — "yellow" was the word here
    /// and nobody had rendered it; a darkened amber at 120%,
    /// `rgb(0.479, 0.384, 0.091)` at 45.2 degrees; red at 130%,
    /// `rgb(0.745, 0.173, 0.142)`. On a **dark** menu bar the middle of the band
    /// is the ramp as written — 115% is its own yellow, `rgb(0.827, 0.902, 0.173)`
    /// — and only the hot end is moved, the floor lifting the red at 130% to
    /// `rgb(1.000, 0.506, 0.478)`, which is red with white in it rather than a
    /// darker red. Which way a plate moves a colour is the plate's own answer
    /// (`UsagePopoverView.legible(_:on:)`).
    ///
    /// Orange itself — hue 30 degrees — arrives at 123.61% on both plates, because
    /// that is where the line interpolated between green and red crosses it. No
    /// plate moves that and the old ceiling never moved it either: what the
    /// ceiling moved was how dark 115% was drawn, turning a yellow into an olive.
    ///
    /// Named once because the frame and the number read the same boundary and
    /// may not come apart. It used to be three: the description read it too,
    /// through `showsRatio`, back when the ratio reached the picture as colour
    /// and nothing else. The description no longer has to ask — the number it
    /// names is the number on screen, whatever colour that number is drawn in.
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
    /// one. Measured 2026-08-18 on this machine, a status item made in a scratch
    /// process:
    ///
    ///     system NSApp.effectiveAppearance : NSAppearanceNameDarkAqua
    ///     status button effectiveAppearance: NSAppearanceNameVibrantDark
    ///     --- after forcing NSApp.appearance = aqua ---
    ///     NSApp.effectiveAppearance : NSAppearanceNameAqua
    ///     status button effectiveAppearance: NSAppearanceNameVibrantDark
    ///
    /// The second half is the failure in miniature: `labelColor` resolves to
    /// black in `aqua` (measured `r=0 g=0 b=0`), the picture is rasterised
    /// through `lockFocus` and holds it, and black ink lands on a dark menu bar
    /// — the very thing the note at the top of this file promises to prevent.
    /// In life the two come apart because the menu bar follows the *wallpaper*:
    /// a light system theme over a dark desktop picture gives a dark menu bar
    /// while `NSApp.effectiveAppearance` says `aqua`. And they differ in their
    /// colours even when they agree in kind — `labelColor` is alpha 0.898 in
    /// `NSAppearanceNameVibrantDark` against 0.847 in `NSAppearanceNameDarkAqua`
    /// (same measurement).
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
        // Not a template any more: the fill's colour is the reading (see the
        // note at the top of this file), and the system would tint it away.
        image.isTemplate = false
        image.accessibilityDescription = describe(ratio)
        return image
    }

    /// What the picture says, for a reader who cannot see it.
    ///
    /// **It names the ratio, and it no longer has to ask whether the picture is
    /// carrying it.** While the ratio reached the drawing as colour and nothing
    /// else, this had to agree with the drawing about a fill too narrow to see
    /// and about a mean of nought — `showsRatio` was that agreement, and it is
    /// gone with the quota: the ratio is now the number, and the number is drawn
    /// whenever there is a ratio at all. One `nil` check answers for the whole
    /// picture.
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
        // a colour that *is* the warning cannot afford it. Measured 2026-08-18 on
        // the light plate, the same colours at 0.55 come out at 2.11 to 2.34 to 1
        // against 4.49 opaque — under the 3 to 1 that graphics need at every point
        // on the ramp — and darkening cannot rescue them: composited at 0.55 over
        // a plate of 0.883, even black reaches only 4.44, which is under the floor
        // the number holds this colour to. Softened, the frame would have to be a
        // second, darker colour, and one reading may not be two colours in a
        // picture 27 points wide.
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
