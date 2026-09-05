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
/// **Both sides of the comparison are percentage points of a week, and that is
/// the whole shape of this file.** The question the figure answers is "am I
/// spending faster than the quota comes back", and `util_7d` is already
/// denominated in exactly what the question is about — the supplier computes it,
/// and it already prices Opus above Sonnet. So:
///
///     burn rate,   per account = points burned over the window / hours of it
///     refill rate, per account = quotaPerAccount / hoursPerWeek
///     percent = (sum of the burn rates) / (contributors x refill rate) x 100
///
/// A per cent over a per cent: the model mix cancels out of the question, and
/// nothing is converted on the way to the answer.
///
/// **This is not a new estimator.** It is `windowAverage`, which lived in this
/// file until 2026-08-24 and was deleted in `787c972` as "an estimate of
/// something the gateway now measures". That reasoning was wrong in one specific
/// way worth writing down: the `tokens` block of `GET /gw/usage` measures a
/// *five-minute token rate*, which is a different quantity from *the burn rate
/// against the refill rate over two days*. Two questions, not two answers to
/// one. The token rate is still measured and still drawn — as a second reading
/// that is the numerator of nothing and colours nothing (§4).
///
/// What went instead is the allowance that replaced it, and everything it was
/// built from: the hour-by-hour decomposition, the split of the day into working
/// and sleeping hours, and the price of a point in tokens. Each of them was a
/// conversion between the question and the unit it was being answered in, and
/// each of them moved — a five-minute numerator that jumps, a day split whose
/// hours cross the threshold in blocks (one hour was worth 10 to 20 points of
/// the answer, measured 2026-08-18), and an exchange rate that depends on which
/// models happened to run in the window.
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

    /// The shortest interval `measure` will answer over, and it is back on the
    /// app's path with the justification it was originally chosen for.
    ///
    /// The rate this function produces is compared against a *week* of refill, so
    /// a short span is a large multiplier over a small measurement. At two hours
    /// of history a single percentage point — the exact width of the sawtooth
    /// (§4) — is 84 pp/week per account, four fifths of a whole quota; six hours
    /// hold that at 28.
    ///
    /// It is what refuses the 6 h row of the table over
    /// `UsageStore.historyWindowSeconds`: a series asked for six hours comes back
    /// 5.99 h long, every account falls under this floor, and the fleet has no
    /// figure at all. While the allowance existed nothing on the app's path
    /// reached this line — the day split refused a whole day first, four times
    /// this — and the comment here said as much. The allowance is gone and this
    /// is the floor again.
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

    /// What one account's series says about it: the burn over a span, taken
    /// from the two ends.
    ///
    /// **It is the production path again**, which is what it was before the
    /// allowance existed. For the round in between nothing the app drew went
    /// through it and it survived as "the coarse method the fine one is held to"
    /// — the hour-by-hour decomposition had to reconcile with it, and
    /// `testHourBucketsReconcileWithTheSpanMethod` was its only reader. That
    /// decomposition is gone with the allowance, and the fleet figure is this
    /// function summed over the accounts (`burnAgainstRefill`).
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
        /// is a floor. The field lived here until 2026-08-24 and went when the
        /// estimator that read it went; it is back because the figure that reads
        /// it is back (`FleetBurn.isLowerBound`).
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
    /// **A reset is charged the level it fell from, and not a flat window.** The
    /// stretch before a turnover is worth the reading the window turned over at:
    /// an account that fell from 66 had spent 66 points of that window, and no
    /// more.
    ///
    /// A flat `+ 100` stood here until 2026-09-05, on the reasoning that the
    /// window "had been spent to its ceiling" before turning over — an
    /// approximation documented as erring upward, bounded by the headroom, and
    /// observed at 0 pp and 1 pp on the two resets the history had ever held
    /// (100 → 0 on acc2 and 99 → 0 on main, 2026-08-17). **That bound does not
    /// hold on today's data and the error is no longer small.** Measured
    /// 2026-09-05 02:50Z over the live 48 h histories:
    ///
    ///     acc2  09-04 20:05:38Z  66 → 0    flat 76 pp, level 42 pp, over by 34
    ///     main  09-04 20:05:18Z  96 → 0    flat 46 pp, level 42 pp, over by  4
    ///     acc3  no fall in this window     flat  9 pp, level  9 pp
    ///
    /// acc3 shows no fall to this probe because its series ended 14 h before it
    /// (§2.7) and stopped short of its own turnover; read again on a week-long
    /// request at 20:26Z it holds one, `50 → 0` — but **not on 09-04 and not
    /// across an eight-minute hole**, which is what stood here until 2026-09-05.
    /// The hole is **24.14 h** wide, 09-04 12:53:44Z → 09-05 13:01:51Z, and the
    /// zero is recorded on **09-05**: the probe printed the date of the fall's
    /// left end only and its width, 86887 s, on the same line, and the width was
    /// read past. Its consequences are worked through under the clamp below and
    /// in §2.7.
    ///
    /// The other two accounts turned over in the same minute, and **none of the
    /// three falls matches its own `resetsAt`** — acc2's window is announced to
    /// end 2026-09-05T21:00:00Z, 18.2 h after the probe, main's
    /// 2026-09-06T15:00:00Z, and acc3's 2026-09-09T03:00:00Z, which puts its
    /// current window's start at 09-02 03:00Z, running straight *through* the
    /// 09-05 13:01 fall (measured 2026-09-05 20:26Z). So this is three falls in
    /// two days that the announced schedule does not explain, rather than the
    /// one-off "whatever caused it" this paragraph used to call the pair of
    /// 09-04. **That mismatch is not a defect here**: an *observed* fall is
    /// charged its level without consulting the schedule at all, and `resetsAt`
    /// is asked exactly once — about a reset no reading saw. That is deliberate
    /// and it stays.
    ///
    /// acc2 fell from **66**, and charging it a whole window invents 34 points of
    /// spending that never happened. On the fleet figure the two rules answer
    /// 157.2% and 112.8%: the difference between "burning half again as fast as
    /// it refills" and "burning about as fast as it refills".
    ///
    /// **The flat window survives for exactly one case**, and it is the case with
    /// no level to charge: a reset *inferred* from `resetsAt` inside a hole,
    /// where the pre-fall reading was never observed. There the charge can be a
    /// whole window over an account that had spent little of it — the old
    /// approximation, kept where nothing better exists.
    ///
    /// One hazard documented rather than fixed, and **it has two cases, not
    /// one**: the interval has two ends and either of them can land on the wrong
    /// side of a flip-flop (the note beside the clamp).
    ///
    ///     [44, 66, 0, 66]      last on the pre-reset value   88 pp, truth 22
    ///     [0, 66, 0, 10, 42]   first on the post-reset zero  108 pp, truth 42
    ///
    /// The first was written here from the start: `last - first + level` counts
    /// that account's window twice. The mirror was written nowhere and is just as
    /// reachable — the window's *first* reading landing on the post-reset zero
    /// means the interval opened after the turnover, so the fall it sees belongs
    /// to a window it does not cover, and the level is credited to an account
    /// that had already been reset. `min(falls, 1)` reaches neither: it collapses
    /// the falls, and what is wrong is which side of the one charged fall `first`
    /// and `last` sit on.
    ///
    /// **How reachable, in numbers — and it is a range, not one figure.** The
    /// width depends on how it is defined, so the definition is part of the
    /// number: from the first post-reset reading to the last pre-reset one, the
    /// stretch in which a window edge lands on the wrong side of the charged
    /// fall. Over the reset of 2026-09-04 that is 20:05:38 → 20:06:01 on acc2,
    /// about 23 s, and 20:05:18 → 20:06:23 on main, about 65 s (measured
    /// 2026-09-05 17:15Z). The edges of the window sweep continuously, and the
    /// histories are re-asked every `UsageStore.historyIntervalSeconds` = 600 s,
    /// so **one** edge lands inside a given flip-flop with probability about
    /// 23/600 to 65/600 — **4 to 11%**, per reset per account, once a week each.
    /// **There are two edges and each sweeps the flip-flop once per reset**, so
    /// "either edge caught it" is twice that: 46/600 to 130/600, **8 to 22%**.
    /// (Both at once is impossible — a minute-wide flip-flop against a 48 h
    /// interval.) Only the narrow end of the width stood here before; counting
    /// one edge of two was the same understatement in the same direction,
    /// because this estimate is the whole argument for *tolerating* the
    /// over-charge rather than fixing it, and quoting the cheap half — of the
    /// width or of the edge count — biases that decision toward "tolerable". The
    /// flat rule had the same hazard one point worse. Both are pinned by
    /// `FleetCapacityTests.testAWindowEdgeInsideAFlipFlopChargesTheWrongWindow`,
    /// which asserts the over-charges rather than the truths, and says so.
    ///
    /// **The level rule has a blind spot of its own, mirroring the flat rule's,
    /// and today's data instantiates it.** Charging the level the series fell
    /// from assumes the last pre-fall reading is *current*. After a hole it is
    /// stale and the charge comes out too small: acc3's last reading before its
    /// 24.14 h hole is **50**, whatever the window climbed to during that day is
    /// unknown, and the fall is charged 50. The undercharge is bounded by the
    /// headroom at that reading — up to 50 pp here — exactly as the flat rule's
    /// over-charge is bounded by the headroom at the ceiling. **The direction is
    /// the difference and it is why this is not a footnote**: the flat rule errs
    /// loud, inventing spend, and the level rule errs *quiet*, hiding it — and
    /// quiet errs toward calm, which is the unsafe side. Measured 2026-09-05
    /// 20:29Z over the 48 h the app asks for, acc2 and main unchanged: acc3
    /// charged its level of 50 burns 6 pp over 44.48 h and the fleet reads
    /// **199.1%**; the same fleet with acc3 charged a flat 100 burns 56 pp and
    /// reads **262.0%** — 62.9 points of ratio apart, with the truth somewhere
    /// between, since nothing says where inside the hole the window stood.
    ///
    /// **No `≥` is raised for it, and that is a decision rather than an
    /// oversight.** The ceiling case can raise one because the series states the
    /// evidence itself, in a single reading. Here there is no such reading: a
    /// flag would need a rule for "the pre-fall reading is stale", i.e. a
    /// threshold on its age, and nothing calibrates such a constant — the only
    /// hole of this size on record is this one, and a threshold from one
    /// observation is a number out of the air. §2.7 keeps that as a negative
    /// result. Pinned by
    /// `FleetCapacityTests.testAFallAfterAHoleIsChargedAStaleLevel`.
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
    /// to climb that far.
    ///
    /// **"Holes that big do not happen" is retracted, and the margin is fourfold
    /// rather than three-hundredfold.** What followed here until 2026-09-05 was
    /// "and the longest gap between two readings in the live history is 18.18
    /// minutes", from which four days of silence read as out of reach. That
    /// measurement stands *for its day* (2026-08-17, three accounts, median gap
    /// 64 s) and is kept as dated history rather than as a property of the
    /// gateway: on 2026-09-05 20:26Z acc3's week holds a **24.14 h** hole,
    /// 09-04 12:53:44Z → 09-05 13:01:51Z, against a next-largest gap anywhere
    /// that week of 0.17 h. Four days against 24.14 h is about **4x**, not 300x.
    /// And a fall sits at the far end of that very hole — an *observed* one, so
    /// this blind spot did not fire; the neighbouring one did, the level charged
    /// from a stale reading (the header). What is left of "unreachable" is
    /// "unobserved": holes of the needed width do happen now, and the
    /// coincidence of a hole with a window climbing back to within a point has
    /// still never been seen.
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
        // spare. Three accounts, one exhausted throughout and two burning 50 pp
        // each over 48 h, answer 116.7% that way against the 175% the two
        // measurable ones read: the most alarming fact about a fleet moving the
        // number 58 points towards calm. So it goes out the way a too-short
        // history does, contributing neither demand nor capacity — its demand
        // was not zero, it was blocked and invisible, and unknown is not zero
        // (§2.7). A ceiling over *part* of the interval is a different thing and
        // stays: that account still shows a rate, and it raises `isLowerBound`.
        guard everBelowCeiling else { return nil }

        // At most one reset per interval, unconditionally, and it is the *first*
        // fall that is charged. A seven-day window cannot turn over twice inside
        // seven days, so a second fall over the threshold is a lagging sample
        // beside a real reset rather than a second window.
        //
        // **It is load-bearing on live data, and it was not when it was
        // written.** The two measuring sources disagree for about a minute
        // across a reset (§4), so the series flip-flops: over the reset of
        // 2026-09-04 the live history shows **three** falls for each of acc2 and
        // main, and from different levels — acc2 `66 → 0` at 20:05:38, 20:05:54
        // and 20:06:04, main `96 → 0` at 20:05:18, 20:05:46 and 20:06:25
        // (measured 2026-09-05 17:15Z). Unclamped, charging each fall the level
        // it fell from credits acc2 198 pp where the truth is 66, and main
        // 288 pp where it is 96.
        //
        // **acc3 says nothing about this reset: it has no reading across the
        // event at all**, its series being silent for 24.14 h from
        // 09-04 12:53:44Z to 09-05 13:01:51Z. "acc3 did not flip-flop that day"
        // stood here until 2026-09-05 and is a claim that could not have come
        // out false — there was no witness — so "two of three accounts on the
        // same reset" does not follow and is withdrawn: acc3's own fall is a
        // different event, some 17 h later, at the far end of that hole.
        //
        // The mechanism that stood beside it — that polling frequency is what
        // decides — is **not shown by this data either** and is recorded as
        // unestablished. A 24 h hole swallows any event whatever, so it says
        // nothing about cadence; and outside the hole acc3 is polled much like
        // the others: measured 2026-09-05 20:26Z over the week-long series, its
        // median gap is 63 s against 60 s on acc2 and 61 s on main (32.9
        // readings an hour against 42.6 and 45.7, counting only gaps of 600 s or
        // less). A minute-wide disagreement has nowhere to fall between readings
        // that close. The figure 13.2 readings an hour is an *average over a
        // window* this very hole dilutes, and it survives only where the claim
        // is about that average — the `max_points` note below.
        //
        // The two resets on record in 2026-08 were clean by contrast,
        // `100, 100, 100, 100, 0, 0, 0, 0` on acc2 and `99, 99, 99, 99, 0, 0, 0,
        // 0` on main with exactly one fall each, which is why this clamp spent
        // its first round as a precaution.
        //
        // The clamp used to be conditional on `hours <= hoursPerWeek`, guarding
        // a span long enough to hold two real resets. No such span can reach
        // here, and that is a property of the source rather than of this
        // function. `since` is honoured on the left edge — asking for *less* does
        // shorten the answer — but asking for more runs into `max_points` of
        // 2000 against a poll of 13 to 46 readings an hour. Asked for a whole
        // week on 2026-09-05 15:35Z the three accounts answer 59.89, 86.83 and
        // 43.09 h, all three `truncated`; the deepest is 86.83 h and a week is
        // still nearly twice that.
        //
        // **Retention was named here as the second ceiling and it is not one.**
        // The reading of 2026-08-17 — main at 1581 points, not truncated, still
        // stopping at 65.85 h — said the gateway simply kept no more, and on that
        // day nothing contradicted it. Today no account is held by retention at
        // all: every one of them is stopped by the cap, and the account that used
        // to be the deepest is now the shallowest, because it is the one the
        // gateway polls hardest (46.4 readings an hour against acc3's 13.2). The
        // cap counts points, not hours, which is the whole of it
        // (`UsageStore.historyWindowSeconds` carries the table).
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
        /// worst-measured contributor, and the depths differ — 43.09 / 47.88 /
        /// 47.91 h over main / acc3 / acc2, measured 2026-09-05 15:35Z over the
        /// 48 h the app asks for. Earlier the same day, at 02:50Z, the same three
        /// read 48.0 / 34.0 / 48.0 h: acc3's series was stale by 14 h that
        /// morning and was fresh to the second by the afternoon (§2.7). Two
        /// measurements of a moving thing, not a contradiction — which is why
        /// both carry a time and not just a date.
        ///
        /// **The mechanism is the `max_points` cap, and the illustration of it
        /// flipped between August and September.** The cap counts points, not
        /// hours, so the same 2000 points cover the fewer hours the harder the
        /// gateway polls an account: 46.4, 38.7 and 13.2 readings an hour over
        /// main, acc2 and acc3 at 2026-09-05 15:35Z — 47.1, 40.8 and 14.1 at
        /// 17:01Z the same day, which is why the time is part of the citation —
        /// and main, the most watched, is
        /// both the `truncated` one and the shallowest. On 2026-08-17 it was the
        /// other way round: main came back at 1581 points, *not* truncated, and
        /// was the deepest of the three, against 38.6 and 38.1 readings an hour
        /// on acc2 and acc3. That dated shape is kept here as the counter-example
        /// it now is: the rule is the cap against the polling rate, never the
        /// ordering of the three accounts, which is a property of the day.
        let measuredHours: Double
        /// An account sat at its ceiling while it was measured, so the points it
        /// was blocked from burning never entered its series at all: the real
        /// figure is at least this one, and the surface that prints it owes the
        /// reader a `≥`.
        ///
        /// **The reason is shorter than it used to be, and it points the other
        /// way.** While the figure was a token rate over an allowance, a blocked
        /// account inflated the *denominator* three ways at once and the ratio
        /// drawn against it read low. Here it is the numerator that is
        /// suppressed: burn that could not happen is burn that never entered the
        /// series, so the burn rate is understated and the ratio with it.
        ///
        /// What it carries is that measurement was suppressed, and nothing about
        /// how much: the requests an exhausted account turned away leave no trace
        /// to count, so the gap between this figure and the truth is unbounded —
        /// an account blocked for an hour and one blocked for two days raise the
        /// same flag. It is a warning that the number is a floor, not a margin on
        /// it. Live example: acc2 spent 34 samples at 100 during a 48 h window,
        /// 2026-08-17.
        ///
        /// An account that spent the *whole* span at the ceiling does not raise
        /// it, because it is not counted at all (`measure` refuses it, for the
        /// reason given there); that fleet is smaller by one in `accounts`
        /// instead.
        ///
        /// **And it must not raise it, which is the asymmetry worth spelling
        /// out**, because the obvious symmetry — "blocked is blocked, mark it
        /// either way" — is wrong. For an account that is *included* with a
        /// partial ceiling, suppressed burn is missing from the numerator while
        /// its full refill share stays in the denominator, so the quotient can
        /// only be too low and `≥` is a fact. For an *excluded* account the
        /// numerator loses a term **and** the denominator loses that account's
        /// refill share, and the mean moves whichever way that account's true
        /// rate sat relative to the others'. Worked out: three accounts refilling
        /// 0.5952 pp/h each, two burning 1.0 pp/h and one pinned throughout.
        /// Excluded, the fleet reads 2.0 / (2 x 0.5952) = 168%. Had the pinned
        /// account been measurable at 0.7 pp/h the answer would be
        /// 2.7 / (3 x 0.5952) = 151%; at 1.5 pp/h it would be 196%. The direction
        /// is unknown, so there is nothing to assert, and a `≥` that may point
        /// the wrong way is worse than none (§2.7).
        ///
        /// The boundary between the two is a single reading — `everBelowCeiling`
        /// is a one-sample probe — and what that reading is worth is measured:
        /// `[100, 99, 100, 100, 100]` beside a spending account answers 87.5%
        /// with the mark, the same series without the 99 answers 175% without it.
        /// Both sides are held together in one place, by
        /// `testOneReadingBelowTheCeilingIsTheWholeDifferenceBetweenMeasuredAndRefused`.
        /// Whether the sawtooth actually
        /// carries a pinned account across that boundary is **not decidable from
        /// today's data**, and §2.7 records the negative result rather than a
        /// threshold nothing could calibrate.
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
    /// the per-account rates, which is what `windowAverage` did before it. Not
    /// `sum of burn / sum of refill`: the accounts are watched over different
    /// depths, and pooling credits the shallow account's missing hours to the
    /// others. Measured 2026-09-05 02:50Z over spans of 48.0 / 34.0 / 48.0 h the
    /// two forms answer 112.8% and 120.2%, and the whole of the difference is
    /// acc3, whose series stopped 14 h before the other two **that morning** —
    /// by 15:35Z the same three read 43.09 / 47.88 / 47.91 h and acc3 was the
    /// freshest of them. The spread is what the form is for, and the spread does
    /// not go away: it was 14 h of staleness then and it is 4.8 h of `max_points`
    /// now (`measuredHours`).
    ///
    /// Contributors are the accounts `measure` could answer for, and the refill
    /// counts them and nobody else: an account we could not measure must never
    /// widen a denominator its own burn is missing from (§2.7).
    ///
    /// **One statement guards one division.** With no contributor the refill rate
    /// is zero and the answer would be `0 / 0` — a published `NaN` rather than a
    /// missing figure, and every surface would draw that as a reading. A fleet
    /// the gateway named no accounts for and a fleet whose every history was too
    /// short reach it by the same path, which is why the guard counts
    /// contributors rather than accounts.
    static func burnAgainstRefill(histories: [String: HistorySeries],
                                  accounts: [AccountUsage]) -> FleetBurn? {
        var burnPerHour = 0.0
        var contributors = 0
        var shortestHours = Double.greatestFiniteMagnitude
        var blocked = false

        for account in accounts {
            guard let series = histories[account.label],
                  let measured = measure(series.points,
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
