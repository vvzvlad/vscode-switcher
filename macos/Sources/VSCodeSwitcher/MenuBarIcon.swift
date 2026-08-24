import AppKit
import SwiftUI

/// The status item's picture: one bar for the fleet's weekly quota, and that
/// quota as a number under it.
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
/// green where the fleet is spending exactly what it may, then yellow, orange,
/// red — written once in `UsagePopoverView.ratioColor` and used by this picture
/// and the popover both.
///
/// What the fill is coloured by is not the number under it. The number is the
/// quota already spent, 0…100, which reaches the ramp's green anchor only at its
/// own top and could never say anything past it; the colour is the popover's
/// lead reading, the measured spend rate over what may be spent, which crosses
/// 100 in ordinary use and goes on to the far end of the ramp. They are two
/// readings of one week and the picture carries both.
///
/// Until this round the colour was a third quantity — a week's demand, estimated
/// here rather than measured — and it could disagree with the popover's own
/// reading about the verdict and not only the shade: measured 2026-08-24 the
/// estimate answered 92.3% while the figures in the popover answered 174.9%, so
/// this picture would have been calm over a fleet the popover called red. One
/// reading is now painted in one place.
///
/// **Past the allowance the frame and the number are coloured as well, because
/// the fill may not be there to colour.** The fill's *length* is the mean, and a mean
/// near zero leaves nothing to colour: the fill's own ink, counted off the
/// bitmap at scale 4 (2026-08-18), is 0.00 pt² at a mean of 0 and 2.12 pt² at 3%
/// — against 34.50 pt² at 50%. At 1% there is no fill at all, the shape being
/// narrower than `minimumVisibleFillWidth`.
/// That is not an exotic state — it is what the fleet looks like just after the
/// windows turn over, which is exactly when a 300% burn is worth knowing, and
/// the one glance this item exists for showed an empty outline and no warning
/// at all. So the colour goes on what is always drawn. A minimum fill width was
/// the other way to fix it and is refused: a capsule drawn at a mean of 0 is a
/// claim about quota that has not been spent, and the whole point of the dashed
/// bar above is that this file does not draw quantities it does not have.
/// Inside the allowance the frame and the number stay `labelColor` — the loud
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
/// One bar, not two: the user asked for the fleet's seven-day mean and nothing
/// else in the menu bar. The five-hour windows and the per-account figures are
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

    /// The whole picture, always this wide: the number's column, with the bar
    /// drawn across all of it. There is no second candidate — a floor of 20 pt
    /// stood here and could never win against a column of 27.
    static var width: CGFloat { numberColumnWidth }

    /// The line the number occupies, as the font lays it out.
    static var numberHeight: CGFloat { ceil(label(forPercent: 100).size().height) }

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
    /// difference is what happens the day the system font lays `100%` out one
    /// point taller. Stacked from the bottom (`numberHeight + gap`) the bar's top
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

    /// How wide the fill comes out for a figure — nought when there is none.
    ///
    /// One arithmetic, asked by the drawing and by `showsRatio`, because the two
    /// have to agree about whether there is a fill at all: the description reads
    /// the picture out to somebody who cannot see it, and it may only name what
    /// the picture drew.
    static func fillWidth(forPercent percent: Int?) -> CGFloat {
        guard let percent else { return 0 }
        return barFillBounds.width * CGFloat(min(100, max(0, percent))) / 100
    }

    /// The narrowest fill worth drawing: a quarter of a point, which is half a
    /// pixel on a 2x display — narrower than that the shape cannot cover a device
    /// pixel and what lands on screen is its own antialiasing.
    ///
    /// Where the line goes is measured and not reasoned, off the bitmap at
    /// scale 4 with the threshold taken off (2026-08-18, the fill's own coloured
    /// ink inside the bar): 0.00 pt² at a mean of 0, **0.25 pt² at 1%** — a shape
    /// 0.24 pt across — and **1.88 pt² at 2%**, at 0.48 pt. Sevenfold between two
    /// neighbouring figures is where a smudge becomes a mark, and the threshold
    /// goes in that gap; for scale, 3% is 2.12 pt² and 50% is 34.50. One figure
    /// is refused by it and no more, which is the point — a wider threshold would
    /// be throwing away readings that can be seen.
    ///
    /// On the width and not on the figure, because the width is what is seen: the
    /// bar is 24 pt wide inside its frame today, so a percentage point is 0.24 pt
    /// — and it is a different number of points the day the picture is a
    /// different size.
    static let minimumVisibleFillWidth: CGFloat = 0.25

    // MARK: - Labels

    /// Two points smaller than the row beside it used to be, and that is what
    /// makes the stack fit: `100%` at 11 pt is 33 points wide, at 9 pt it is 27,
    /// and the width of the picture is now the width of this string.
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

    /// Every percentage the icon can ever draw in ink, laid out once.
    ///
    /// The icon is redrawn whenever the figure changes, and laying a string out
    /// is the expensive half of drawing one. An array rather than a dictionary
    /// keyed by the same integer: the index is clamped into range before the
    /// lookup, so there is no absent case to invent an answer for.
    ///
    /// One table and not two. A second one held the warning colour until the
    /// colour became a ramp (§4) — there is no longer *a* warning colour to lay
    /// out, the ratio picks one out of a continuum, and a table of 101 strings per
    /// colour is not a table. What replaces it is one string laid out on demand
    /// below, which the redraw can afford: the figure changes once a minute at
    /// most, and only while the fleet is over capacity.
    private static let labels: [NSAttributedString] =
        (0...100).map { NSAttributedString(string: "\($0)%", attributes: attributes) }

    /// The label for a percentage, clamped into the range the table covers.
    /// Above 100 the quota is spent, and `100%` says exactly that.
    ///
    /// `colour` is about the spend *ratio*, which is a different quantity from
    /// the one being printed: the number is the mean already spent and it can be
    /// anything at all while the week is being asked for more than it holds.
    /// `nil` is ink, which is the calm state and the one the table serves.
    static func label(forPercent value: Int, in colour: NSColor? = nil) -> NSAttributedString {
        let ink = labels[min(100, max(0, value))]
        guard let colour else { return ink }
        return NSAttributedString(string: ink.string, attributes: attributes(in: colour))
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

    /// The pair of rates the bar is coloured by, or `nil` for a bar with nothing
    /// to say about it.
    ///
    /// One rule for both surfaces, asked of the popover rather than written out
    /// again — the same arrangement as `fillColor` below and for the same
    /// reason: two surfaces deciding separately when a figure has stopped
    /// standing for now would drift the day one of them was tuned. What the rule
    /// is, and why it has an age in it, is spelled out over
    /// `UsagePopoverView.headlineRates`.
    ///
    /// **What it asks for grew by one figure, and the picture goes colourless in
    /// one more state because of it.** The colour is now the ratio the popover's
    /// lead states — the measured spend rate over its allowance — so a gateway
    /// that reports quota and histories but names no `tokens` block leaves this
    /// picture in ink where it used to carry a ramp. That is the two surfaces
    /// agreeing rather than a loss: in exactly that state the popover already
    /// falls back to the weekly quota, and a menu bar warning about a reading the
    /// popover no longer shows is a warning nobody can go and read.
    ///
    /// The age half is not ceremony up here, and the argument that used to stand
    /// in this comment — "the figure is an average over two days, refreshed
    /// every ten minutes on purpose, and ten minutes cannot move it enough to
    /// matter" — assumed the refreshing. A `/gw/usage` outage skips the whole
    /// histories block (`UsageStore.poll`), so nothing is refreshed at all, no
    /// `allowanceFailure` is set, and a guard on the failure alone left this
    /// picture with a red frame nothing could clear over a figure last confirmed
    /// hours ago. Up here there is no room to write "as of a while ago", so the
    /// colour has to go rather than get a caveat.
    static func rates(for snapshot: UsageSnapshot,
                      now: Date = Date()) -> UsagePopoverView.HeadlineRates? {
        UsagePopoverView.headlineRates(for: snapshot, now: now)
    }

    /// Everything one picture is drawn from.
    ///
    /// `Equatable` so its owner can go on redrawing only when the reason to
    /// redraw really changed — a poll lands once a minute and mostly says the
    /// same thing twice. Two fields rather than one now, and both belong: the
    /// figure sets the number and the fill's length, the rates set the fill's
    /// colour.
    struct Reading: Equatable {
        var percent: Int?
        var rates: UsagePopoverView.HeadlineRates?
    }

    /// What one poll makes of the picture, with each half's own freshness rule
    /// already applied.
    ///
    /// The clock is an argument because one of those rules is an age
    /// (`rates(for:now:)`): with it the ceiling can be asked about without
    /// waiting twenty minutes of real time for one.
    static func reading(for snapshot: UsageSnapshot, now: Date = Date()) -> Reading {
        Reading(percent: percent(for: snapshot), rates: rates(for: snapshot, now: now))
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
    static func fillColor(for rates: UsagePopoverView.HeadlineRates?,
                          on background: UsagePopoverView.RampBackground) -> NSColor {
        guard let rates else { return .labelColor }
        return NSColor(UsagePopoverView.ratioColor(atPercent: rates.percent, on: background))
    }

    /// The ramp's colour for a reading the picture has to warn about, or `nil`
    /// while it does not — which is what the frame and the number are drawn in
    /// past the allowance, and the one place a colour rule here is still a step.
    ///
    /// **It is a step about whether to paint rather than about what to paint
    /// with.** Everything else on both surfaces takes the ramp at any figure
    /// (§4); this cannot, because the calm state has to stay calm — a menu bar
    /// that changed colour on every reading would be saying nothing with all of
    /// them. So the boundary stays where `HeadlineRates.isOverAllowance` puts it,
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
    /// Named once because three things read the same boundary and may not come
    /// apart: the frame, the number, and the description that reads the picture
    /// out to somebody who cannot see it.
    private static func warningColor(for rates: UsagePopoverView.HeadlineRates?,
                                     on background: UsagePopoverView.RampBackground) -> NSColor? {
        guard let rates, rates.isOverAllowance else { return nil }
        return NSColor(UsagePopoverView.ratioColor(atPercent: rates.percent, on: background))
    }

    /// Whether this picture says anything about the spend ratio at all.
    ///
    /// The ratio reaches the picture as colour and as nothing else, so there are
    /// two ways for it to reach nobody. A fill too narrow to see is not drawn at
    /// all (`drawBar` returns before it), and neither is one with no reading
    /// behind it — and inside the allowance everything else in the picture is
    /// ink, so at a mean of nought, or with the quota half failed, what is on
    /// screen is the picture an unmeasured fleet gets. Past the allowance the
    /// frame carries it whatever the mean says, which is what the tinting is for.
    ///
    /// It asks `fillWidth` and not the figure, and the difference is a percentage
    /// point wide: `(reading.percent ?? 0) > 0` stood here, which is `drawBar`'s
    /// old exit condition rather than a question about what can be seen. At 1%
    /// the fill is 0.24 pt across — less than half a pixel on a 2x display and
    /// 0.25 pt² of ink against 34.50 at 50% — and VoiceOver was told the picture
    /// carried a reading it does not carry.
    ///
    /// Asked by `describe`, and that is the point of naming it: the description
    /// is the picture read out to somebody who cannot see it, and a description
    /// that named a figure the picture is not carrying would be the reverse of
    /// what it is for. Measured with the gateway down and a stored reading of
    /// 60%: the picture drew no colour anywhere and VoiceOver said "Weekly quota:
    /// no data".
    /// It asks the boundary rather than the colour, and that is the second half
    /// of asking it once: `warningColor(for:) != nil` was the same question via a
    /// colour that then had to be built and thrown away, and with `reading.rates
    /// != nil` in the guard above it the presence of a figure was asked twice —
    /// half a condition that could not decide anything.
    /// `HeadlineRates.isOverAllowance` is where the boundary is named, so the
    /// frame, the number and this still read one thing.
    static func showsRatio(_ reading: Reading) -> Bool {
        guard let rates = reading.rates else { return false }
        return rates.isOverAllowance
            || fillWidth(forPercent: reading.percent) >= minimumVisibleFillWidth
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
    static func image(for reading: Reading, appearance: NSAppearance? = nil) -> NSImage {
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
            draw(reading, on: background(for: appearance))
        }
        image.unlockFocus()
        // Not a template any more: the fill's colour is the reading (see the
        // note at the top of this file), and the system would tint it away.
        image.isTemplate = false
        image.accessibilityDescription = describe(reading)
        return image
    }

    /// What the picture says, for a reader who cannot see it. The spend ratio is
    /// in here because in the picture it is carried by colour alone, and colour
    /// alone reaches nobody using VoiceOver — and it is in here on exactly the
    /// terms the picture carries it on (`showsRatio`), because the two have to
    /// say the same thing.
    static func describe(_ reading: Reading) -> String {
        let quota = reading.percent.map { "Weekly quota: \($0)%" } ?? "Weekly quota: no data"
        guard let rates = reading.rates, showsRatio(reading) else { return quota }
        return quota + ", " + UsagePopoverView.ratioLabel(for: rates) + " " + UsagePopoverView.ratioCaption
    }

    private static func draw(_ reading: Reading, on background: UsagePopoverView.RampBackground) {
        drawBar(reading, on: background)
        guard let percent = reading.percent else { return }
        let label = label(forPercent: percent, in: warningColor(for: reading.rates, on: background))
        let size = label.size()
        // Flush with the right edge of the picture, which is the right edge of
        // the column: the digits grow leftwards and the `%` never moves. And on
        // the bottom row of the stack, under the bar.
        label.draw(at: NSPoint(x: width - size.width, y: 0))
    }

    /// The bar. Filled in proportion when there is a reading, empty and dashed
    /// when there is not — a shape that reads as "nothing measured" rather than
    /// as a quota nobody has touched.
    private static func drawBar(_ reading: Reading, on background: UsagePopoverView.RampBackground) {
        let rect = barRect
        let radius = barHeight / 2
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: radius, yRadius: radius)
        outline.lineWidth = 1
        if reading.percent == nil { outline.setLineDash([2, 2], count: 2, phase: 0) }
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
        (warningColor(for: reading.rates, on: background)
            ?? NSColor.labelColor.withAlphaComponent(UsagePopoverView.calmFrameOpacity)).setStroke()
        outline.stroke()

        let inner = barFillBounds
        let filled = fillWidth(forPercent: reading.percent)
        // Narrower than a pixel is not a smaller reading, it is a mark nobody
        // can see — and `showsRatio` asks the same question of the same
        // arithmetic, so the description never names a colour that was not put
        // on screen.
        guard filled >= minimumVisibleFillWidth else { return }
        fillColor(for: reading.rates, on: background).setFill()
        NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY,
                                         width: filled, height: inner.height),
                     xRadius: inner.height / 2, yRadius: inner.height / 2).fill()
    }

}
