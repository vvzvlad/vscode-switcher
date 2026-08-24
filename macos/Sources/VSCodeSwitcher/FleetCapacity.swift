import Foundation

/// What a week of quota may be spent at, and everything the figure is built
/// from.
///
/// Utilisation per account does not answer "will the quota last". The gateway
/// routes across several accounts, and each account's seven-day window resets on
/// its own schedule, handing back a whole 100 percentage points when it turns
/// over. So "89% spent" says only where one account stands inside a window that
/// may end in an hour or in six days.
///
/// **Demand is no longer estimated here, and that is the whole shape of this
/// file.** It used to be, two ways at once — an average burn over the window
/// stretched to a week, and a projection off the recent work hours — and the
/// answer was compared against a supply of `100 pp x accounts`. Both are gone,
/// because the gateway now *measures* the demand: `GET /gw/usage` publishes a
/// live token rate over its own five-minute window (`TokenRate`), which is the
/// same quantity without an estimator in front of it. What is left here is the
/// other side of the comparison — what that rate may be, in the same unit:
///
///     price of a point  = tokens spent over the window / points burned over it
///     allowed work rate = (capacity - a week of sleeping) / a week of work hours
///     allowance         = allowed work rate x price of a point   [tokens/hour]
///
/// The machinery the two estimators were built on is still here, because the
/// allowance is built on the same machinery: the burn rule and its guards, the
/// hour-by-hour decomposition, and the split of the day into working and
/// sleeping hours. What went with the estimators is the arithmetic that turned
/// them into a week's demand, and the setting that chose between the two.
///
/// Nothing here fetches anything: it reads the series `UsageClient` already
/// brought back.

/// The arithmetic of the allowance. Stateless, and deliberately not isolated to
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

    /// The shortest interval `measure` will answer over.
    ///
    /// It was chosen for an estimator that no longer exists: the measured rate
    /// was multiplied by `168 / span` to reach a week, so a short span was a
    /// large multiplier over a small measurement — at two hours of history a
    /// single percentage point, the exact size of the sawtooth, became 84 pp/week
    /// and four fifths of an account's whole quota. Six hours held the multiplier
    /// at 28.
    ///
    /// **Nothing on the app's path reaches it now.** The allowance goes through
    /// `measureHourly`, whose own floor is a whole day (`minimumProjectionHours`),
    /// and a day is four times this. It stays because `measure` stays, and
    /// `measure` stays because the hour-by-hour decomposition is checked against
    /// it — see the note there.
    static let minimumMeasuredHours: Double = 6

    /// The shortest history an account's day may be split from, which is the
    /// floor everything the app computes actually stands on.
    ///
    /// A day, because the split sorts the hours of the day into working and
    /// sleeping ones and a series shorter than a day has not seen every hour of
    /// the day even once. An hour nobody watched is not a sleeping hour, it is an
    /// unknown one, and unknown is not zero (§2.7). An account below this
    /// contributes neither its spending nor its 100 pp of capacity.
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
    /// it is something restoring the window, and that is the refusal both ways
    /// of reading a series make — `measure` over the whole span, `hourBuckets`
    /// over each step.
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

    /// What one account's series says about it: the burn over a span, taken
    /// from the two ends.
    ///
    /// **Nothing the app draws goes through this any more, and it is not dead
    /// code.** It is the coarse method the fine one is held to. `hourBuckets`
    /// cuts the same series into clock hours and `burn(over:)` adds them back up,
    /// and the rule this project pays for in scars is that the two must agree —
    /// the first prototype of the decomposition was wrong by a whole restored
    /// window on the one account whose history crossed a reset, and nothing but
    /// this comparison could have said so (§2.7). Its reader is
    /// `testHourBucketsReconcileWithTheSpanMethod`, which asks this function for
    /// a stretch and the buckets for the same one. Delete it and the invariant
    /// has nothing to reconcile against.
    ///
    /// It carried a third field, `hitCeiling`, and that one *was* dead the moment
    /// the demand estimators went: the flag reached a surface through the
    /// window-average estimator alone, and the allowance raises its own from
    /// `HourlyMeasurement` (`SustainableRate.isLowerBound`).
    struct Measurement {
        /// Percentage points burned over `hours`, never negative.
        var burnPP: Double
        var hours: Double
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
        var everBelowCeiling = first.value < ceilingPercent
        var previous = first.value
        for reading in readings.dropFirst() {
            // Consecutive *readings*: a hole is stepped over rather than treated
            // as a boundary, because a window that turned over while the gateway
            // was not looking turned over all the same.
            if previous - reading.value > resetDropThreshold { resets += 1 }
            if reading.value < ceilingPercent { everBelowCeiling = true }
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
        return Measurement(burnPP: max(0, burn), hours: hours)
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
        /// is what production splits by — `sustainable` defaults `timeZone` to
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

    /// Which hours of the local day the fleet works in, 0…23.
    ///
    /// The fleet's rate is the sum of the accounts' own rates, here and in every
    /// hour of the day — the same "per account, then summed" the window average
    /// makes, and for the same reason: the accounts are watched over different
    /// depths, so one total over one span would credit the shallow account with
    /// hours nobody measured it over.
    ///
    /// **One reader, and there used to be two.** The demand estimator spread a
    /// week's spending over it; that estimator is gone, and `sustainable` — which
    /// uses it to work out what a working hour may cost — is all that is left. So
    /// the split is computed exactly once per pass now, where before it was
    /// computed twice over the same series in the same pass.
    private static func workHoursOfDay(_ measured: [HourlyMeasurement]) -> Set<Int> {
        let overall = measured.reduce(0.0) { $0 + rate(over: $1.buckets) }
        let threshold = overall * workHourFraction
        var workHours: Set<Int> = []
        for hour in 0..<hoursPerDay {
            let fleetRate = measured.reduce(0.0) { total, account in
                total + rate(over: account.buckets.filter { $0.hourOfDay == hour })
            }
            if fleetRate > threshold { workHours.insert(hour) }
        }
        return workHours
    }

    // MARK: - The allowance

    /// What the fleet may spend an hour of work and still have the week last,
    /// in tokens an hour — and everything the figure was built from.
    ///
    /// The unit is the point: the gateway now says how fast tokens are going
    /// (`TokenRate`), and a rate is only a warning against another rate. A per
    /// cent of a seven-day window cannot be compared with five minutes of
    /// spending without an arithmetic nobody can do in their head.
    struct SustainableRate: Sendable, Equatable {
        /// The allowance itself: input-equivalent tokens an hour.
        let tokensPerHour: Double
        /// What one percentage point of a window costs in input-equivalent
        /// tokens — the conversion the whole figure turns on. Live on this fleet
        /// it is 7.04 M (2026-08-24, 48 h window).
        let tokensPerPoint: Double
        /// Percentage points an hour a working hour may burn, which is the
        /// allowance before it is priced in tokens.
        let allowedWorkRate: Double
        /// How many hours of the day the fleet was found to be working in, and
        /// the rate the rest of them were measured at (`workHoursOfDay`).
        let workHoursPerDay: Int
        let sleepRate: Double
        /// How many accounts stood behind it — which is exactly how many were
        /// counted into capacity.
        let accounts: Int
        /// The shortest per-account history that went in: how much watching
        /// stands behind the answer. The answer is only as well measured as its
        /// worst-measured contributor, and the depths differ — 2.16 / 2.18 / 2.74
        /// days over acc2 / acc3 / main, measured 2026-08-17.
        ///
        /// The gateway's `max_points` cap is not what makes the shallowest
        /// shallow, and the obvious reading of those three numbers is the wrong
        /// one: *two* of the accounts come back `truncated` at 2000 points, and
        /// the one that does not — main, at 1581 — is the deepest of the three.
        /// What separates them is how hard the gateway watches each account: 38.6
        /// and 38.1 readings an hour on acc2 and acc3 against main's 24.0. The cap
        /// counts points, not hours.
        let measuredHours: Double
        /// An account sat at its ceiling while it was measured, so the points it
        /// was blocked from burning never entered its series at all.
        ///
        /// **It makes the allowance too generous, which is the direction that
        /// matters**, and it does so three ways at once — all three pushing the
        /// allowance up and the ratio drawn against it down.
        ///
        /// Suppressed points are missing from the denominator of
        /// `tokensPerPoint`, so a point reads dearer than it is, and the
        /// allowance is that price times a rate. They are missing from
        /// `sleepRate` too, so the week of nights costs less than it did and
        /// leaves more behind. **And the third is the largest: a blocked account
        /// brings its whole 100 pp into `capacity` whatever it managed to spend**
        /// — capacity counts contributors, not what they were allowed to burn —
        /// so an account blocked for most of the window adds a full week's quota
        /// to the supply while adding almost nothing to the demand it is netted
        /// against. Whatever is drawn against the allowance is therefore a floor.
        /// Live example: acc2 spent 34 samples at 100 during a 48 h window,
        /// 2026-08-17.
        ///
        /// **Where the `≥` actually reaches, and where it does not.** The mark
        /// belongs to `UsagePopoverView.ratioLabel`, which since the lead became
        /// a pair of rates has exactly one caller: the menu bar's accessibility
        /// description (`MenuBarIcon.describe`). `--dump` carries the same flag
        /// but writes its own ASCII `>=` inline, so it is a second reader of the
        /// flag and not of this string. A sighted reader of the popover gets
        /// neither — the
        /// quantity the popover prints is `of 19.9M/h sustainable`, which is the
        /// inflated one and carries no mark at all. That is deliberate and it is
        /// the trade §4 records: the caption is a measurement in tokens, and a
        /// `≥` in front of a budget reads as "at least this much is allowed",
        /// which is the opposite of what the flag means.
        ///
        /// What it carries is that measurement was suppressed, and nothing about
        /// how much: the requests an exhausted account turned away leave no trace
        /// to count, so the gap between this figure and the truth is unbounded —
        /// an account blocked for an hour and one blocked for two days raise the
        /// same flag. It is a warning that the number is a floor, not a margin on
        /// it. The sleeping rate moves the same way for the same reason, and the
        /// exchange rate is the larger of the two terms.
        ///
        /// An account that spent the *whole* window at the ceiling does not raise
        /// it, because it is not counted at all (`measureHourly` refuses it, for
        /// the reason given there); that fleet is smaller by one in `accounts`
        /// instead.
        let isLowerBound: Bool

        /// The rest of the day. Named rather than derived at each use, because
        /// the two halves have to add up to 24 in every reader.
        var sleepHoursPerDay: Int { 24 - workHoursPerDay }
    }

    /// The allowance, or `nil` when the fleet cannot say what it may spend.
    ///
    /// ```
    /// tokens per point = tokens spent over the window / points burned over it
    /// allowed work rate = (capacity - a week of sleeping) / a week of work hours
    /// allowance         = allowed work rate x tokens per point
    /// ```
    ///
    /// **It has to be the working rate and not the flat weekly average**, and
    /// that is the whole reason this function is not one division. What it is
    /// compared against is measured over five minutes — that is to say, while
    /// somebody is working. Spread the same capacity over all 168 hours of the
    /// week instead and every working hour of every healthy week reads as an
    /// overrun; this project already threw the gateway's own `pace` away for
    /// exactly that (§2.7). So the sleeping hours are paid at the rate they were
    /// measured at, and what is left of the week is spread over the hours
    /// somebody is actually at the keyboard.
    ///
    /// **The two measurements must span the same window.** The points come from
    /// the histories this pass fetched and the tokens from `/gw/sessions` asked
    /// with the same `since`, which the gateway honours: 22, 32, 38 and 46
    /// sessions came back for windows of 6, 12, 24 and 48 h (2026-08-24). What
    /// they do not span *exactly* is measured rather than waved at — the series
    /// begins where the gateway's retention lets it, which on that day was 0.2 to
    /// 1.1 minutes after the `since` asked for, or 0.04% of a 48 h window.
    ///
    /// **A long window is both safer and cheaper here.** The exchange rate barely
    /// moves with it — 6.934, 7.047 and 7.044 M tokens per point over windows of
    /// 12, 24 and 48 h (2026-08-24, three accounts), a spread of 1.6% — while the
    /// points it divides by are whole numbers, so a short window divides by very
    /// few of them. At 6 h there is no figure at all on that fleet, and not
    /// because of noise: `measure` refuses a span under `minimumMeasuredHours`,
    /// and a series asked for 6 h comes back 5.99 h long. The window is the one
    /// the histories were fetched over (`UsageStore.historyWindowSeconds`), which is
    /// 48 h unless the setting takes it higher.
    ///
    /// **Its contributors are the accounts whose day could be split**, which is
    /// the `measureHourly` set — a day of history, and not pinned at the ceiling
    /// throughout. Capacity counts them and nobody else, exactly as both
    /// estimators do: an account we could not measure must never widen a
    /// denominator its own spending is missing from (§2.7).
    ///
    /// The tokens, on the other hand, are the fleet's whole spend over the
    /// window, because `/gw/sessions` reports per session and a session is not
    /// an account. **The mismatch is real and it errs towards the warning**: a
    /// refused account's tokens stay in the numerator of the exchange rate while
    /// its points leave the denominator, so the rate reads high, the allowance
    /// reads high — and a high allowance makes the fleet look *safer*, which is
    /// the unsafe direction. It is bounded by how much of the fleet's spend the
    /// refused account served and it is not observable from here. On the live
    /// fleet no account has been refused (2026-08-24, three accounts, all three
    /// contributing).
    ///
    /// **Refusals, and what each one answers.** No account with a splittable day
    /// — the same "unknown is not zero" both estimators make. No points burned
    /// over the window, which is at once a fleet with nothing to price a token by
    /// and a fleet at rest with no working hours to spread a week over: there is
    /// no working rate to allow, and answering the flat weekly average instead
    /// would be the very comparison the second paragraph refuses. No tokens spent
    /// over the window — then there is no exchange rate either, and inventing one
    /// would price every future hour off two numbers that never happened. And a
    /// week whose sleeping hours already spend the whole capacity, which leaves
    /// nothing for a working hour to be allowed: the answer there is not "zero
    /// an hour", because the arithmetic that produced it has gone negative and a
    /// floor would hide it.
    ///
    /// Note which of these is *not* a refusal: a current rate of zero. An idle
    /// fleet genuinely spends nothing, that is a reading, and it is the caller's
    /// figure rather than this one's.
    ///
    /// **It is the whole cost of the pass now, and it used to be half of it.**
    /// While the demand estimators existed, this function ran `measureHourly` and
    /// the split a second time over the same series in the same pass, because the
    /// figure the estimator produced carried a field meaning "which estimator
    /// ran" and filling it on the other path would have made that field lie. With
    /// one reader left there is nothing to duplicate, and the duplication was
    /// nearly the whole bill: measured 2026-08-24 on this machine over the live
    /// fleet's own bodies (three accounts, 1616 / 1145 / 1020 readings, release
    /// build, best of twenty over four runs) this function costs **0.697 to
    /// 0.741 ms**, of which `measureHourly` over the three series is **0.676 to
    /// 0.696 ms**. That decomposition is what ran twice, so the pass on the
    /// projection path cost about twice this and now costs this.
    ///
    /// It runs once every ten minutes and off the main thread, so the figures are
    /// named to save the next reader the measurement rather than because anything
    /// has to be done about it. Note what they are *not* comparable with: the
    /// 0.639 ms this comment used to quote was taken by another method on another
    /// day, and a first cold run of the bench above answered 1.239 ms before
    /// settling — a number from a different harness is not a baseline.
    static func sustainable(histories: [String: HistorySeries],
                            accounts: [AccountUsage],
                            spentTokens: Double,
                            timeZone: TimeZone = .current) -> SustainableRate? {
        var measured: [HourlyMeasurement] = []
        var shortestHours = Double.greatestFiniteMagnitude
        var blocked = false
        for account in accounts {
            guard let series = histories[account.label],
                  let hourly = measureHourly(series.points,
                                             resetsAt: account.sevenDay?.resetsAt,
                                             timeZone: timeZone) else { continue }
            measured.append(hourly)
            shortestHours = min(shortestHours, hourly.hours)
            blocked = blocked || hourly.hitCeiling
        }

        // **Nothing asks whether anybody was measured**, and that is the same
        // omission the statement below documents rather than a second one. The
        // burn is a sum over the contributors, so a fleet where nobody could be
        // measured sums nothing and the price of a point refuses it three lines
        // on. A `!measured.isEmpty` stood here and decided nothing on any input;
        // it has been taken out, and what stands in its place is
        // `testThePriceOfAPointDividesByTheContributorsAndNothingElse`, which
        // pins the link the removal rests on — that the burn is that sum and
        // only that sum.
        //
        // The same burn `measure` takes over the span, asked of the buckets so
        // that one decomposition serves the whole file: over a whole series the
        // stretch's edges *are* the first and last readings, which is the case
        // the two methods agree on exactly (`HourBucket`). Clamped for
        // `rate(over:)`'s reason — an account whose reading wobbled down by a
        // point has not un-burned anything.
        let burned = measured.reduce(0.0) { $0 + max(0, burn(over: $1.buckets)) }
        // **One statement, and it stands in front of both divisions below.** A
        // fleet that burned nothing over the window has no points to price a
        // token by, *and* no work hours to spread a week over: the fleet's rate
        // is what the threshold is a fraction of, so an hour clears 0.45 of it
        // whenever that rate is above zero — and the rate is above zero exactly
        // when the burn is, both being the same clamped sum over the same
        // buckets. Asking the second half separately was tried and taken back
        // out: no series reaches it, and a guard nothing can fire is a branch
        // that cannot execute. What keeps `workHours.count` safe to divide by is
        // therefore this line plus the test that pins the invariant,
        // `testAnAnswerAlwaysHasWorkHoursToSpreadTheWeekOver`.
        //
        // A fleet at rest is the shape that reaches it, and refusing is the
        // right answer: what is asked here is what an hour of work may cost, and
        // a fleet that has not worked has not said. The lead figure it would have
        // been drawn against is a measured zero, which the surface states on its
        // own — a rate needs an allowance to be a ratio, and there is none.
        guard burned > 0, spentTokens > 0 else { return nil }
        let tokensPerPoint = spentTokens / burned

        let workHours = workHoursOfDay(measured)
        let sleepRate = measured.reduce(0.0) { total, account in
            total + rate(over: account.buckets.filter { !workHours.contains($0.hourOfDay) })
        }

        let capacity = Double(measured.count) * quotaPerAccount
        let sleepingWeek = sleepRate * Double(hoursPerDay - workHours.count) * daysPerWeek
        let workingWeek = Double(workHours.count) * daysPerWeek
        guard capacity - sleepingWeek > 0 else { return nil }
        let allowedWorkRate = (capacity - sleepingWeek) / workingWeek
        return SustainableRate(tokensPerHour: allowedWorkRate * tokensPerPoint,
                               tokensPerPoint: tokensPerPoint,
                               allowedWorkRate: allowedWorkRate,
                               workHoursPerDay: workHours.count,
                               sleepRate: sleepRate,
                               accounts: measured.count,
                               measuredHours: shortestHours,
                               isLowerBound: blocked)
    }
}
