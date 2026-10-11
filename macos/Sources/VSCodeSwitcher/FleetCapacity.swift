import Foundation

/// How fast the fleet is burning its weekly quota, against how fast that quota
/// refills.
///
/// Utilisation per account does not answer "will the quota last". The gateway
/// routes across several accounts, and each account's seven-day window resets on
/// its own schedule, handing back a whole 100 percentage points when it turns
/// over. So "89% spent" says only where one account stands inside a window that
/// may end in an hour or in six days.
///
/// **Both sides of the comparison are percentage points of a week.** `util_7d`
/// is already denominated in what the question is about — the supplier computes
/// it, and it already prices Opus above Sonnet. So:
///
///     burn rate,   per account = points burned over the window / hours of it
///     refill rate, per account = quotaPerAccount / hoursPerWeek
///     percent = (sum of the burn rates) / (contributors x refill rate) x 100
///
/// A per cent over a per cent: the model mix cancels out of the question, and
/// nothing is converted on the way to the answer.
///
/// This is a different quantity from the `tokens` block of `GET /gw/usage`,
/// which measures a five-minute token rate. That rate is still drawn, as a
/// second reading that is the numerator of nothing and colours nothing (§4).
///
/// Nothing here fetches anything: it reads the series `UsageClient` already
/// brought back.

/// The arithmetic of the fleet figure. Stateless, and deliberately not isolated
/// to any actor: it is pure arithmetic over values already in hand, and a
/// `@MainActor` annotation here would drag every `nonisolated async` caller onto
/// the main thread the moment it read one of the constants below (see the note
/// on `UsageStore.windowSeconds`).
enum FleetCapacity {

    /// A fall larger than this between two consecutive readings is a window
    /// reset, not the signal moving.
    ///
    /// Inside a window the reading never falls by more than 1 pp — the ±1
    /// sawtooth of the two measuring sources (§4). At a reset it falls 99 to
    /// 100. Anything strictly between 1 and 99 separates the two; 5 sits far
    /// from both ends. Below 1, every jitter tooth is charged as a restored
    /// window. Above 99, a real reset reads as an account that un-burned its
    /// quota, and its burn comes out negative.
    static let resetDropThreshold: Double = 5

    /// The trailing stretch every account is measured over: **how fast the fleet
    /// is burning now**, not on average over the whole fetched history.
    ///
    /// A moving average of width `W` shows a burst of duration `T` at strength
    /// `min(1, T/W)`: an hour of three agents burning at three times the refill
    /// rate moves a 48 h figure by 4 points and an 8 h figure by 25.
    ///
    /// The floor is quantisation. The reading is integer percentage points, so a
    /// window of `W` hours can only answer in multiples of `100 / (W x 0.5952 x n)`
    /// per cent for `n` contributors. Measured on one account over 24 h at
    /// 10-minute anchors (145 of them), with `minimumMeasuredHours` lifted:
    ///
    ///     W(h)  levels  quantum%  range over 24 h  p90 jump  read exactly 0
    ///        1     0.6     168.0    0.0 … 364.1      175.9      101 of 145
    ///        2     1.2      84.0    0.0 … 340.3       84.1       84
    ///        4     2.4      42.0    0.0 … 215.1       41.9       69
    ///        6     3.6      28.0    0.0 … 171.6       28.2       67
    ///        8     4.8      21.0    0.0 … 149.1       21.1       67
    ///       12     7.1      14.0    0.0 … 140.5        0.4       67
    ///       24    14.3       7.0    0.0 …  70.3        7.0       13
    ///       48    28.6       3.5   24.5 …  54.7        0.3        0
    ///
    /// "levels" is `W x 0.5952` — the points an account burns over the window at
    /// exactly 100%, and therefore how many distinct answers exist at the anchor
    /// of the scale. A short window spends most of its time pinned at exactly 0.
    /// `n` divides the quantum, so contributors buy levels the same way hours do:
    /// the confident zero is a property of `W x n` rather than of `W`.
    ///
    /// A short window does not read negative: between resets the series does not
    /// decay (every negative step is the −1 sawtooth or a reset), and `measure`
    /// cannot express a negative anyway.
    ///
    /// 8 is chosen inside a band. Below, the window has to clear
    /// `minimumMeasuredHours` by more than the gap between its left edge and the
    /// first reading inside it (at exactly 6 h every account is refused). Above,
    /// the bursts the figure exists to show get diluted: busy stretches on this
    /// fleet run 3 h at the median and 7 h at p90. Eight gives two hours of slack
    /// over the floor and a quantum of 10.5% at two contributors and 21% at one.
    static let burnWindowHours: Double = 8

    /// The least of `burnWindowHours` an account has to have been *watched* over
    /// to be counted — a coverage rule.
    ///
    /// The rate is compared against a *week* of refill, so a short span is a
    /// large multiplier over a small measurement: at two hours one percentage
    /// point of the sawtooth (§4) is 84 pp/week per account, against 28 at six.
    /// Every account is measured over the same trailing window, so what this
    /// refuses is an account that went **quiet inside that window**: 6 h of
    /// readings inside 8 is 75% coverage, and an account the gateway stopped
    /// polling more than two hours ago cannot say what it is burning now.
    ///
    /// An account is either polled densely (median gap 60 to 63 s, p99 0.08 h)
    /// or missing for hours (holes of 25 h and 52 h have been seen), so the slack
    /// over this floor is sized against holes rather than ordinary jitter.
    ///
    /// It also caps the noise of an admitted account: at the floor the quantum is
    /// 28% for one contributor rather than the 21% a full window gives.
    static let minimumMeasuredHours: Double = 6

    /// The reading at which an account is out of quota and its demand stops
    /// being visible. The gateway reports utilisation as per cent, 0…100, so
    /// this is the ceiling itself rather than a margin below it.
    private static let ceilingPercent: Double = 100

    /// One account's whole quota per window, in percentage points. This is what
    /// makes capacity a countable thing: an account is worth exactly one window
    /// per week, whatever it spent last week.
    private static let quotaPerAccount: Double = 100

    /// The window everything here is denominated in, and it is exactly seven
    /// days: the announced next reset falls 7.0002 days after the last reading of
    /// the window that ended. Counted from the first zero reading it is slightly
    /// shorter, and that shortfall is the lag of the sample that caught the reset
    /// (42 s on main and 285 s on acc2), not a shorter window. Both the
    /// extrapolation to a week and the window start derived from `resetsAt`
    /// stand on that.
    private static let hoursPerWeek: Double = 168

    /// What one account's series says about it: the burn over a span, taken
    /// from the two ends. The fleet figure is this function summed over the
    /// accounts (`burnAgainstRefill`).
    struct Measurement {
        /// Percentage points burned over `hours`, never negative.
        var burnPP: Double
        var hours: Double
        /// At its ceiling at least once, and below it at least once — a series
        /// that never left the ceiling is refused outright rather than flagged
        /// (the guard below says why).
        ///
        /// The points such an account was blocked from burning never entered its
        /// series at all, so its burn is understated and everything drawn from it
        /// is a floor (`FleetBurn.isLowerBound`).
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
    /// positive deltas charges every one of them as spend (198 pp against 56 by
    /// the endpoints on one 47 h series). Endpoints cannot accumulate that error.
    /// The sawtooth is one-sided *downward*: a reading is either the truth or the
    /// truth minus one, never above it. So a pair of endpoints understates by at
    /// most one point, and an interval with no reset in it can read −1 and
    /// nothing lower — which is why the refusal below asks `rawChange < -1` and
    /// not `< -2`.
    ///
    /// **A reset is charged the level it fell from, and not a flat window**: an
    /// account that fell from 66 had spent 66 points of that window, and no more.
    /// An *observed* fall is charged its level without consulting the schedule;
    /// `resetsAt` is asked exactly once — about a reset no reading saw. There
    /// there is no level to charge, so a whole window is charged, which can
    /// over-charge an account that had spent little of it.
    ///
    /// Known over-charge: either end of the interval can land on the wrong side
    /// of a flip-flop across a reset (the note beside the clamp).
    ///
    ///     [44, 66, 0, 66]      last on the pre-reset value   88 pp, truth 22
    ///     [0, 66, 0, 10, 42]   first on the post-reset zero  108 pp, truth 42
    ///
    /// `min(falls, 1)` reaches neither: what is wrong is which side of the one
    /// charged fall `first` and `last` sit on. A flip-flop lasts about 23 to 65 s
    /// and the histories are re-asked every `UsageStore.historyIntervalSeconds`
    /// = 600 s, so with two edges the chance of catching one is about 8 to 22%
    /// per reset per account. Pinned by
    /// `FleetCapacityTests.testAWindowEdgeInsideAFlipFlopChargesTheWrongWindow`,
    /// which asserts the over-charges rather than the truths.
    ///
    /// Known under-charge: charging the level assumes the last pre-fall reading
    /// is current. After a hole it is stale, and the charge falls short by up to
    /// the headroom at that reading — an error toward calm. No `≥` is raised for
    /// it: a flag would need a threshold on the reading's age, and nothing
    /// calibrates one (§2.7). Pinned by
    /// `FleetCapacityTests.testAFallAfterAHoleIsChargedAStaleLevel`.
    ///
    /// Nothing is smoothed on the way in, and `UsageHistoryModel.withoutSourceLag`
    /// is not used: untouched edges are a requirement of §4 that two tests hold.
    /// A median endpoint destroys a reset at the edge of the interval — an
    /// account pinned at its ceiling that turns over on the last sample would
    /// read as one that spent a whole window in a day — and ±1 pp of sawtooth is
    /// by two orders of magnitude the cheaper error.
    ///
    /// One shape gets past everything below: a hole that hides a reset *and*
    /// lets the new window climb back to within a point of the pre-reset reading
    /// or past it leaves no signature at all — no fall to count, nothing far
    /// enough negative to refuse. Above the reading it is a small positive burn
    /// (`[95, nil, nil, nil, 97]` reads 2 pp where the truth is 102); a point
    /// below it, the reading falls inside the sawtooth band the refusal leaves
    /// alone and `max(0, …)` serves it as a confident zero (`[95, nil, nil, nil,
    /// 94]` reads 0 pp where a counted reset answers 99). A named `resetsAt` does
    /// not save either: the schedule is read only over readings that already
    /// fell, since a schedule consulted on its own invents resets that never
    /// happened. It takes roughly four days of silence for the new window to
    /// climb that far; holes of 24 h have been observed.
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

        var falls = 0
        // The reading the *first* fall started from, which is the level that
        // window held when it turned over. Only the first, because only the
        // first is charged (the clamp below).
        var firstFallLevel = 0.0
        var hitCeiling = first.value >= ceilingPercent
        var everBelowCeiling = first.value < ceilingPercent
        var previous = first.value
        for reading in readings.dropFirst() {
            // Consecutive *readings*: a hole is stepped over rather than treated
            // as a boundary, because a window that turned over while the gateway
            // was not looking turned over all the same.
            if previous - reading.value > resetDropThreshold {
                if falls == 0 { firstFallLevel = previous }
                falls += 1
            }
            if reading.value < ceilingPercent { everBelowCeiling = true } else { hitCeiling = true }
            previous = reading.value
        }

        // An account that never left its ceiling was not measured at all: it
        // served nothing it was asked for, so its series is flat at 100 and its
        // burn reads as zero — a demand of nought and a whole window of capacity
        // handed to the fleet by the one account that certainly had none to
        // spare. Three accounts, one exhausted throughout and two burning 10 pp
        // each over the 8 h window, answer 140% that way against the 210% the two
        // measurable ones read: the most alarming fact about a fleet moving the
        // number 70 points towards calm. So it goes out the way a too-short
        // history does, contributing neither demand nor capacity — its demand
        // was not zero, it was blocked and invisible, and unknown is not zero
        // (§2.7). A ceiling over *part* of the interval is a different thing and
        // stays: that account still shows a rate, and it raises `isLowerBound`.
        guard everBelowCeiling else { return nil }

        // At most one reset per interval, unconditionally, and it is the *first*
        // fall that is charged. A seven-day window cannot turn over twice inside
        // seven days, and no interval reaching here is that long, so a second
        // fall over the threshold is a lagging sample beside a real reset rather
        // than a second window.
        //
        // This is load-bearing: the two measuring sources disagree for about a
        // minute across a reset (§4), so the series flip-flops — e.g. `66 → 0`
        // three times within 30 s. Unclamped, charging each fall the level it
        // fell from would credit 198 pp where the truth is 66.
        let resets = min(falls, 1)
        var credit = firstFallLevel * Double(resets)

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
        // Both halves are needed. The schedule alone, with a tolerance around the
        // boundary, counts a reset when the left edge slides just past a reset
        // instant: the first reading is already the post-reset value and nothing
        // happened inside the interval. A boundary inside the interval whose fall
        // the gateway actually saw is already counted by the loop above, and the
        // observation lag (see `hoursPerWeek`) only ever moves that fall *later*,
        // never out of the interval.
        if resets == 0, rawChange < -1 {
            if let resetsAt, case let windowStart = resetsAt.addingTimeInterval(-hoursPerWeek * 3600),
               windowStart > first.at, windowStart < last.at {
                // The one place the flat window survives: nothing observed the
                // fall, so there is no level to charge and a whole window is
                // what is left. It errs upward, over an account that may have
                // spent little of it — the header says how far that can go.
                credit = quotaPerAccount
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
        let burn = rawChange + credit
        return Measurement(burnPP: max(0, burn), hours: hours, hitCeiling: hitCeiling)
    }

    // MARK: - The fleet figure

    /// What one pass over the fleet found: how fast it is burning its quota,
    /// against how fast that quota comes back.
    struct FleetBurn: Sendable, Equatable {
        /// The burn rate as a per cent of the refill rate. 100 is a fleet
        /// spending exactly what comes back over the same hours; above that the
        /// quota runs out before the windows turn over.
        let percent: Double
        /// The fleet's burn in percentage points of a week per hour — the sum of
        /// the accounts' own rates, which is the numerator of `percent` and the
        /// figure `--dump` prints beside it.
        let burnRate: Double
        /// What the same accounts refill at, in the same unit:
        /// `contributors x quotaPerAccount / hoursPerWeek`. Named rather than
        /// derived at each use so the two sides of the division are one
        /// statement, and printed beside the burn for the same reason.
        let refillRate: Double
        /// How many accounts actually contributed a rate — which is exactly how
        /// many the refill rate counts. Not how many the gateway knows about.
        let accounts: Int
        /// The shortest per-account span that went in: how much watching stands
        /// behind the answer. The answer is only as well measured as its
        /// worst-measured contributor.
        ///
        /// It is capped at `burnWindowHours`, so it reports how much of the
        /// window each account was awake for. A densely polled fleet reads about
        /// the window itself; anything less is an account that went quiet inside
        /// it, refused altogether once it drops under `minimumMeasuredHours`. An
        /// account that lost two hours of an 8 h window is measured over 6 and
        /// averaged, unweighted, beside one measured over 8.
        let measuredHours: Double
        /// An account sat at its ceiling while it was measured, so the points it
        /// was blocked from burning never entered its series at all: the real
        /// figure is at least this one, and the surface that prints it owes the
        /// reader a `≥`.
        ///
        /// What it carries is that measurement was suppressed, and nothing about
        /// how much: the requests an exhausted account turned away leave no trace
        /// to count, so the gap between this figure and the truth is unbounded —
        /// an account blocked for an hour and one blocked for two days raise the
        /// same flag. It is a warning that the number is a floor, not a margin on
        /// it.
        ///
        /// **An account that leaves the fleet must not raise it** — whether it
        /// spent the whole span at the ceiling (`measure` refuses it) or the
        /// operator switched it off (`switchedOff`). For an account that is
        /// *included* with a partial ceiling, suppressed burn is missing from the
        /// numerator while its full refill share stays in the denominator, so the
        /// quotient can only be too low and `≥` is a fact. An *excluded* account
        /// takes a burn term **and** its refill share, and the mean moves
        /// whichever way that account's true rate sat relative to the others'.
        /// Worked out: three accounts refilling 0.5952 pp/h each, two burning
        /// 1.0 pp/h and one pinned throughout. Excluded, the fleet reads
        /// 2.0 / (2 x 0.5952) = 168%. Had the pinned account been measurable at
        /// 0.7 pp/h the answer would be 2.7 / (3 x 0.5952) = 151%; at 1.5 pp/h it
        /// would be 196%. Excluding a switched-off account has been seen to move
        /// the figure down on one day and up on another. The direction is
        /// unknown, and a `≥` that may point the wrong way is worse than none
        /// (§2.7).
        ///
        /// The boundary between the two is a single reading — `everBelowCeiling`
        /// is a one-sample probe: `[100, 99, 100, 100, 100]` beside a spending
        /// account answers 105% with the mark, the same series without the 99
        /// answers 210% without it. Both sides are held together by
        /// `testOneReadingBelowTheCeilingIsTheWholeDifferenceBetweenMeasuredAndRefused`.
        /// Whether the sawtooth actually carries a pinned account across that
        /// boundary is not decidable from the data, and §2.7 records the negative
        /// result rather than a threshold nothing could calibrate.
        let isLowerBound: Bool
    }

    /// The fleet's burn against its refill, or `nil` when there is nobody to
    /// measure.
    ///
    /// ```
    /// burn rate,   per account = burnPP / hours                   [pp/h]
    /// refill rate, per account = quotaPerAccount / hoursPerWeek    [pp/h]
    /// percent = sum of the burn rates / (contributors x refill rate) x 100
    /// ```
    ///
    /// **The summing form is per account, then summed** — the unweighted mean of
    /// the per-account rates, not `sum of burn / sum of refill`. Accounts can be
    /// watched over different spans inside the window (one that went quiet for
    /// two hours is measured over six), and pooling would credit the quiet
    /// account's missing hours to its neighbours (`measuredHours`).
    ///
    /// Contributors are the accounts `measure` could answer for, and the refill
    /// counts them and nobody else: an account we could not measure must never
    /// widen a denominator its own burn is missing from (§2.7).
    ///
    /// **Every account is measured over the same trailing `burnWindowHours`**, so
    /// the unweighted average never mixes different stretches of time. Trimming
    /// happens here rather than inside `measure`: which stretch the fleet is
    /// asked about is a fleet decision, while `measure` answers "what does this
    /// series say about its own span".
    ///
    /// **An account the operator has switched off is not a contributor** and its
    /// refill share leaves with it. The flag is `disabled` from `/gw/status` and
    /// never `eligible`, which is a different question wearing the same shape:
    /// `eligible` goes false the moment a five-hour window fills, over an account
    /// that is in the rotation and will be back by itself within the hour, and
    /// dropping that one would take a live account's burn out of the numerator
    /// (`AccountSwitch`). The gateway also stops polling a switched-off account,
    /// so its series would age out of the window on its own
    /// `burnWindowHours - minimumMeasuredHours` later; the flag covers those
    /// hours and does not depend on that incidental gateway behaviour.
    ///
    /// **One statement guards one division.** With no contributor the refill rate
    /// is zero and the answer would be `0 / 0` — a published `NaN` rather than a
    /// missing figure, and every surface would draw that as a reading. A fleet
    /// the gateway named no accounts for, a fleet whose every history was too
    /// short, and a fleet whose every account the operator has switched off all
    /// reach it by the same path, which is why the guard counts contributors
    /// rather than accounts.
    static func burnAgainstRefill(histories: [String: HistorySeries],
                                  accounts: [AccountUsage],
                                  switchedOff: Set<String>,
                                  now: Date) -> FleetBurn? {
        var burnPerHour = 0.0
        var contributors = 0
        var shortestHours = Double.greatestFiniteMagnitude
        var blocked = false
        let since = now.addingTimeInterval(-burnWindowHours * 3600)

        for account in accounts {
            guard !switchedOff.contains(account.label) else { continue }
            guard let series = histories[account.label] else { continue }
            // The window is closed at both ends rather than open at the top: a
            // reading stamped after `now` is a clock disagreement rather than a
            // measurement of the future, and letting one in would stretch the span
            // the rate is divided by.
            let inWindow = series.points.filter { $0.timestamp >= since && $0.timestamp <= now }
            guard let measured = measure(inWindow,
                                         resetsAt: account.sevenDay?.resetsAt) else { continue }
            burnPerHour += measured.burnPP / measured.hours
            contributors += 1
            shortestHours = min(shortestHours, measured.hours)
            blocked = blocked || measured.hitCeiling
        }

        guard contributors > 0 else { return nil }
        let refillPerHour = Double(contributors) * quotaPerAccount / hoursPerWeek
        return FleetBurn(percent: burnPerHour / refillPerHour * 100,
                         burnRate: burnPerHour,
                         refillRate: refillPerHour,
                         accounts: contributors,
                         measuredHours: shortestHours,
                         isLowerBound: blocked)
    }
}
