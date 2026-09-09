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
/// against the refill rate over the trailing `burnWindowHours`*. Two questions,
/// not two answers to one. (That last window was two days when the sentence was
/// written: the figure was measured over whatever span each series held, up to
/// the 48 h the fetch asks for. Since 2026-09-09 it is eight hours, and the
/// argument is untouched by which — what makes the two questions two is the unit
/// and the subject, not the width.) The token rate is still measured and still
/// drawn — as a second reading that is the numerator of nothing and colours
/// nothing (§4).
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

    /// The trailing stretch every account is measured over, and the whole of what
    /// the figure is about: **how fast the fleet is burning now**, not on average
    /// since the gateway started keeping records.
    ///
    /// Until 2026-09-09 there was no window here at all — each account was
    /// measured over whatever span its own series happened to hold, up to the
    /// 48 h `UsageStore.historyWindowSeconds` asks for. That is a mean over two
    /// days, and a burst cannot move one: a moving average of width `W` shows a
    /// burst of duration `T` at strength `min(1, T/W)`, so an hour of three agents
    /// burning at three times the refill rate moves a 48 h figure by 4 points and
    /// an 8 h figure by 25. The user's report was "many agents running, the per
    /// cent is stuck at 93", and that arithmetic is the whole of it.
    ///
    /// **Eight hours, and the floor under it is measured rather than preferred.**
    /// The reading is integer percentage points, so a window of `W` hours can only
    /// answer in multiples of `100 / (W x 0.5952 x n)` per cent for `n`
    /// contributors — the quantum below. Measured 2026-09-09 17:43Z (load average
    /// 3.04), acc2 alone over 145 anchors 10 minutes apart across the last 24 h,
    /// the floor of `minimumMeasuredHours` lifted so that short windows can answer
    /// at all:
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
    /// of the scale. At one hour it is 0.6: the answer is 0% or 168% and there is
    /// nothing in between, which is not a noisy reading of the fleet but no
    /// reading of it. The last column is the same fact from the other side — a
    /// short window spends most of its time pinned at exactly 0, which is the
    /// calmest thing this scale can draw.
    ///
    /// **The table is one account's, and the last column is the one that moves
    /// most when it is not.** `n` divides the quantum, so contributors buy levels
    /// the same way hours do. Re-swept 2026-09-09 18:55Z at the shipped floor: a
    /// fleet of three contributors reads exactly 0% at **0** anchors of 145 over
    /// 24 h and 3 of 349 over 58 h, while today's fleet — acc3 switched off,
    /// leaving acc2 alone at 101 of the 145 anchors — reads it at 59. Every zero
    /// in both sweeps landed on a single-contributor anchor and not one on a
    /// two-contributor anchor, so the confident zero is a property of `W x n`
    /// rather than of `W`.
    ///
    /// **A short window does not read negative, and the premise that it does is
    /// withdrawn.** It was put to this round that a seven-day *rolling* window
    /// sheds old usage on its own, so a short span would see a fall with no reset
    /// in it and answer a negative burn. Neither half survives measurement. The
    /// series does not decay: over 5997 consecutive steps on the three week-deep
    /// histories (2026-09-09 17:43Z) every negative step is either exactly −1 pp,
    /// the ±1 sawtooth of §4 (141 / 154 / 137 on acc2 / acc3 / main), or the one
    /// reset each account holds (−65 / −83 / −97); not one step falls in between,
    /// where a window shedding usage would land. And `measure` has no way to
    /// express a negative anyway — a series fabricated to drift −7 pp over 8 h with
    /// no reset in the schedule is *refused* (`nil`), and a −1 tooth is served as
    /// 0 pp by the `max(0, …)` clamp. What a short window actually costs is the
    /// two columns above: quantisation, and a confident zero.
    ///
    /// **What picks 8 and not 7 or 12 is a band, not a plateau**, and saying so is
    /// the point — the constant is honest about being chosen inside a range whose
    /// ends are measured. Below, `minimumMeasuredHours` forbids it outright: a
    /// window of exactly 6.00 h holds 5.912 h of readings and every account is
    /// refused (acc2, same probe), so the window has to clear the floor by more
    /// than the gap between its left edge and the first reading inside it. Above,
    /// the burst the figure exists to show gets diluted: the busy stretches on this
    /// fleet run 3.0 h at the median and 7.0 h at p90 (21 bursts over the
    /// week-deep series, an hour counting as busy when the account burned a whole
    /// point in it — 1 h x7, 2 h x3, 3 h x3, 4 h, 5 h x2, 6 h x2, 7 h, 8 h, 18 h),
    /// so a window of 8 h shows the median burst at 3/8 of its strength where 48 h
    /// shows it at 3/48. Eight is the round number in that band: two hours of slack
    /// over the floor, a quantum of 10.5% at two contributors and 21% at one.
    static let burnWindowHours: Double = 8

    /// The least of `burnWindowHours` an account has to have been *watched* over
    /// to be counted, and with the window above it has become a coverage rule.
    ///
    /// It used to mean "a series shorter than this says too little": the rate is
    /// compared against a *week* of refill, so a short span is a large multiplier
    /// over a small measurement, and at two hours one percentage point of the
    /// sawtooth (§4) is 84 pp/week per account against 28 at six. That reasoning
    /// still holds and is now doing a different job. The span is no longer
    /// whatever the account's series happened to hold — every account is measured
    /// over the same trailing 8 h — so what this refuses is an account that went
    /// **quiet inside that window**: 6 h of readings inside 8 is 75% coverage, and
    /// an account the gateway stopped polling more than two hours ago cannot say
    /// what it is burning now.
    ///
    /// That is the case the live fleet was in on 2026-09-09, and the minute this
    /// line did the refusing can be pointed at. The gateway stopped polling acc3
    /// at 05:38:28Z, so its coverage of the window shrank an hour per hour:
    /// replaying the day's series, at the 07:30Z anchor it held 112 readings
    /// spanning 6.06 h and was measured, and at 07:35Z it held 111 spanning
    /// 5.98 h and this guard turned it away. From 07:35Z on the account is out by
    /// silence; for the not-quite two hours before that the switch
    /// (`switchedOff`) was the only thing keeping it out. Later in the day the
    /// refusal is not this
    /// line's at all, and the paragraph used to be pinned to that hour: by 18:55Z
    /// acc3's last reading is 13.29 h old and the window holds no readings of it
    /// whatever, so `measure` returns at `readings.first` and never reaches the
    /// floor. An example with nothing inside the window is an example this guard
    /// cannot run on. Holes are
    /// not rare and they are not small — main's series had a 52.37 h gap and acc2's
    /// a 25.54 h one that same day, against a median gap between readings of 60 to
    /// 63 s and a p99 of 0.08 h. An account is either polled densely or missing for
    /// hours; there is very little in between, which is why the slack over this
    /// floor is not sized against ordinary jitter (the shortfall on a densely
    /// polled account is 0.09 h at the median and 0.16 h at the worst over the
    /// 145-anchor sweep) but against holes no margin could cover anyway.
    ///
    /// It also caps the noise of an admitted account: at the floor the quantum is
    /// 28% for one contributor rather than the 21% a full window gives, and that
    /// is the worst the figure can carry.
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
        /// worst-measured contributor.
        ///
        /// **Since 2026-09-09 it is capped at `burnWindowHours`**, and what it
        /// reports is no longer how deep the gateway's records go but how much of
        /// the window each account was awake for. A fleet polled densely reads the
        /// window itself — 7.9 h on the live pair, 2026-09-09 18:20Z — and
        /// anything less is an account that went quiet inside it, refused
        /// altogether once it drops under `minimumMeasuredHours`.
        ///
        /// **The spread it exists to report survives the window**, which is the
        /// only reason the field does. Holes are what make it: main's series held a
        /// 52.37 h gap and acc2's a 25.54 h one on 2026-09-09, against a median gap
        /// between readings of 60 to 63 s. An account that lost two hours of an 8 h
        /// window is measured over 6 and averaged, unweighted, beside one measured
        /// over 8.
        ///
        /// What this field used to carry was the depth of the *fetch*, and the
        /// numbers are kept as dated history because the mechanism behind them is
        /// still live one level up (`UsageStore.historyWindowSeconds`): 43.09 /
        /// 47.88 / 47.91 h over main / acc3 / acc2 at 2026-09-05 15:35Z, against
        /// 48.0 / 34.0 / 48.0 h at 02:50Z the same morning when acc3's series was
        /// stale by 14 h. The `max_points` cap counts points and not hours, so the
        /// same 2000 points cover the fewer hours the harder an account is polled —
        /// 46.4, 38.7 and 13.2 readings an hour over main, acc2 and acc3 at 15:35Z
        /// — and in August the ordering was the other way round. The rule is the
        /// cap against the polling rate, never the ordering, which is a property of
        /// the day. None of that reaches this field any more.
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
        /// **There are two ways out of the fleet now and the argument covers both
        /// the same way.** Since 2026-09-09 an account the operator has switched
        /// off leaves as well (`switchedOff`), and it leaves for a reason that has
        /// nothing to do with ceilings — but it leaves by the same door, dropping
        /// a burn term and a refill share together, so the mean moves in a
        /// direction nothing here knows either. That is not a guess: measured on
        /// the live fleet at 2026-09-09 17:44Z, excluding the switched-off acc3
        /// moved the whole-span figure **down**, 89.7% to 55.0%, because acc3's
        /// window had turned over inside the span and it was carrying more burn
        /// than its neighbours. Earlier the same day the same exclusion moved the
        /// figure the other way, **up** from 92% to 137% — that pair is the report
        /// this round opened with rather than a reading taken here, and it is
        /// quoted as such. Same fleet, same switch, opposite directions hours
        /// apart. A `≥` on either would have been a claim about a direction that
        /// reverses within a day.
        ///
        /// So the rule is about the shape of the exclusion and not about its
        /// cause: **an account that leaves the fleet takes its refill with it and
        /// raises nothing**, whether it left at its ceiling or at the operator's
        /// hand. Only an account still inside the fleet can be a floor.
        ///
        /// The boundary between the two is a single reading — `everBelowCeiling`
        /// is a one-sample probe — and what that reading is worth is measured:
        /// `[100, 99, 100, 100, 100]` beside a spending account answers 105%
        /// with the mark, the same series without the 99 answers 210% without it.
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
    /// acc3, whose series stopped 14 h before the other two **that morning**.
    ///
    /// **The trailing window narrowed the spread without closing it**, so the form
    /// is still the right one and its reason has changed. Depth of the *fetch* no
    /// longer reaches the figure at all, so `max_points` and staleness of a
    /// fortnight-old record are somebody else's problem now; what is left is an
    /// account that went quiet *inside* the eight hours, which is common — main's
    /// series held a 52.37 h hole and acc2's a 25.54 h one on 2026-09-09. Six hours
    /// of readings inside the window against eight is the widest spread the floor
    /// admits, and pooling would still credit the quiet account's two hours to its
    /// neighbours (`measuredHours`).
    ///
    /// Contributors are the accounts `measure` could answer for, and the refill
    /// counts them and nobody else: an account we could not measure must never
    /// widen a denominator its own burn is missing from (§2.7).
    ///
    /// **Every account is measured over the same trailing `burnWindowHours`**, and
    /// the same-ness is as load-bearing as the length. The rates are averaged
    /// unweighted, so accounts answering about different stretches of time are
    /// averaged across epochs — which is what the whole-span form did until
    /// 2026-09-09, when acc2 answered about 46.9 h, main about 11.9 and acc3 about
    /// 36 h that had ended twelve hours earlier. Trimming here rather than inside
    /// `measure` is deliberate: which stretch the fleet is asked about is a fleet
    /// decision, while `measure` goes on answering "what does this series say
    /// about its own span".
    ///
    /// **An account the operator has switched off is not a contributor** and its
    /// refill share leaves with it. The flag is `disabled` from `/gw/status` and
    /// never `eligible`, which is a different question wearing the same shape:
    /// `eligible` goes false the moment a five-hour window fills, over an account
    /// that is in the rotation and will be back by itself within the hour, and
    /// dropping that one would take a live account's burn out of the numerator
    /// (`AccountSwitch` carries the measurement).
    ///
    /// It costs less than it looks like it should, because the window above
    /// already evicts most of what the switch names: the gateway stops polling a
    /// switched-off account altogether — measured 2026-09-09, acc3's own
    /// background poll and its header readings both stop at the same instant,
    /// 12.17 h before the probe — so its series freezes and ages out of the window
    /// `burnWindowHours - minimumMeasuredHours` = 2 h later. What the flag buys is
    /// those two hours, which are exactly the two hours after an operator takes an
    /// account out because something is wrong and is therefore watching. It is not
    /// left to the window on principle as well as on timing: "the gateway stops
    /// polling a disabled account" is somebody else's incidental behaviour, and a
    /// rule that holds only because of it is not a rule.
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
