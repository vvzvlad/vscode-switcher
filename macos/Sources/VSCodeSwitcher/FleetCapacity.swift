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
    let measuredHours: Double

    /// At or above this the fleet is being asked for more than the week holds.
    ///
    /// Named once because two surfaces have to agree about it — the popover's
    /// headline and the status item's bar are both green below and red at or
    /// above, and a boundary written twice is a boundary that can be moved once.
    static let capacityPercent: Double = 100

    /// Demand has caught up with supply. `>=`, not `>`: exactly 100 is a week
    /// with nothing left over, which is the state the colour is a warning about.
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
    /// along with its demand and moving the fleet figure up. The mirror shape, a
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
    static func load(histories: [String: HistorySeries], accounts: [AccountUsage]) -> FleetLoad? {
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
                         measuredHours: shortestHours)
    }

    /// What one account's series says about it.
    private struct Measurement {
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
    private static func measure(_ points: [HistoryPoint], resetsAt: Date?) -> Measurement? {
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
}
