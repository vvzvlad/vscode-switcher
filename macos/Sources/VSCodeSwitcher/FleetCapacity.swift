import Foundation

/// Supply against demand over a week: whether the quota lasts until the windows
/// reset.
///
/// Utilisation per account cannot answer that question. The gateway routes
/// across several accounts, and each account's seven-day window resets on its
/// own schedule, handing back a whole 100 percentage points when it turns over.
/// So "89% spent" says only where one account stands inside a window that may
/// end in an hour or in six days; it says nothing about whether the week runs
/// out. What answers it is a rate against a supply:
///
///     capacity = 100 pp x accounts                     per 7 days
///     demand   = sum over accounts of (pp/h) x 168     per 7 days
///     load     = demand / capacity x 100
///
/// Measured live 2026-08-17 over three accounts: capacity 300 pp/week, demand
/// 378 pp/week, load 126% — the week was being asked for a quarter more than it
/// holds.
///
/// **Demand is estimated two ways, and the calculation window picks which.**
/// A window of a day or more contains a whole sleep cycle, so the plain average
/// over it is honest on its own and is extrapolated to a week exactly as it
/// always was. A window shorter than a day cannot contain one, and a plain
/// average over it is biased by whichever part of the day it happened to land
/// on: six hours of an evening read as a catastrophe, the same six hours over a
/// morning read as an idle fleet — measured 2026-08-18 on the live series, the
/// fleet's hourly rate runs 8.49 pp/h at 18:00 against 0.00 pp/h from 07:00 to
/// 14:00. The projection is the correction for exactly that. It takes the rate
/// from the recent *work* hours and pays the sleeping hours their own small
/// rate, so a short window buys responsiveness without buying the bias
/// (`projected`, and the boundary is `projectionWindowHours`).
///
/// Both paths answer with the same `FleetLoad`, and nothing downstream learns
/// which one ran: the surfaces, the guards, the colour ramp and the two stamps
/// read `percent`, `isLowerBound` and `accounts` and no more.
///
/// Nothing here fetches anything: it reads the series `UsageClient` already
/// brought back.

/// What one pass over the fleet found.
struct FleetLoad: Sendable, Equatable {
    /// Demand over capacity, in per cent. 100 is a fleet asked for exactly what
    /// it has; above that the quota runs out before the windows come back.
    let percent: Double
    /// An account sat at its ceiling while it was measured, so the demand it
    /// could not serve never entered its series at all: the real figure is at
    /// least this one, and the surface that prints it owes the reader a `≥`.
    /// Live example: acc2 spent 34 samples at 100 during the last 48 h.
    ///
    /// What it carries is that demand was suppressed, and nothing about how
    /// much: the requests an exhausted account turned away leave no trace to
    /// count, so the gap between this figure and the truth is unbounded — an
    /// account blocked for an hour and one blocked for two days raise the same
    /// flag. It is a warning that the number is a floor, not a margin on it.
    ///
    /// An account that spent the *whole* interval at the ceiling does not raise
    /// it, because it is not counted at all (`measure` refuses it, for the
    /// reason given there); that fleet is smaller by one in `accounts` instead.
    let isLowerBound: Bool
    /// How many accounts actually contributed a rate — which is exactly how
    /// many were counted into capacity. Not how many the gateway knows about.
    let accounts: Int
    /// The shortest per-account interval that went in. The answer is only as
    /// well measured as its worst-measured contributor, and the depths differ:
    /// 2.16 / 2.18 / 2.74 days over acc2 / acc3 / main, measured 2026-08-17
    /// (51.75 / 52.43 / 65.85 h).
    ///
    /// The gateway's `max_points` cap is not what makes the shallowest shallow,
    /// and the obvious reading of these three numbers is the wrong one: *two* of
    /// the accounts come back `truncated` at 2000 points, and the one that does
    /// not — main, at 1581 — is the deepest of the three. What separates them is
    /// how hard the gateway watches each account: 38.6 and 38.1 readings an hour
    /// on acc2 and acc3 against main's 24.0. The cap counts points, not hours,
    /// so the same 2000 points cover fewer hours the faster the samples are
    /// taken, and these spans belong to the day they were measured rather than
    /// to the source.
    ///
    /// It means the same thing on both paths and it is not what either figure is
    /// *built* from: the window average is built from the endpoints of that span,
    /// and the projection from the last few work hours inside it
    /// (`projection.recentWorkHours`) plus the hour-of-day split taken over the
    /// whole of it. What it says on both is how much watching stands behind the
    /// answer, which is why it survived the projection: a day-and-a-half of
    /// history classifies the hours of the day about as well as it measures a
    /// rate, which is to say only just.
    let measuredHours: Double
    /// What the projection was built from, or `nil` when the window average
    /// produced this figure. The presence of the value *is* which estimator ran
    /// — there is no separate flag to disagree with it.
    ///
    /// Nothing on any surface reads this. It exists for `--dump`, which owes the
    /// reader enough to rebuild the estimate by hand: a figure that moved because
    /// a setting moved must not look like a figure that moved because the fleet
    /// did.
    let projection: Projection?

    /// The parts of a projected demand, in the units the projection works in.
    ///
    /// `demand = recentWorkRate x workHoursPerDay x 7 + sleepRate x sleepHoursPerDay x 7`,
    /// both rates being fleet-wide sums of per-account rates, in percentage
    /// points per hour.
    struct Projection: Sendable, Equatable {
        /// How many hours of the day the fleet was found to be working in.
        /// Between 0 and 24: 24 is a fleet that burns around the clock, and then
        /// the projection is arithmetically the window average with a fresher
        /// rate; 0 is a fleet that burned nothing at all, and then demand is 0.
        let workHoursPerDay: Int
        /// Fleet pp/h over the most recent `recentWorkHours` of work hours.
        let recentWorkRate: Double
        /// Fleet pp/h over the sleeping hours of the whole measured history.
        /// Small but not zero — background agents do spend at night: 0.129 pp/h
        /// over three accounts, measured 2026-08-18.
        let sleepRate: Double
        /// How many work hours the recent rate actually came from, taken from
        /// the account that could offer the fewest. It is at least
        /// `FleetCapacity.minimumRecentWorkHours` and usually a little more than
        /// asked for, because the scan stops on the bucket that crosses the
        /// asked-for total rather than inside it.
        let recentWorkHours: Double

        /// The rest of the day. Named rather than derived at each use, because
        /// the two halves have to add up to 24 in every reader.
        var sleepHoursPerDay: Int { 24 - workHoursPerDay }
    }

    /// Spelled out rather than left to the memberwise initialiser so the
    /// projection can default to absent. Everything that builds one of these by
    /// hand — the surface tests, all twelve of them — is describing a figure to
    /// draw, and how it was estimated is not something a surface knows or draws.
    init(percent: Double,
         isLowerBound: Bool,
         accounts: Int,
         measuredHours: Double,
         projection: Projection? = nil) {
        self.percent = percent
        self.isLowerBound = isLowerBound
        self.accounts = accounts
        self.measuredHours = measuredHours
        self.projection = projection
    }

    /// At or above this the fleet is being asked for more than the week holds.
    ///
    /// Named once because several rules have to agree about it, and a boundary
    /// written twice is a boundary that can be moved once. Two of them read it
    /// now: it is the middle anchor of the colour ramp both surfaces are painted
    /// with (`UsagePopoverView.greenLoadPercent`, where the ramp is green), and
    /// it is the one place a colour rule is still a step rather than a ramp
    /// (`MenuBarIcon.warningColor`, below).
    static let capacityPercent: Double = 100

    /// Demand has caught up with supply. `>=`, not `>`: exactly 100 is a week
    /// with nothing left over, which is the state the warning is about.
    ///
    /// **Nothing chooses a colour with this.** The colour of both surfaces is a
    /// continuous ramp over the load (§4), and a figure either side of 100 is a
    /// hair either side of the same green. What this still decides is whether the
    /// status item's frame and number are painted at all — a fleet at 300% just
    /// after its windows turned over has no fill to colour, so the warning has to
    /// go on the ink, and below capacity the picture stays calm.
    var isOverCapacity: Bool { percent >= Self.capacityPercent }
}

/// The arithmetic of `FleetLoad`. Stateless, and deliberately not isolated to
/// any actor: it is pure arithmetic over values already in hand, and a
/// `@MainActor` annotation here would drag every `nonisolated async` caller onto
/// the main thread the moment it read one of the constants below (see the note
/// on `UsageStore.windowSeconds`).
enum FleetCapacity {

    /// A fall larger than this between two consecutive readings is a window
    /// reset, not the signal moving.
    ///
    /// Live data, re-measured 2026-08-17 — method: walk the consecutive non-null
    /// `util_7d` readings of `GET /gw/usage/<label>/history` for each of the
    /// three accounts and look at the falls. Inside a window the reading never
    /// fell by more than 1 pp, and that figure is 1 pp on all three accounts —
    /// it is the ±1 sawtooth of the two measuring sources (§4). The falls at a
    /// reset are 99 to 100 across the two resets on record: 99 → 0 on main and
    /// 100 → 0 on acc2, which is every reset the history holds. Anything
    /// strictly between 1 and 99 separates the two; 5 sits far from both ends,
    /// so neither a wider sawtooth nor a reset caught mid-fall lands on the
    /// boundary.
    ///
    /// Move it and the failure is not gradual. Below 1: every jitter tooth is
    /// charged as a whole restored window, +100 pp of burn for one point of
    /// disagreement. Above 99: a real reset reads as an account that un-burned
    /// its quota, and its burn comes out negative.
    static let resetDropThreshold: Double = 5

    /// The shortest interval an account may be extrapolated from.
    ///
    /// The measured rate is multiplied by `168 / span` to reach a week, so a
    /// short span is a large multiplier over a small measurement: at two hours
    /// of history a single percentage point — the exact size of the sawtooth —
    /// becomes 84 pp/week, more than four fifths of an account's whole quota.
    /// Six hours holds the multiplier at 28 and the sawtooth's worth at 28
    /// pp/week, which is noise the answer can carry.
    ///
    /// An account below this contributes neither a rate nor its 100 pp of
    /// capacity: an account we could not measure is not an account that spent
    /// nothing (§2.7, "unknown is not zero").
    static let minimumMeasuredHours: Double = 6

    /// The calculation window at which the estimator changes: below it the
    /// projection, at it and above it the window average.
    ///
    /// It is a day because a day is what holds a whole sleep cycle. Anything
    /// shorter averages over a slice of the day and inherits whichever slice it
    /// got — on the live fleet the extremes of the hour-of-day profile are
    /// 8.49 pp/h at 18:00 and 0.00 pp/h across 07:00–14:00 (2026-08-18, three
    /// accounts over 46.7 / 55.7 / 70.2 h), so a six-hour average is anywhere
    /// between nothing and three and a half times the day's mean of 2.47 pp/h
    /// depending only on when it was taken. At a day and over there is nothing
    /// for the projection to correct and it would be machinery for nothing.
    static let projectionWindowHours: Double = 24

    /// The fewest work hours the recent rate may be taken from.
    ///
    /// The rate is a burn over a span, and the span's endpoints each carry the
    /// one-sided ±1 pp sawtooth (§4), so the error in the rate is at most one
    /// point spread over the window — exactly `1 / hours` pp/h, confirmed rather
    /// than assumed by sliding every window position across the live history on
    /// 2026-08-18 and comparing raw endpoints against endpoints taken as a
    /// median of five: the largest disagreement is 0.4988, 0.2494, 0.1666,
    /// 0.1244 and 0.0830 pp/h at 2, 4, 6, 8 and 12 work hours, which is `1/N` to
    /// three figures every time. In load points over a three-account fleet that
    /// is `rate x work hours x 7 / 3`, and at 16 work hours in the day —
    /// which is what these figures were computed at, the split having since
    /// answered 14 — **18.6, 9.3, 6.2, 4.7 and 3.1 points**; at 14 the same
    /// column is 16.3, 8.1, 5.4, 4.1 and 2.7.
    /// The median disagreement is 0.0000 at every N — the tooth is rare, not
    /// gradual, so what these numbers bound is the bad window rather than the
    /// usual one.
    ///
    /// Four is where that stops dominating. At 2 the worst case is 18.6 points
    /// on a figure whose whole warning band is 30 points wide (100 to 130, §4),
    /// which is to say the noise can carry the reading from calm to red on its
    /// own; at 4 it is 9.3, at the default 6 it is 6.2. Below four there is no
    /// figure rather than a noisy one — the same trade `minimumMeasuredHours`
    /// makes for the window average.
    static let minimumRecentWorkHours: Double = 4

    /// The shortest history an account may be *projected* from, as against
    /// averaged over.
    ///
    /// A day, and for a different reason than `minimumMeasuredHours`: the
    /// projection splits the day into work hours and sleeping ones, and a series
    /// shorter than a day has not seen every hour of the day even once. An hour
    /// nobody watched is not a sleeping hour, it is an unknown one, and unknown
    /// is not zero (§2.7). An account below this contributes neither demand nor
    /// its 100 pp of capacity, exactly as one with too little history does on the
    /// other path.
    private static let minimumProjectionHours: Double = 24

    /// An hour of the day counts as a work hour when the fleet burns at least
    /// this share of its overall hourly rate in it.
    ///
    /// **The plateau this number was chosen for does not exist, and the figure
    /// the file used to quote for it was wrong.** What stood here said 15 work
    /// hours for every fraction in [0.41, 0.66]. Re-measured 2026-08-18 on the
    /// live history (three accounts, 46 h of overlap), the steps of the count are
    /// 0.01 → 20 hours, 0.10 → 19, 0.22 → 17, 0.37 → 16, 0.44 → 14, 0.88 → 12:
    /// **no fraction answers 15 at all**, and 0.45 answers 14. Over the 48 h the
    /// app actually fetches the steps are 0.01 → 20, 0.09 → 19, 0.22 → 17,
    /// 0.36 → 16, 0.43 → 14, 0.85 → 12 — the same shape, and 0.45 is two
    /// hundredths from the edge of its own plateau. The mechanism is worth
    /// naming: the hourly rates are whole percentage points over two or three
    /// observations of each hour of the day, so several hours land on exactly the
    /// same value and cross the threshold as a block. 05:00 and 14:00 both sit at
    /// 1.000 pp/h today, which is why the count steps 16 → 14 and never through
    /// 15.
    ///
    /// **It stays anyway, because every replacement measured is worse.** The
    /// review's own suggestion — sort the rates and cut at the largest gap
    /// between adjacent values — answers **2 work hours in 19 of 21 sub-windows**:
    /// the widest gap in the profile is between the evening peak (7.757 pp/h) and
    /// the hour below it (6.000), so it cuts the peak off rather than the sleeping
    /// block. Method for all of them (2026-08-18): recompute the split over every
    /// sub-window the history allows — each end offset from 0 to 24 h in steps of
    /// 3 h, each length from 24 h to the whole depth — and group the results by
    /// the instant the window *ends*. Inside a group the fleet's recent behaviour
    /// is the same and only the classification depth moves, so the spread inside a
    /// group is the rule's own unsteadiness rather than the fleet's. Mean spread
    /// within one instant, in load points and in work hours:
    ///
    ///     fraction 0.45      4.0 points   0.43 h
    ///     fraction 0.35      5.6          0.57
    ///     fraction 0.55      5.8          0.71
    ///     hours above the median rate     5.8   0.57
    ///     Otsu (least within-class variance)    6.2   0.57
    ///     largest gap between adjacent rates    18.8  2.57
    ///
    /// The fraction is the steadiest of the six on both columns. That the line
    /// sits a hundredth from a step in *one* window does not make it unsteady
    /// across windows: the step moves with the data, and proximity in one cut
    /// predicts nothing about the next.
    ///
    /// **One hour moved between the classes costs about 10 points of load, not
    /// the 3 this file used to claim.** Measured end to end at the newest instant
    /// over 48 h of history with a 6 h recent window (2026-08-18): 20 work hours
    /// answer 36%, 19 → 45%, 17 → 89%, 16 → 93%, 14 → 112%, 12 → 119%. So 17 → 16
    /// is 4.6 points and 16 → 14 is 18.8, and the per-hour cost runs from 3.6 to
    /// 21.9 depending on which hour crosses. The old figure treated the split as
    /// if it only moved the two multipliers; it moves both *rates* as well, since
    /// an hour leaving the work class takes its burn out of the recent rate and
    /// puts it into the sleeping one.
    ///
    /// It is a share of the mean rather than an absolute rate on purpose: a
    /// quiet fleet and a busy one have the same shape of day, and a fixed pp/h
    /// threshold would call every hour of a quiet week a sleeping hour.
    private static let workHourFraction: Double = 0.45

    /// The days a week has, as the projection counts them: the same seven
    /// `hoursPerWeek` is 168 of, spelled separately because the projection
    /// multiplies hours-per-day by it rather than dividing into a week.
    private static let daysPerWeek: Double = 7

    /// The hours a day has, and the sum the two classes are held to.
    private static let hoursPerDay: Int = 24

    /// The whole width of the sawtooth, in percentage points.
    ///
    /// A reading is the truth or the truth minus one and never above it (§2.7,
    /// re-measured 2026-08-18 over 5844 steps on three accounts: the deepest
    /// fall that is not a reset is exactly −1.0 pp on all three), and the truth
    /// inside a window cannot fall. So a fall past this with no reset to explain
    /// it is something restoring the window, and that is the refusal both
    /// estimators make — `windowAverage` over the whole span, `projected` over
    /// each step.
    private static let sawtoothPP: Double = 1

    /// The reading at which an account is out of quota and its demand stops
    /// being visible. The gateway reports utilisation as per cent, 0…100, so
    /// this is the ceiling itself rather than a margin below it.
    private static let ceilingPercent: Double = 100

    /// One account's whole quota per window, in percentage points. This is what
    /// makes capacity a countable thing: an account is worth exactly one window
    /// per week, whatever it spent last week.
    private static let quotaPerAccount: Double = 100

    /// The window everything here is denominated in, and it is exactly seven
    /// days: measured 2026-08-17 on both accounts whose history holds a reset,
    /// the announced next reset falls 7.0002 days after the last reading of the
    /// window that ended. Counted from the first zero reading instead it is
    /// 6.9995 days on main and 6.9967 on acc2, and that shortfall is the lag of
    /// the sample that caught the reset (42 s and 285 s — 0.0005 d and 0.0033 d,
    /// which is what those two shortfalls are), not a shorter window. Both the
    /// extrapolation to a week and the window start derived from `resetsAt`
    /// stand on that.
    ///
    /// The lag is measured as the first zero reading minus the announced
    /// boundary, and the boundary is `resets_at` from `GET /gw/usage` minus
    /// seven days — the reset the history holds belongs to the window that is
    /// running now. Numbers that stood here before, 63 s and 306 s, are a
    /// different quantity: the gap between the two samples straddling the reset.
    /// They do not match the shortfalls above and never did.
    private static let hoursPerWeek: Double = 168

    /// Load over the whole fleet, or `nil` when it cannot be measured.
    ///
    /// The window picks the estimator, and the boundary is
    /// `projectionWindowHours` — strictly under a day is the projection, a day
    /// and over is the average this function has always taken. The reason is in
    /// the file header: a window shorter than a day cannot hold a whole sleep
    /// cycle, so its average is a statement about the part of the day it landed
    /// on rather than about the week.
    ///
    /// The window is the *calculation* window and not the request: on the
    /// projection path the histories still come back over the fixed span
    /// `UsageStore.fleetLoadWindowSeconds`, because classifying the hours of the
    /// day needs a whole day of them however few of those hours the recent rate
    /// is taken from.
    static func load(histories: [String: HistorySeries],
                     accounts: [AccountUsage],
                     windowHours: Double = Config.default.usageLoadWindowHours,
                     timeZone: TimeZone = .current) -> FleetLoad? {
        guard windowHours < projectionWindowHours else {
            return windowAverage(histories: histories, accounts: accounts)
        }
        return projected(histories: histories,
                         accounts: accounts,
                         recentWorkHours: windowHours,
                         timeZone: timeZone)
    }

    /// Demand as the average burn over the whole measured window, extrapolated
    /// to a week. The estimator four reviews approved, unchanged.
    ///
    /// `accounts` says which accounts the fleet has — a history under a label
    /// the fleet does not have is not demand anybody can serve — and it hands
    /// `measure` each account's seven-day `resetsAt`. What it is deliberately
    /// *not* read for is `utilization` as the right-hand endpoint. That figure
    /// and the histories come from two different requests polled at two
    /// different moments, and neither body says which of the two is the later
    /// one — splicing it onto the end of a series moves that endpoint by a point
    /// in an unknown direction, and one point is the entire size of the effect
    /// the endpoint rule below exists to survive. The series' own last sample is
    /// the endpoint, always.
    ///
    /// `resetsAt` crosses that same gap between two requests safely, and the
    /// difference is what the two figures do with time: `utilization` moves
    /// every few minutes, so a skew of one poll is a real change of value, while
    /// a window boundary moves once a week — a minute of skew cannot move it at
    /// all. For the same reason this function takes no clock: there is nothing
    /// for it to decide.
    ///
    /// Returns `nil` rather than a confident wrong number when no account
    /// contributed — including the case where every account's history is too
    /// shallow to extrapolate from. A missing figure beats a wrong one (§2.7).
    ///
    /// **The points must be the gateway's own, not smoothed ones**, and whoever
    /// wires this up has to check: the other loader hands out smoothed points,
    /// `UsageHistoryModel.load` returning `withoutSourceLag(answer.points)`
    /// because the chart wants the sawtooth gone. Passing that here is not a
    /// visible mistake — the filter never touches the ends the burn is taken
    /// from, and over the live history it changes nothing this reads: 145 / 154 /
    /// 77 teeth over acc2 / acc3 / main and not one of them at the ceiling,
    /// because all 120 ceiling readings on acc2 sit in runs (measured
    /// 2026-08-17, median of three over the non-null `util_7d` readings). The
    /// exposure is the whole account, and it grew that far when the ceiling
    /// refusal was added: a lone reading *below* the ceiling among ceiling
    /// readings — a 99 between two 100s — is exactly the shape a median of three
    /// deletes, and it is the only thing holding `everBelowCeiling` true for an
    /// account otherwise pinned at 100. Smooth it away and `measure` refuses the
    /// account outright, taking its 100 pp of capacity out of the denominator
    /// along with its demand and moving the fleet figure up. **Up because of
    /// which account it is**, and not because dropping one always raises the
    /// figure — dropping an account pulls the load towards the mean of the ones
    /// that remain, either way round, and `hourBuckets` works that arithmetic
    /// through. Here the lost account is one pinned at its ceiling, whose
    /// measured burn is a suppressed near-zero and therefore under that mean, so
    /// this particular loss can only push upwards. The mirror shape, a
    /// lone 100 between two 99s, is the cheap one: it costs `hitCeiling`, which
    /// is the `≥` on a figure that still gets printed.
    ///
    /// Both are the ordinary one-sample tooth, common enough to plan for: of the
    /// downward excursions in the live history 18 / 130, 19 / 136 and 6 / 83 are
    /// one sample wide over acc2 / acc3 / main (2026-08-17, an excursion being a
    /// fall too small for a reset that later returns to the level it fell from).
    /// It has not been caught at the ceiling itself — acc2's ceiling readings
    /// that day are one unbroken run — but nothing about the ceiling makes the
    /// two measuring sources agree any better there.
    private static func windowAverage(histories: [String: HistorySeries],
                                      accounts: [AccountUsage]) -> FleetLoad? {
        var demandPerHour = 0.0
        var contributors = 0
        var shortestHours = Double.greatestFiniteMagnitude
        var blocked = false

        for account in accounts {
            guard let series = histories[account.label],
                  let measured = measure(series.points,
                                         resetsAt: account.sevenDay?.resetsAt) else { continue }
            // Per account, then summed: the accounts have different history
            // depths, and dividing one total by the longest span would credit
            // the shallow account with the hours nobody measured it over.
            demandPerHour += measured.burnPP / measured.hours
            contributors += 1
            shortestHours = min(shortestHours, measured.hours)
            blocked = blocked || measured.hitCeiling
        }

        guard contributors > 0 else { return nil }
        // Capacity counts the contributors and nobody else: an account that
        // could not be measured must never widen the denominator its own demand
        // is missing from.
        let capacity = Double(contributors) * quotaPerAccount
        let demand = demandPerHour * hoursPerWeek
        return FleetLoad(percent: demand / capacity * 100,
                         isLowerBound: blocked,
                         accounts: contributors,
                         measuredHours: shortestHours,
                         projection: nil)
    }

    /// What one account's series says about it.
    ///
    /// Internal rather than private because the projection's decomposition has
    /// to be checked against it: `testHourBucketsReconcileWithTheSpanMethod`
    /// sums the buckets and asks this function for the same stretch, which is
    /// the one thing that keeps the two estimators talking about the same burn.
    struct Measurement {
        /// Percentage points burned over `hours`, never negative.
        var burnPP: Double
        var hours: Double
        /// The account was at its ceiling at least once while it was measured,
        /// and below it at least once too — a series that never left the ceiling
        /// has no `Measurement` at all.
        var hitCeiling: Bool
    }

    /// One account's burn and the span it was burned over, or `nil` when the
    /// series cannot answer. `resetsAt` is the end of the account's current
    /// seven-day window; it is what places a reset that fell inside a hole, but
    /// only over readings that already show one happened. `nil` when the gateway
    /// did not name a window.
    ///
    /// **Burn is the endpoints plus the resets between them, and never a sum of
    /// the series' positive steps.** The reading is integer-valued and jitters
    /// by ±1 pp, because the gateway's own poll and the values lifted out of API
    /// response headers disagree by a point for about one five-minute cycle
    /// (§4). Every tooth of that sawtooth has a rising edge, and a sum of
    /// positive deltas charges every one of them as spend. Re-measured 2026-08-18
    /// over the whole depth of the three series: on acc2 (2000 readings over
    /// 46.79 h) the sum answers 198 pp where the endpoints say the account burned
    /// 56 — every one of those 198 a single-point step, an overstatement of 3.5
    /// times; 185 against 51 on acc3 over 54.23 h and 119 against 23 on main over
    /// 67.83 h. (The figure that stood here, "158 pp against 50 over 62 h on
    /// acc2", carried no date and no depth that matches one.) Endpoints cannot
    /// *accumulate* that error, which is the whole point: whatever the signal
    /// did in between, an account that reads 50 now and read 0 then has spent
    /// 50. What an endpoint can still do is land on a tooth of its own, and that
    /// is bounded and measured — sliding a 24 h window across the live history
    /// one sample at a time (2026-08-17), the raw endpoints disagree with
    /// endpoints taken as a median of the five outermost readings in 13% / 19% /
    /// 6% of windows over acc2 / acc3 / main. The disagreement is one point wide
    /// and one-sided *downward*: a reading is either the truth or the truth minus
    /// one, never above it. So a figure carries ±1 pp at worst rather than the
    /// ±2 of two teeth pointing opposite ways, and the most a pair of endpoints
    /// can understate by is one point, never two. Since the truth inside a
    /// window cannot fall either, an interval with no reset in it can read −1
    /// and nothing lower — which is the whole reason the refusal below asks
    /// `rawChange < -1` and not `< -2`.
    ///
    /// Re-measured 2026-08-17 over the deepest series each account serves
    /// (2000 / 2000 / 1558 readings over 53.7 / 52.1 / 65.5 h), two ways.
    /// Plateaus: over every stretch of at least 100 consecutive readings whose
    /// values span a single point and whose level holds four fifths of them, not
    /// one reading sits above the level — 0 against 17 / 47 / 22 below it over
    /// acc2 / acc3 / main. Pairs: over every two readings less than 24 h apart
    /// with no reset between them, the smallest `v[j] − v[i]` is exactly −1 pp on
    /// all three accounts, where a two-sided tooth would answer −2 as soon as the
    /// earlier reading sat high and the later one low.
    ///
    /// `+ 100` per reset is the one approximation, and it errs upward on
    /// purpose: it charges the stretch before a reset as if the window had been
    /// spent to its ceiling. An account whose window turned over at 93 is
    /// credited with the 7 pp it never got to spend. The error is bounded by
    /// exactly that headroom — by the reading the window turned over at — and on
    /// the live fleet that headroom is small: both resets the history has held
    /// went from 100 (acc2) and from 99 (main), which is 0 pp and 1 pp
    /// (2026-08-17; the 2026-08-18 re-measure over the full depth keeps the one
    /// that survived retention, main's 99 → 0). The 7 is the example above, not
    /// an observation. It overstates load,
    /// which is the safe direction for a question that reads "will my tokens
    /// last". The bound holds only for a reset the series showed: for one
    /// inferred from `resetsAt` the pre-reset reading was never observed, so the
    /// charge can be a whole window over an account that had spent little of it.
    ///
    /// Nothing is smoothed on the way in, and `UsageHistoryModel.withoutSourceLag`
    /// is declined even though it would leave these endpoints where they are — it
    /// iterates `1..<(points.count - 1)`, and untouched edges are a requirement
    /// of §4 that two tests hold. Smoothing an endpoint is not a fix but a
    /// hazard, and the cost was measured on a real window: main over the 24 h
    /// ending with its reset at 2026-08-16 15:00:42 UTC sat at its ceiling the
    /// whole time and turned over on the last sample, so its 284 readings begin
    /// `99, 99, 99, 99, 99, 99` and end `99, 99, 0`. Raw endpoints answer `0 − 99 + 100 = 1 pp`, which is
    /// right: an account pinned at its ceiling burned about a point. Median
    /// endpoints answer `99 − 99 + 100 = 100 pp` — wrong by 99 pp, and wrong in
    /// the shape that matters, turning a blocked account into one that spent a
    /// whole week's quota in a day. A reset at the edge of the interval is
    /// exactly what a median destroys, and ±1 pp of sawtooth is by two orders of
    /// magnitude the cheaper error.
    ///
    /// One shape gets past everything below: a hole that hides a reset *and*
    /// lets the new window climb back to within a point of the pre-reset reading
    /// or past it leaves no signature at all — no fall to count, nothing far
    /// enough negative to refuse. Above the reading it is a small positive burn
    /// (`[95, nil, nil, nil, 97]` reads 2 pp where the truth is 102); a point
    /// below it, the reading falls inside the sawtooth band the refusal leaves
    /// alone and `max(0, …)` serves it as a confident zero (`[95, nil, nil, nil,
    /// 94]` reads 0 pp where a counted reset answers 99). Same hole, same
    /// silence, and the clamp is named again where it happens.
    ///
    /// A named `resetsAt` does not save either of them, and that is on
    /// purpose: the schedule is read only over readings that already fell, since
    /// a schedule consulted on its own invents resets that never happened (the
    /// note beside the guard). The readings here carry no signature at all, so
    /// this one stands. It takes roughly four days of silence for the new window
    /// to climb that far, and the longest gap between two readings in the live
    /// history is 18.18 minutes (2026-08-17, over three accounts whose median
    /// gap is 64 s).
    static func measure(_ points: [HistoryPoint], resetsAt: Date?) -> Measurement? {
        // Only the seven-day window, and only the samples that carry a reading:
        // `util_7d: null` says the sample measured nothing, which is not a
        // reading of zero (§2.7). Order is the gateway's, which is ascending —
        // the same assumption `AccountSeries.make` and `FleetSeries.make` make.
        let readings: [(at: Date, value: Double)] = points.compactMap { point in
            point.sevenDay.map { (at: point.timestamp, value: $0) }
        }
        guard let first = readings.first, let last = readings.last else { return nil }
        let hours = last.at.timeIntervalSince(first.at) / 3600
        guard hours >= minimumMeasuredHours else { return nil }

        var resets = 0
        var hitCeiling = first.value >= ceilingPercent
        var everBelowCeiling = first.value < ceilingPercent
        var previous = first.value
        for reading in readings.dropFirst() {
            // Consecutive *readings*: a hole is stepped over rather than treated
            // as a boundary, because a window that turned over while the gateway
            // was not looking turned over all the same.
            if previous - reading.value > resetDropThreshold { resets += 1 }
            if reading.value >= ceilingPercent { hitCeiling = true } else { everBelowCeiling = true }
            previous = reading.value
        }

        // An account that never left its ceiling was not measured at all: it
        // served nothing it was asked for, so its series is flat at 100 and its
        // burn reads as zero — a demand of nought and a whole window of capacity
        // handed to the fleet by the one account that certainly had none to
        // spare. Three accounts, one exhausted throughout and two burning 50 pp
        // each over 48 h, answer 116.7% that way against the 175% the two
        // measurable ones read: the most alarming fact about a fleet moving the
        // number 58 points towards calm. So it goes out the way a too-short
        // history does, contributing neither demand nor capacity — its demand
        // was not zero, it was blocked and invisible, and unknown is not zero
        // (§2.7). A ceiling over *part* of the interval is a different thing and
        // stays: that account still shows a rate, and it raises `isLowerBound`.
        guard everBelowCeiling else { return nil }

        // At most one reset per interval, unconditionally. A seven-day window
        // cannot turn over twice inside seven days, so a second fall over the
        // threshold is a lagging sample beside a real reset rather than a second
        // window, and charging it costs +100 pp of burn that never happened.
        // Nothing live has shown such a sample: both resets the history holds
        // are clean, `100, 100, 100, 100, 0, 0, 0, 0` on acc2 and `99, 99, 99,
        // 99, 0, 0, 0, 0` on main, exactly one fall over the threshold in each.
        //
        // The clamp used to be conditional on `hours <= hoursPerWeek`, guarding
        // a span long enough to hold two real resets. No such span can reach
        // here, and that is a property of the source rather than of this
        // function: measured 2026-08-17, `since` of 7 and 30 days returns the
        // same points and the spans stop at 51.75 h on acc2, 52.43 h on acc3 and
        // 65.85 h on main. Asking for *less* does shorten them — `since` of two
        // days answers 1951 points over 47.96 h on acc2 against 2000 over
        // 51.75 h — so `since` is honoured on the left edge; what it cannot do is
        // reach further back than the gateway kept. Two independent ceilings hold
        // that — `max_points` of 2000 against 24 to 39 readings an hour, which is
        // what makes acc2 and acc3 come back `truncated`, and the gateway simply
        // not retaining more, which is what main shows at 1581 points, not
        // truncated and still stopping at 65.85 h. A whole week is two and a half
        // times deeper than the deepest account reaches.
        resets = min(resets, 1)

        let rawChange = last.value - first.value
        // A window's reading only ever goes up until it resets, so an interval
        // that ends lower than it began has two causes: the ±1 pp sawtooth (§4)
        // on an idle account, and a reset nobody saw. Past −1 the sawtooth
        // cannot reach, and a fall with no counted reset in it is a signature
        // the readings themselves left: something restored this window inside
        // the interval. The schedule then says whether one belongs here —
        // `resetsAt` ends the current window and the window is exactly seven
        // days, so `resetsAt` minus a week is when it began.
        //
        // Both halves are needed, and asking the schedule alone is what this
        // replaced. That guard counted a reset whenever the boundary landed
        // within 15 minutes of the interval, and it fired hardest where it was
        // most wrong: when the caller's `since` slides past a reset instant the
        // first reading of the series is already the *post*-reset value, no
        // reset happened inside the interval at all, and the boundary still sits
        // minutes before `first.at`. Replayed on the live acc2 series
        // (2026-08-17, boundary 2026-08-15 21:00:00Z), a left edge from the
        // boundary to 15 minutes past it answered 152 pp instead of 52 and took
        // the three-account fleet from 134% to 255% — deterministically, for the
        // quarter of an hour a week each account's boundary spends inside that
        // tolerance.
        //
        // Nothing is left for a tolerance to do, which is why there is no longer
        // a constant for one. A boundary inside the interval whose fall the
        // gateway actually saw is already counted by the loop above, and the
        // observation lag (42 s on main, 285 s on acc2 — see `hoursPerWeek`)
        // only ever moves that fall *later*, never out of the interval.
        if resets == 0, rawChange < -1 {
            if let resetsAt, case let windowStart = resetsAt.addingTimeInterval(-hoursPerWeek * 3600),
               windowStart > first.at, windowStart < last.at {
                resets = 1
            } else {
                // The readings and the schedule contradict each other: the
                // series fell past the sawtooth and no window began inside it to
                // explain the fall. Answering anyway means a confident 0% over
                // an account that may have spent most of a window — clamped by
                // `max(0, …)` below — and a missing figure beats a wrong one
                // (§2.7). This refuses whether or not `resetsAt` is known; when
                // it is known and places the boundary elsewhere, the schedule is
                // evidence against the reading, not the absence of evidence.
                return nil
            }
        }

        // What is left for `max(0, …)` is the −1…0 case: left signed it would
        // subtract from the fleet's demand, and one account resting would make
        // the others look cheaper, which is not a thing that happens. Usually
        // that band really is the sawtooth — but not certainly, and claiming so
        // would hide the one shape that reaches it: a reset buried in a hole
        // whose new window climbed back to within a point *below* the pre-reset
        // reading (`[95, nil, nil, nil, 94]`) leaves no fall to count and no
        // signature to refuse, and is served here as 0 pp against a truth near
        // 99. It is the same blind spot the header documents for a window that
        // climbed back *above* the reading; the difference is only which side of
        // the reading the new window stopped on, and this side is the one the
        // clamp makes silent.
        let burn = rawChange + quotaPerAccount * Double(resets)
        return Measurement(burnPP: max(0, burn), hours: hours, hitCeiling: hitCeiling)
    }

    // MARK: - The projection

    /// One local clock hour of one account's series.
    ///
    /// **It carries the change and the resets apart, and that separation is the
    /// whole correctness of the decomposition.** A bucket that carried a
    /// finished burn would have to decide, inside itself, whether a window
    /// turned over — and the first prototype of this did exactly that, taking
    /// each hour's own first and last reading and adding 100 per reset it saw
    /// between them. The arithmetic reconciled on two accounts out of three and
    /// was wrong by a whole window on the third: 128 pp against the 27 the span
    /// method answers on main, 231 against 132 over the fleet, measured
    /// 2026-08-18 and reproduced here before anything was built on top of it.
    /// The mechanism is worth naming because it is not obvious. A fall from 99
    /// to 0 that lands between one hour's last reading and the next hour's first
    /// is invisible to both hours' endpoints — neither pair straddles it — so the
    /// −99 is never subtracted, while the reset is still counted across the
    /// boundary and its +100 still charged. The hundred is not double-counted;
    /// it is charged with nothing to cancel it.
    ///
    /// So a step is the unit, not an hour: `deltaPP` is a signed change that
    /// telescopes, `resets` is a count, and `burn(over:)` puts them together the
    /// same way `measure` does over a span. Sum any contiguous stretch of these
    /// and the answer is the endpoint burn of that stretch — **exactly when the
    /// stretch's own edges fall on readings**, and that is the rare case rather
    /// than the ordinary one. Measured over the 48 h the app fetches
    /// (2026-08-18): exactly **1** hour boundary out of 48, 45 and 48 landed on a
    /// reading over `main`, `acc2` and `acc3`. Polling every minute or so does not
    /// make boundaries land on samples — the interval is a median of 64 s with a
    /// p90 of 303 s and no alignment to the clock at all — so an edge inside a
    /// step is what normally happens.
    ///
    /// **Inside a step the two methods part, and they part two different ways.**
    /// A *reset* step is charged whole to the hour its fall began in, so the
    /// stretch holding that hour carries the entire −99 and 100 while the
    /// endpoint method, stopping at the last reading before the edge, has not
    /// seen the fall at all: the divergence is that step's whole burn. An
    /// *ordinary* step is spread pro rata, so the stretch carries only the share
    /// of the change that fell inside it and the divergence is that share.
    /// Frequencies are the other way round from what the reset case suggests: of
    /// the boundaries above, 46 / 44 / 47 fell inside an ordinary step and 1 —
    /// `main`'s only reset — inside a reset step. Sizes are the same order: the
    /// reset straddle is exactly 1 pp (the stretch ending at 18:00 local, which
    /// is `TimeZone.current` and what production splits by), and the ordinary
    /// straddles are 0 pp at almost every boundary because the reading did not
    /// move across the step — non-zero at 3 / 2 / 4 of them, peaking at 0.94,
    /// 0.97 and 0.47 pp.
    ///
    /// `testHourBucketsReconcileWithTheSpanMethod` asks all of it, over three
    /// fixtures: a reset inside a bucket, a reset whose fall ends exactly on a
    /// bucket boundary, and a reset step that straddles one — the last being the
    /// only one of the three that can tell whole attribution from spreading, and
    /// the one that holds the qualification above. All three are sampled on the
    /// hour, so only the reset case ever straddles there; the ordinary straddle
    /// is a live-data statement and not a fixture.
    struct HourBucket: Sendable, Equatable {
        /// Start of the local clock hour, so buckets order and the recent window
        /// can be scanned back through them.
        let start: Date
        /// Which hour of the day it is, 0…23. Kept rather than recomputed
        /// because the profile asks it of every bucket several times.
        let hourOfDay: Int
        /// The signed change of the reading over the part of the hour the
        /// readings covered, with **no** reset charge in it. Negative is
        /// ordinary: the sawtooth is one-sided downward.
        let deltaPP: Double
        /// Window turnovers charged to this hour: a fall is charged to the hour
        /// it started in, together with the whole of its change.
        let resets: Int
        /// How much of the hour the readings actually covered. Under an hour at
        /// the ends of a series, and under an hour in a gap; the profile divides
        /// by it rather than by 1.
        ///
        /// **And over an hour when a reset step crossed the hour's end**, because
        /// such a step is not spread: its whole span goes to the hour its fall
        /// began in, boundary and all. On the live `main` series that bucket
        /// carries 1.0117 h (2026-08-18; it is the only bucket over an hour on any
        /// of the three accounts). It is the **17:00** bucket in local time, which
        /// is what production splits by — `load` defaults `timeZone` to
        /// `.current`; "14:00" stood here for a round because the measuring script
        /// labelled its hours in UTC, and this machine runs at UTC+3. The figure
        /// itself re-measures unchanged, but only over a window that covers the
        /// whole of that hour: today's 48 h fetch begins at 17:54 on the day of
        /// the reset, so the same bucket reads 0.10 h from it. The
        /// profile divides by what it is given, so the hour reads a rate over
        /// slightly more than an hour — which is the honest reading of a fall
        /// nobody watched the middle of.
        let hours: Double
    }

    /// Percentage points burned over a set of buckets.
    ///
    /// The same shape `measure` uses over a span — the signed change plus a
    /// window per reset, clamped to one — and it is the same clamp for the same
    /// reason: a seven-day window cannot turn over twice inside the depth the
    /// gateway keeps, so a second fall is a lagging sample beside a real reset
    /// and charging it costs 100 pp that never happened.
    ///
    /// The clamp is a property of the set it is asked over, and that is a real
    /// limit rather than a rounding: two falls landing one in a work hour and
    /// one in a sleeping hour are charged once in each class, 200 pp where the
    /// span says 100. It needs two falls in one series to happen at all, and the
    /// live history has held one fall per account at most — 1 reset over 5844
    /// steps across three accounts, measured 2026-08-18.
    static func burn(over buckets: [HourBucket]) -> Double {
        var change = 0.0
        var resets = 0
        for bucket in buckets {
            change += bucket.deltaPP
            resets += bucket.resets
        }
        return change + quotaPerAccount * Double(min(resets, 1))
    }

    /// Percentage points per hour over a set of buckets, never negative.
    ///
    /// The clamp is `measure`'s, moved to where the projection needs it: an
    /// account whose reading wobbled down by a point has not un-burned anything,
    /// and left signed it would make the rest of the fleet look cheaper.
    private static func rate(over buckets: [HourBucket]) -> Double {
        let hours = buckets.reduce(0.0) { $0 + $1.hours }
        guard hours > 0 else { return 0 }
        return max(0, burn(over: buckets)) / hours
    }

    /// One account's series cut into local clock hours, or `nil` when it cannot
    /// be cut honestly.
    ///
    /// **A step's change is spread across the hours the step spans**, in
    /// proportion to time. The readings are levels, not events: what happened
    /// between two of them is a stretch of spending we cannot resolve, and
    /// uniform is the only reading of it available. The alternative — charging
    /// the whole step to one hour — turns an 18-minute gap into a spike and a
    /// two-reading fixture into a series that touched one hour of the day, which
    /// would then fail the day-coverage guard for a series that was watched
    /// continuously.
    ///
    /// **A reset step is not spread.** Its change and its reset go together into
    /// the hour the fall started in, because splitting them is exactly the
    /// failure `HourBucket` documents: half a −99 in one hour and the whole +100
    /// in the next. They move as a pair or not at all.
    ///
    /// **Two readings can share a timestamp, and such a step keeps its change
    /// and contributes no time.** Not a hypothetical: in the 48 h the app
    /// fetches there are 31, 13 and 12 of them over acc2, acc3 and main
    /// (2026-08-18, over 2000 / 1487 / 1618 readings), and they are almost all a
    /// `poll` sample and a `headers` sample landing on the same second — the two
    /// measuring sources of §4, seen from the other side. Dropping them as
    /// zero-length is the obvious thing and it is wrong: they carry −9, +3 and
    /// −3 pp on those three series, and the −9 is a sixth of acc2's whole 58 pp
    /// burn. A decomposition that drops them stops reconciling with the span
    /// method, which is how this was found. The readings are never *backwards*,
    /// on the other hand — 0 pairs out of all three series, in the 48 h window
    /// and over the full depth alike — so the gateway's order is ascending in
    /// the weak sense §2.7 assumes, and no more than that.
    ///
    /// **A fall past the sawtooth on such a step would refuse the account
    /// outright**, and the two rules meet in a place worth naming. The refusal
    /// below asks the schedule for a window that began *strictly inside* the
    /// step — `windowStart > previous.at, windowStart < reading.at` — and a step
    /// across no time at all has no inside for a boundary to fall in: the
    /// condition cannot be satisfied by any schedule, so the guard returns `nil`
    /// and the account loses its demand *and* its 100 pp of capacity.
    ///
    /// **Which way that moves the reading depends on who left, and "up" — what
    /// stood here — is only half of it.** The load is `sum of demand / (N x 100)`,
    /// so dropping an account pulls the figure towards the mean of the ones that
    /// remain: up when the dropped account was below that mean, down when it was
    /// above. In one line, `(S - d) / (N - 1) > S / N` is exactly `d < S / N`.
    /// Demands of 40 / 40 / 200 pp read 93.3%, and without the 200 they read 40%
    /// — fifty-three points *down*.
    ///
    /// The dangerous direction is that one, because **a refusal can hide an
    /// overload**: what gets refused is not the quiet account but the one whose
    /// readings fell unexplainably, and unexplained falls live where the spending
    /// is. A fleet pushed over capacity by one account reads calm on the two that
    /// are left, and nothing on screen says the figure is now about somebody
    /// else. This is documentation and not a change, because the
    /// shape does not occur: re-counted the same day over the same window there
    /// are 26 / 13 / 13 such pairs (the count moves with the window, which is why
    /// it differs from the figures above), their changes are only −1, 0 and +1 pp
    /// — 10/14/2 on acc2, 1/8/4 on acc3, 6/5/2 on main — and not one of them
    /// falls past the sawtooth at all. A reset landing exactly between two
    /// same-second samples would be needed, and the two sources are both reading
    /// the same window.
    ///
    /// The refusal is `measure`'s, asked of every step rather than of the span:
    /// a fall past the sawtooth with no reset to explain it is something that
    /// restored the window, and the schedule is consulted exactly as it is
    /// there — over readings that already fell, never on its own. Asking it per
    /// step is stricter than asking it per span, and deliberately: the span
    /// method only ever sees the net change, so a 5 pp dip in the middle of a
    /// rising series rides through it unnoticed while this refuses the account.
    /// The cost of the strictness is measured and is currently zero — over the
    /// live history the deepest fall that is not a reset is exactly −1.0 pp on
    /// all three accounts (2026-08-18, 5844 steps), so no step reaches the
    /// refusal at all.
    static func hourBuckets(_ readings: [(at: Date, value: Double)],
                            resetsAt: Date?,
                            timeZone: TimeZone) -> [HourBucket]? {
        var slices: [Date: (change: Double, resets: Int, hours: Double)] = [:]
        func add(_ start: Date, change: Double, resets: Int, hours: Double) {
            var slice = slices[start] ?? (0, 0, 0)
            slice.change += change
            slice.resets += resets
            slice.hours += hours
            slices[start] = slice
        }
        // The current window began a week before it ends, the window being
        // exactly seven days (`hoursPerWeek`).
        let windowStart = resetsAt?.addingTimeInterval(-hoursPerWeek * 3600)

        for (previous, reading) in zip(readings, readings.dropFirst()) {
            let change = reading.value - previous.value
            var resets = previous.value - reading.value > resetDropThreshold ? 1 : 0
            if resets == 0, change < -sawtoothPP {
                // The readings fell further than the two measuring sources can
                // disagree by, and nothing in them says a window turned over.
                // The schedule answers only whether one began inside this step.
                guard let windowStart, windowStart > previous.at, windowStart < reading.at else { return nil }
                resets = 1
            }
            let span = reading.at.timeIntervalSince(previous.at)
            // Two kinds of step go in whole rather than pro rata, and the branch
            // serves both. A reset, because splitting it is the failure
            // `HourBucket` documents — and into the hour the fall *started* in,
            // which is where the spending the `+ 100` stands for happened, and
            // which puts the step on the same side of an hour boundary as the
            // endpoint method would. And a step across no time at all, which is
            // two sources reporting the same instant: it has no time to be
            // spread over, and it still carries a real change.
            guard resets == 0, span > 0 else {
                add(hourStart(of: previous.at, in: timeZone),
                    change: change, resets: resets, hours: max(0, span) / 3600)
                continue
            }
            var cursor = previous.at
            while cursor < reading.at {
                let start = hourStart(of: cursor, in: timeZone)
                let next = min(start.addingTimeInterval(3600), reading.at)
                // A time zone whose offset moved under us could otherwise leave
                // the cursor where it was; the remainder goes into one bucket
                // and the loop ends rather than spinning.
                guard next > cursor else {
                    add(start, change: change * (reading.at.timeIntervalSince(cursor) / span),
                        resets: 0, hours: reading.at.timeIntervalSince(cursor) / 3600)
                    break
                }
                let covered = next.timeIntervalSince(cursor)
                add(start, change: change * (covered / span), resets: 0, hours: covered / 3600)
                cursor = next
            }
        }

        return slices
            .map { HourBucket(start: $0.key,
                              hourOfDay: hourOfDay(of: $0.key, in: timeZone),
                              deltaPP: $0.value.change,
                              resets: $0.value.resets,
                              hours: $0.value.hours) }
            .sorted { $0.start < $1.start }
    }

    /// The start of the local clock hour `date` falls in.
    ///
    /// Arithmetic rather than `Calendar`, because this is asked once or twice
    /// per step and the live pass carries some six thousand of them. The offset
    /// is queried at the instant rather than taken once, so a zone that changes
    /// offset mid-series maps each instant by the rule in force then; a zone
    /// offset by half an hour has its hours boundaried on the half hour, which
    /// is where its wall clock puts them.
    private static func hourStart(of date: Date, in timeZone: TimeZone) -> Date {
        let offset = Double(timeZone.secondsFromGMT(for: date))
        let local = date.timeIntervalSince1970 + offset
        return Date(timeIntervalSince1970: (local / 3600).rounded(.down) * 3600 - offset)
    }

    /// Which hour of the local day `date` falls in, 0…23.
    private static func hourOfDay(of date: Date, in timeZone: TimeZone) -> Int {
        let local = date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))
        let hours = Int((local / 3600).rounded(.down))
        return ((hours % 24) + 24) % 24
    }

    /// One account's series, cut into hours and flagged, or `nil` when it cannot
    /// carry a projection.
    ///
    /// Internal, like `Measurement` and for the same reason: the reconciliation
    /// test asks this for the buckets and `measure` for the span, and the two
    /// have to answer the same burn.
    struct HourlyMeasurement {
        var buckets: [HourBucket]
        /// The whole span between the first and last reading, as `Measurement`
        /// means it.
        var hours: Double
        /// At the ceiling at least once, and below it at least once.
        var hitCeiling: Bool
    }

    static func measureHourly(_ points: [HistoryPoint],
                              resetsAt: Date?,
                              timeZone: TimeZone) -> HourlyMeasurement? {
        // Same readings as `measure` reads, and for the same reasons: only the
        // seven-day window, and `util_7d: null` is a sample that measured
        // nothing rather than a reading of zero (§2.7).
        let readings: [(at: Date, value: Double)] = points.compactMap { point in
            point.sevenDay.map { (at: point.timestamp, value: $0) }
        }
        guard let first = readings.first, let last = readings.last else { return nil }
        let hours = last.at.timeIntervalSince(first.at) / 3600
        guard hours >= minimumProjectionHours else { return nil }

        var hitCeiling = first.value >= ceilingPercent
        var everBelowCeiling = first.value < ceilingPercent
        for reading in readings.dropFirst() {
            if reading.value >= ceilingPercent { hitCeiling = true } else { everBelowCeiling = true }
        }
        // An account that never left its ceiling was watched, not measured — the
        // reason is written out in `measure`, and it is the same reason here.
        guard everBelowCeiling else { return nil }

        guard let buckets = hourBuckets(readings, resetsAt: resetsAt, timeZone: timeZone) else { return nil }
        return HourlyMeasurement(buckets: buckets, hours: hours, hitCeiling: hitCeiling)
    }

    /// The most recent `wanted` work hours of one account's series, scanning
    /// back through work hours only and stepping over the sleeping ones.
    ///
    /// **Work hours, not clock hours, and that is the point of the scan.** Ask
    /// for the last six clock hours at ten in the morning and there are no work
    /// hours in them at all, so the figure would be undefined every morning and
    /// zero every morning it was not. Scanning back for six *work* hours reaches
    /// however far it has to — on this fleet's day that is between six and
    /// twenty clock hours.
    ///
    /// `nil` when what came back is under `minimumRecentWorkHours`: fewer usable
    /// work hours than asked for is answerable as long as there are enough to
    /// extrapolate from, and under the floor there is no figure rather than a
    /// noisy one.
    private static func recentWorkWindow(_ buckets: [HourBucket],
                                         workHours: Set<Int>,
                                         wanted: Double) -> (buckets: [HourBucket], hours: Double)? {
        var taken: [HourBucket] = []
        var hours = 0.0
        for bucket in buckets.reversed() where workHours.contains(bucket.hourOfDay) {
            taken.append(bucket)
            hours += bucket.hours
            if hours >= wanted { break }
        }
        guard hours >= minimumRecentWorkHours else { return nil }
        return (taken, hours)
    }

    /// Demand as the recent work rate over a week's work hours plus the sleeping
    /// rate over its sleeping hours.
    ///
    /// ```
    /// demand = recentWorkRate x workHoursPerDay x 7
    ///        + sleepRate      x sleepHoursPerDay x 7
    /// ```
    ///
    /// **The day is split from the data, not from a schedule.** For each hour of
    /// the local day the fleet's rate in it is measured over the whole history,
    /// and an hour counts as a work hour when it burns more than
    /// `workHourFraction` of the fleet's overall hourly rate. On the live fleet
    /// that is 14 work hours and a sleeping block from 05:00 to 15:00
    /// (2026-08-18, three accounts, `#` a work hour):
    ///
    /// ```
    /// 000000000011111111112222
    /// 012345678901234567890123
    /// #####..........#########
    /// ```
    ///
    /// The three accounts agree about the shape of that day, which is what makes
    /// one fleet-wide split the right thing rather than three per-account ones:
    /// the trough falls on the same hours for all of them and every one of them
    /// peaks in the evening. Re-measured over the 48 h the app fetches
    /// (2026-08-18) acc2 reads exactly 0.0 pp/h from 07:00 to 14:00 while main
    /// and acc3 stay at or under 0.5 there — 0.50 at 09:00 on main, 0.21 at 08:00
    /// and 0.50 at 10:00 on acc3 — so "each of them reads 0.0" was too strong;
    /// the fleet itself is at zero only in 07:00, 11:00, 12:00 and 13:00. The
    /// sleeping rate the split then answers is 0.350 pp/h over the fleet (0.200 /
    /// 0.050 / 0.100 on main / acc2 / acc3), which is 24.5 pp of demand a week
    /// and 8.2 load points.
    ///
    /// **The classification is thin, and it is the weakest part of the answer.**
    /// The gateway keeps two to three days, so each hour of the day is observed
    /// two or three times per account, and the rates come out quantised to whole
    /// percentage points; recomputed over sub-windows of that history the split
    /// moves by 0.43 of an hour on average at `workHourFraction` and by more at
    /// every alternative measured (the numbers are on the constant). One hour
    /// moved between the classes is worth about 10 load points here. Depth is the
    /// only cure and it is not on this side of the wire — §2.7 has it ordered as
    /// issue №6 in the gateway's forge.
    ///
    /// **A flat fleet is not a refusal.** If every hour clears the threshold the
    /// split is 24 work hours and no sleeping ones, and the arithmetic collapses
    /// to `rate x 168` — the window average with a fresher rate, which is the
    /// right answer for a fleet that genuinely burns around the clock. The
    /// instability that worries a reader here is self-cancelling: the split can
    /// only be unstable when the hourly rates cluster around the mean, and when
    /// they do, moving an hour from one class to the other moves demand by the
    /// difference between two rates that are nearly equal. What a flat profile
    /// cannot do is make the answer wrong, only make the *split* arbitrary. A
    /// fleet that burned nothing at all lands on the other end — no hour clears a
    /// threshold of zero, so there are no work hours, all 24 hours are sleeping
    /// hours at a rate of zero, and demand is zero. That is a fleet at rest
    /// reading 0%, which is what it is.
    ///
    /// It costs 0.706 ms against the window average's 0.126 ms over the live
    /// fleet — 5105 points, release build, best of twenty, measured 2026-08-18.
    /// Both are once every ten minutes and off the main thread, so the cost is
    /// named here to save the next reader the measurement rather than because
    /// anything has to be done about it.
    private static func projected(histories: [String: HistorySeries],
                                  accounts: [AccountUsage],
                                  recentWorkHours: Double,
                                  timeZone: TimeZone) -> FleetLoad? {
        var measured: [HourlyMeasurement] = []
        for account in accounts {
            guard let series = histories[account.label],
                  let hourly = measureHourly(series.points,
                                             resetsAt: account.sevenDay?.resetsAt,
                                             timeZone: timeZone) else { continue }
            measured.append(hourly)
        }
        guard !measured.isEmpty else { return nil }

        // The fleet's rate is the sum of the accounts' own rates, here and in
        // every hour of the day — the same "per account, then summed" the window
        // average makes, and for the same reason: the accounts are watched over
        // different depths, so one total over one span would credit the shallow
        // account with hours nobody measured it over.
        let overall = measured.reduce(0.0) { $0 + rate(over: $1.buckets) }
        let threshold = overall * workHourFraction
        var workHours: Set<Int> = []
        for hour in 0..<hoursPerDay {
            let fleetRate = measured.reduce(0.0) { total, account in
                total + rate(over: account.buckets.filter { $0.hourOfDay == hour })
            }
            if fleetRate > threshold { workHours.insert(hour) }
        }

        var recentWorkRate = 0.0
        var sleepRate = 0.0
        var shortestRecent = Double.greatestFiniteMagnitude
        var shortestHours = Double.greatestFiniteMagnitude
        var contributors = 0
        var blocked = false
        for account in measured {
            var recent = 0.0
            var recentHours = 0.0
            if !workHours.isEmpty {
                // An account that cannot fill the window leaves the way one with
                // too little history does: without its demand and without its
                // 100 pp of capacity. It keeps its say in the split above, and
                // that is deliberate — which hours of the day are working ones is
                // a true thing to have learned from a series too short to take a
                // recent rate from.
                guard let window = recentWorkWindow(account.buckets,
                                                    workHours: workHours,
                                                    wanted: recentWorkHours) else { continue }
                recent = rate(over: window.buckets)
                recentHours = window.hours
            }
            recentWorkRate += recent
            sleepRate += rate(over: account.buckets.filter { !workHours.contains($0.hourOfDay) })
            // Both minima are taken *before* the counter, which is what makes
            // them answerable below: a positive `contributors` is exactly the
            // statement that this line ran at least once, so neither can still
            // hold its sentinel when the guard lets the figure out.
            shortestRecent = min(shortestRecent, recentHours)
            shortestHours = min(shortestHours, account.hours)
            blocked = blocked || account.hitCeiling
            contributors += 1
        }
        guard contributors > 0 else { return nil }

        // Capacity counts the contributors and nobody else, exactly as on the
        // other path.
        let capacity = Double(contributors) * quotaPerAccount
        let workPerDay = workHours.count
        let demand = recentWorkRate * Double(workPerDay) * daysPerWeek
            + sleepRate * Double(hoursPerDay - workPerDay) * daysPerWeek
        return FleetLoad(percent: demand / capacity * 100,
                         isLowerBound: blocked,
                         accounts: contributors,
                         measuredHours: shortestHours,
                         projection: FleetLoad.Projection(
                            workHoursPerDay: workPerDay,
                            recentWorkRate: recentWorkRate,
                            sleepRate: sleepRate,
                            recentWorkHours: shortestRecent))
    }
}
