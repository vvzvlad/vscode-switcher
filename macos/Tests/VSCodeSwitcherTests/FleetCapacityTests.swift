import XCTest
@testable import VSCodeSwitcher

/// The burn rule — how many percentage points an account spent over a span —
/// and the ways of getting it wrong.
///
/// The one that matters is the first test here: the utilisation series jitters
/// by ±1 pp, so anything that reads burn as "how much did this go up" reads a
/// quiet account as a busy one. Everything else holds the guards around it: what
/// counts as a reset, when the schedule may be consulted, when there is no
/// answer at all.
///
/// **These used to ask `FleetCapacity.load` and now ask `measure` directly**, and
/// the reason is that `load` is gone: the week's demand was estimated here and is
/// now measured by the gateway, so both estimators went with the setting that
/// chose between them. The rule they were laundering through a fleet aggregation
/// is `measure`'s, and the question is asked one step closer to where it is
/// answered.
///
/// **`measure` is back on the app's path**, and it is the whole of the numerator
/// now: `burnAgainstRefill` calls it once per account and `FleetCapacityBurnTests`
/// asks what it does with the answers. It spent one round with no production
/// reader at all, checked only against the hour-by-hour decomposition; both that
/// decomposition and its reconciliation test are gone with the allowance they fed.
///
/// **What a reset costs changed with them, and half these fixtures moved.** A
/// reset used to be charged a flat 100 pp on the reasoning that a window holds
/// 100 points; what it actually restores is the level the series fell *from*, and
/// on the live fleet the two are far apart — acc2's window turned over at 66 on
/// 2026-09-04, so the flat rule charged it 76 pp where the observed level charges
/// 42. Across the fleet that is 157.2% against 112.8% (2026-09-05 02:50Z; the
/// day holds several probes and they do not agree, so the time is part of the
/// citation). The flat
/// window survives in exactly one place, `testAResetHiddenInAHoleIsFoundThroughTheSchedule`:
/// there is no observed level when nobody saw the fall.
final class FleetCapacityTests: XCTestCase {

    // MARK: - Fixtures

    /// The instant every fixture series opens at, named here rather than inside
    /// `history` so a test can place a window boundary at a moment it knows the
    /// series covers.
    private let seriesStart = Date(timeIntervalSince1970: 1_786_700_000)

    /// One account's series as the gateway sends it: `readings` spread evenly
    /// over `overHours`, `nil` for a sample that said nothing about the window.
    ///
    /// Decoded rather than constructed, because `HistorySeries` has only the
    /// wire format's initialiser — and a hole is a thing only the wire format
    /// can say.
    private func history(_ label: String, _ readings: [Double?], overHours: Double) throws -> HistorySeries {
        let start = seriesStart.timeIntervalSince1970
        let step = readings.count > 1 ? overHours * 3600 / Double(readings.count - 1) : 0
        let points = readings.enumerated().map { index, value in
            "{\"ts\": \(start + Double(index) * step), \"util_7d\": \(value.map { "\($0)" } ?? "null")}"
        }
        let body = """
        {"label": "\(label)", "since": \(start), "points": [\(points.joined(separator: ","))]}
        """
        return try UsageFixtures.decode(body, as: HistorySeries.self)
    }

    /// The burn one series answers, with no window boundary offered.
    private func burnedPP(_ series: HistorySeries, resetsAt: Date? = nil) throws -> Double {
        try XCTUnwrap(FleetCapacity.measure(series.points, resetsAt: resetsAt)).burnPP
    }

    // MARK: - Burn is the endpoints, not the steps

    /// The trap this whole file exists for.
    ///
    /// A series that rises 0 → 50 over 48 h while jittering by ±1 pp on single
    /// samples. Read by its endpoints it burned 50 pp; summed as positive
    /// deltas every jitter tooth is charged as spend and the answer triples. The
    /// live case is acc2 over 46.79 h: 198 pp against a true 56, from 198
    /// spurious single-point steps (2026-08-18, full depth).
    func testBurnIsTheEndpointsAndNeverASumOfPositiveDeltas() throws {
        // One sample every five minutes over 48 h, as the gateway takes them.
        let samples = 577
        let values: [Double] = (0..<samples).map { index in
            let base = (50.0 * Double(index) / Double(samples - 1)).rounded(.down)
            guard index > 0, index < samples - 1, index % 5 == 2 else { return base }
            // A single sample a point away from both of its neighbours: the two
            // measuring sources disagreeing for one cycle.
            return index % 10 == 2 ? base + 1 : max(0, base - 1)
        }
        let naive = zip(values, values.dropFirst()).reduce(0.0) { $0 + max(0, $1.1 - $1.0) }
        XCTAssertGreaterThan(naive, 150,
                             "the fixture has to be able to fool a delta sum, or this test proves nothing")

        let series = try history("main", values.map { Optional($0) }, overHours: 48)
        XCTAssertEqual(try burnedPP(series), 50, accuracy: 0.001, """
            burn must come from the endpoints and the resets between them, never from a sum of \
            positive deltas: this series carries \(Int(naive) - 50) jitter teeth of ±1 pp, and \
            summing its rises answers \(Int(naive)) pp for an account that burned 50. \
            Live: acc2 read 198 pp over 46.79 h where the true figure was 56.
            """)
    }

    /// The window turned over mid-interval: 100 → 0 → 50. Endpoints alone say
    /// the account gave 50 pp back.
    ///
    /// This is the one shape where the flat window and the observed level are
    /// the same number — the account was at 100 when it fell — which is why it
    /// cannot hold the rule and `testAResetIsChargedTheLevelItFellFrom` below
    /// exists. What it catches is the reset credit going missing altogether; what
    /// it cannot catch is the endpoint rule being replaced by a sum of positive
    /// deltas — over this fixture that sum is 25 + 25, the same 50 — and the test
    /// above is the only one that can.
    func testAResetInsideTheIntervalRestoresTheWholeWindowWhenItFellFromTheCeiling() throws {
        let series = try history("main", [100, 100, 0, 25, 50], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 50, accuracy: 0.001,
                       "the endpoints alone read −50 pp, which is an account that un-burned its quota")
    }

    /// **A reset restores the level the series fell from, not a whole window**,
    /// and the difference is the live fleet's whole answer.
    ///
    /// The shape is acc2's on 2026-09-04, and it is the whole shape rather than
    /// its tail: the account was at **44** when the 48 h window opened, climbed to
    /// 66, turned over there at 20:05:38Z, and the new window stood at **20** when
    /// the histories were read. So its burn is `(66 − 44) + 20 = 42` pp — what it
    /// spent finishing the old window plus what it has spent of the new one —
    /// which is the arithmetic §2.7 records. The flat rule charges 76 — a whole
    /// window against an account that had a third of one left to give — and over
    /// the three-account fleet the two forms answer 157.2% and 112.8% (measured
    /// 2026-09-05 02:50Z; main's reset the same evening fell from 96, so it was
    /// over-charged by 4, and acc3, whose series ended before its own turnover
    /// that day, holds no fall in that window and reads 9 pp either way).
    ///
    /// **The fixture used to be `[66, 66, 0, 20, 42]` and could not hold the rule
    /// it is named for.** There `first` and `firstFallLevel` were the same 66, so
    /// `last − first + level` collapsed to `last` and the expected 42 was simply
    /// the last reading: "the burn is the last reading" passed it. Here the three
    /// are 44, 66 and 20, no two alike, and 42 is not a reading of the series at
    /// all. Its docstring was wrong about the live shape in the same way — it
    /// called 42 the last reading and derived `66 − 66 + 42` — which is how a
    /// degenerate fixture goes unnoticed.
    ///
    /// A window's quota is not 100 points of *spending* — it is 100 points of
    /// utilisation, and an account that never reached the top of the old window
    /// never had those points to spend.
    func testAResetIsChargedTheLevelItFellFrom() throws {
        let series = try history("acc2", [44, 55, 66, 0, 10, 20], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 42, accuracy: 0.001, """
            20 − 44 over the interval plus the 66 the window was standing at when it turned over; \
            a flat 100 answers 76 pp, which is the live over-charge that took the fleet from \
            112.8% to 157.2%, and the last reading alone answers 20
            """)
    }

    /// Two falls over the threshold inside one 48 h span, and they collapse to a
    /// single reset: a seven-day window cannot turn over twice in two days, so
    /// the second fall is a lagging sample and charging it costs +100 pp that
    /// never happened.
    ///
    /// The clamp used to ask `hours <= hoursPerWeek` first, for a span long
    /// enough to hold two real resets. This test stands where that question used
    /// to be asked, because the gateway cannot produce such a span — but **not
    /// for the reason written here until 2026-09-05**, which was the retention
    /// ceiling this branch spent three rounds removing: "`since` of 2, 7 and 30
    /// days all come back with the same points, and the deepest account reaches
    /// 64.89 h — a week is four times that", undated and in the present tense.
    /// It predates the branch and outlived the correction made in
    /// `FleetCapacity.swift`, which it then contradicted.
    ///
    /// Measured 2026-09-05 20:29Z, `since` at 48 / 72 / 168 h: acc2 and main
    /// answer the same at all three, 2000 points over 46.84 and 43.74 h, both
    /// `truncated` — they are held by `max_points`, not by retention. acc3 is
    /// the counter-example to "the same points": 477 points over 44.48 h, then
    /// 1285 over 68.47 h, then 2000 over 84.92 h, only the last `truncated`. So
    /// the deepest is **84.92 h and a week is less than twice that**, not four
    /// times — and "four times" did not follow from 64.89 h either: that is
    /// 2.6×. What still holds is the conclusion: no reachable span holds two
    /// real resets. The reasoning about weeks belongs in a comment now, not in a
    /// 15-day fixture built out of readings 90 hours apart by a source that
    /// samples once a minute.
    func testTwoFallsInsideOneSpanCollapseToASingleReset() throws {
        let series = try history("main", [10, 90, 5, 95, 30], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 110, accuracy: 0.001, """
            30 − 10 over the interval plus the 90 the first window was standing at when it turned \
            over; counting both falls answers 200 pp for an account that could not have spent two \
            windows in two days
            """)
    }

    /// **The clamp on live data**, and the shape that makes it load-bearing
    /// rather than a precaution.
    ///
    /// The gateway measures each account two ways — its own poll and the value in
    /// a response header — and across a reset the two disagree for about a
    /// minute, so the series flip-flops. Both acc2 and main did it on 2026-09-04,
    /// each from a level of its own: acc2 fell `66 → 0` three times, at 20:05:38,
    /// 20:05:54 and 20:06:04, and main `96 → 0` three times, at 20:05:18,
    /// 20:05:46 and 20:06:25 (measured 2026-09-05 17:15Z). Charged the level each
    /// time, that is 198 pp of credit on an account whose window held 66, and
    /// 288 pp on one whose window held 96. This fixture is acc2's.
    ///
    /// **acc3 is not a third data point about this reset**: it has no reading
    /// across the event at all, its series being silent for 24.14 h from
    /// 09-04 12:53:44Z to 09-05 13:01:51Z (measured 2026-09-05 20:26Z). "acc3
    /// did not flip-flop that day" stood here until 2026-09-05 and could not
    /// have come out false for want of a witness, so "two of three accounts on
    /// the same reset" is withdrawn — acc3's own fall is a different event some
    /// 17 h later, at the far end of that hole. The polling-frequency
    /// explanation goes with it, unestablished rather than disproved: a 24 h
    /// hole hides any event, and outside the hole acc3's median gap is 63 s
    /// against 60 s on acc2 and 61 s on main, which leaves a minute-wide
    /// disagreement nowhere to fall through. The 13.2 readings an hour quoted
    /// here was an average over a window this hole dilutes.
    ///
    /// The two resets on record in 2026-08 were clean by contrast — one fall each
    /// — which is why the clamp spent its first round with nothing able to fail
    /// without it. Charging the level rather than a flat window is what gave it
    /// teeth: while every reset cost 100, the second and third falls at least
    /// charged the same amount as the first.
    func testAFlipFloppingResetIsStillOneReset() throws {
        let series = try history("acc2", [66, 0, 66, 0, 66, 0, 42], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 42, accuracy: 0.001, """
            one window turned over, at 66: charging each of the three falls credits 198 pp and \
            answers 174 for an account that burned 42
            """)
    }

    /// **What a window edge landing inside a flip-flop costs, both ways round.**
    /// This test pins a known over-charge rather than a rule, and a fix to
    /// `measure` is expected to change it deliberately.
    ///
    /// The clamp above keeps one reset out of three falls, but it cannot say
    /// *which side of the flip-flop the interval's ends fell on*, and both ends
    /// have a bad side. The one the header of `measure` already named is the
    /// trailing end: a last reading on the pre-reset value, `[44, 66, 0, 66]`,
    /// leaves `last − first + level` counting the window twice — 88 pp where the
    /// account spent 22. The mirror was named nowhere: a **first** reading on the
    /// post-reset zero, `[0, 66, 0, 10, 42]`, credits a reset the interval opened
    /// after — 108 pp where the account spent 42. `min(falls, 1)` reaches neither:
    /// it collapses the falls, and what is wrong here is which side of the one
    /// charged fall `first` and `last` sit on.
    ///
    /// The third fixture is the control, and it is the one the neighbours already
    /// use: `[66, 0, 66, 0, 66, 0, 42]` opens on the pre-reset value and closes on
    /// the new window, which is the alignment the rule is written for, and answers
    /// 42. So the difference between 42 and 108 is nothing about the account at
    /// all — it is where the window's left edge cut a flip-flop 23 s wide on acc2,
    /// 65 s on main.
    ///
    /// **How reachable it is, in numbers rather than in "a one-minute shape" —
    /// and it is a range rather than one figure:** the width runs from the first
    /// post-reset reading to the last pre-reset one, the stretch in which an edge
    /// lands on the wrong side of the charged fall, and over the reset of
    /// 2026-09-04 that is 20:05:38 → 20:06:01 on acc2, about 23 s, against
    /// 20:05:18 → 20:06:23 on main, about 65 s (measured 2026-09-05 17:15Z). The
    /// edges sweep continuously, and the histories are re-asked every
    /// `UsageStore.historyIntervalSeconds` = 600 s. So **one** edge lands inside
    /// a given flip-flop with probability about 23/600 to 65/600 — **4 to 11%**,
    /// per reset per account, once a week each — and since the interval has
    /// **two** edges and each sweeps the flip-flop once per reset, "either edge
    /// caught it" is twice that, 46/600 to 130/600, **8 to 22%**. Both at once
    /// cannot happen: a minute against 48 h. Only the narrow end of the width
    /// stood here before, and counting one edge of two understated it again the
    /// same way; this estimate is the whole argument for *tolerating* the
    /// over-charge rather than fixing it, so quoting the cheap half — of the
    /// width or of the edge count —
    /// biases that decision toward "tolerable". Not fixed here because refusing
    /// such windows is a design change and not a defect fix: the interval
    /// genuinely holds a fall, and choosing not to answer over it would cost a
    /// figure on the day a reset is most interesting.
    func testAWindowEdgeInsideAFlipFlopChargesTheWrongWindow() throws {
        let openedOnTheZero = try history("acc2", [0, 66, 0, 10, 42], overHours: 48)
        XCTAssertEqual(try burnedPP(openedOnTheZero), 108, accuracy: 0.001, """
            the interval opened after the reset, so its account spent the 42 it climbed to; the \
            observed fall credits it 66 more, and this is the known over-charge — if a fix has \
            made this 42, this expectation is what to update
            """)

        let closedOnTheOldValue = try history("acc2", [44, 66, 0, 66], overHours: 48)
        XCTAssertEqual(try burnedPP(closedOnTheOldValue), 88, accuracy: 0.001, """
            the interval closed on the lagging source's pre-reset reading, so the endpoints \
            already carry the whole old window and the credit adds it again: 22 pp of spending \
            charged 88, and this is the known over-charge — if a fix has made this 22, this \
            expectation is what to update
            """)

        let clean = try history("acc2", [66, 0, 66, 0, 66, 0, 42], overHours: 48)
        XCTAssertEqual(try burnedPP(clean), 42, accuracy: 0.001,
                       "the same flip-flop cut on the outside of both edges is the rule's own case")
    }

    /// **What a fall after a hole costs, and it is the level rule's own blind
    /// spot — mirror of the flat rule's.** This test pins a known *under*-charge
    /// rather than a rule, and a fix to `measure` is expected to change it
    /// deliberately.
    ///
    /// Charging the level the series fell from takes the last pre-fall reading
    /// for a *current* one. Across a hole it is stale: the window went on
    /// climbing while nobody was looking, and the level charged is where it stood
    /// before the silence rather than where it stood when it turned over. The
    /// shape is acc3's on 2026-09-05 — 50, then 24.14 h without a reading
    /// (09-04 12:53:44Z → 09-05 13:01:51Z), then 0 — and the charge is 50.
    ///
    /// The undercharge is bounded by the headroom at that reading, up to 50 pp
    /// here, exactly as the flat rule's over-charge is bounded by the headroom at
    /// the ceiling. **The direction is what makes it worth more than a footnote:
    /// the flat rule errs loud and this one errs quiet**, and quiet is toward
    /// calm. On the live fleet (2026-09-05 20:29Z, over the 48 h the app asks
    /// for, acc2 and main unchanged) acc3 charged its level of 50 puts the figure
    /// at 199.1%; charged a flat 100 it reads 262.0% — 62.9 points of ratio, with
    /// the truth somewhere between.
    ///
    /// **The control is the same arithmetic with the level fresh**, and it is why
    /// no `≥` is raised for this: `measure` cannot tell the two series apart, so
    /// a flag would need a rule for "the pre-fall reading is stale" — a threshold
    /// on its age — and the only hole of this size on record is the one above.
    /// §2.7 keeps that as a negative result rather than a constant nothing
    /// calibrates.
    func testAFallAfterAHoleIsChargedAStaleLevel() throws {
        let acrossAHole = try history("acc3", [44, 50, nil, nil, nil, 0, 2], overHours: 48)
        XCTAssertEqual(try burnedPP(acrossAHole), 8, accuracy: 0.001, """
            2 − 44 over the interval plus the 50 the series was last seen at before 32 h of \
            silence; the window may have climbed anywhere up to 100 inside that hole, so the \
            truth is 8 to 58 pp and this answers the bottom of it. This is the known \
            under-charge — if a fix has made this larger, this expectation is what to update
            """)

        let levelStillFresh = try history("acc3", [44, 50, 50, 50, 50, 0, 2], overHours: 48)
        XCTAssertEqual(try burnedPP(levelStillFresh), 8, accuracy: 0.001, """
            the same 8 pp, and here it is right: the series watched the window sit at 50 up to \
            the fall. The two fixtures are indistinguishable to `measure`, which is the whole \
            reason the hole raises no flag — telling them apart needs a staleness threshold, and \
            one hole on record calibrates nothing
            """)
    }

    /// A single lagging sample beside a real reset: the series falls twice —
    /// 95 → 0 and 95 → 3 — but 48 h cannot hold two seven-day windows, so the
    /// second fall is the sample that lagged, not a window that turned over.
    /// Counted as one it is charged +100 pp that never happened.
    func testALaggingSampleBesideAResetIsNotASecondReset() throws {
        let series = try history("main", [95, 0, 95, 3, 10], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 10, accuracy: 0.001, """
            10 − 95 over the interval plus the 95 the window was standing at when it turned over; \
            counting the lagging sample as a second reset answers 105 pp for an account that \
            burned about 10
            """)
    }

    /// The reset threshold held from above. Not every reset falls a whole
    /// window: both resets on record are 99 → 0 and 100 → 0, but an account
    /// whose window turns over at 45 falls 40 pp, and 5 sits low enough to read
    /// that as the reset it is. Raise the constant past this fall and it goes
    /// uncounted: the interval then reads −25 pp, no schedule is offered to
    /// place what happened, and the account is refused altogether. From below the
    /// constant was already held: lower it to 1.5 and the 2 and 3 pp falls the
    /// hole fixtures are built on are charged as whole restored windows, which
    /// reddens three of them (checked by mutation, 2026-08-17). From above
    /// nothing held it at all.
    func testAFallDeeperThanTheSawtoothIsAResetEvenWithoutAWholeWindowBehindIt() throws {
        let series = try history("main", [45, 5, 10, 15, 20], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 20, accuracy: 0.001, """
            20 − 45 over the interval plus the 45 that window was standing at when it turned over; \
            a threshold too high to see this fall does not answer 25 pp or 0, it refuses the \
            account outright
            """)
    }

    /// The threshold is the largest fall that is still the signal moving, not
    /// the smallest fall that is a reset: `>` and not `>=`. So a fall of exactly
    /// `resetDropThreshold` is the signal, and this account burned the 5 pp its
    /// endpoints say. Asked with `>=` the same series is charged the 50 it fell
    /// from — 55 pp for an account that spent 5 — and every other fixture here
    /// falls either well inside the threshold or well past it.
    func testAFallOfExactlyTheThresholdIsNotAReset() throws {
        let series = try history("main", [50, 50 - FleetCapacity.resetDropThreshold, 55], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 5, accuracy: 0.001,
                       "55 − 50 with nothing but the signal in between; counting that fall as a reset answers 55 pp")
    }

    /// The mirror of the phantom: a reset that fell entirely inside a hole is
    /// not a fall between two readings, but the readings still carry its
    /// signature — 95 → 92 across the hole is a window that ended lower than it
    /// began, which nothing but a reset does. The schedule is what places it:
    /// this window ends a week after a moment inside the interval, so it began
    /// inside the interval, and the account did not un-burn 3 pp — it spent 97.
    ///
    /// **This is the one place a reset is still charged a flat 100 pp**, and the
    /// reason is in the fixture: nobody observed the fall, so there is no level
    /// to charge and a whole window is all that is left. It errs upward over an
    /// account that had less than a window to give — the same direction the flat
    /// rule erred in everywhere before it was replaced — and that is the price of
    /// a figure at all here.
    func testAResetHiddenInAHoleIsFoundThroughTheSchedule() throws {
        let series = try history("main", [95, nil, nil, nil, 92], overHours: 48)
        let boundaryInside = seriesStart.addingTimeInterval((24 + 168) * 3600)
        XCTAssertEqual(try burnedPP(series, resetsAt: boundaryInside), 97, accuracy: 0.001,
                       "the endpoints alone read −3 pp, which the clamp would serve as a confident 0%")

        // The control half, and it is the *same series* with only the schedule
        // moved: one variable, so a failure here means the boundary test and
        // nothing else. A window that began five minutes before the first
        // reading, or five minutes after the last, did not begin inside this
        // interval — and then the readings and the schedule contradict each
        // other, because the series fell 3 pp all the same. There is no figure
        // in that (§2.7), and no tolerance either: the gateway's own lag (42 s
        // on main, 285 s on acc2) can only move an observed fall later, into the
        // interval, never out of it.
        let outside: [(String, TimeInterval)] = [
            ("five minutes before the first reading", 168 * 3600 - 300),
            ("five minutes after the last reading", (48 + 168) * 3600 + 300),
        ]
        for (side, boundary) in outside {
            XCTAssertNil(FleetCapacity.measure(series.points,
                                               resetsAt: seriesStart.addingTimeInterval(boundary)),
                         "a window that began \(side) cannot be the reset this interval hides")
        }
    }

    /// The phantom the schedule guard used to invent, in the shape that produces
    /// it live: the caller asks for `now − 48 h`, that edge slides past a reset
    /// instant, and the first reading of the series is then already the
    /// post-reset value. Nothing reset inside the interval — it starts at zero
    /// and rises — and the schedule must not be consulted about it at all.
    ///
    /// Replayed from acc2 on 2026-08-17 (boundary 2026-08-15 21:00:00Z, first
    /// post-reset reading 285 s later, 52 by the end): asking the schedule
    /// without asking the readings answered 152 pp instead of 52. It is not a
    /// rare alignment either — every account passes through it for the quarter of
    /// an hour a week its boundary spends inside the old tolerance.
    ///
    /// **The name and the fixture both changed on 2026-09-05, and the old ones
    /// were a pair of claims nothing could break.** It was called
    /// `testAScheduleBoundaryBeforeARisingSeriesIsNotAHiddenReset` and placed the
    /// boundary five minutes before the first reading — but the branch that reads
    /// `resetsAt` sits behind `if resets == 0, rawChange < -1`, and a series that
    /// rises 52 points short-circuits on the second half before the schedule is
    /// ever looked at. The boundary could go anywhere and the test stayed green,
    /// so it held nothing about boundaries; what it actually holds is the
    /// short-circuit. Placing the boundary **inside** the interval is what makes
    /// that bite: it is the one alignment where the short-circuit is the only
    /// thing refusing the phantom, so dropping `rawChange < -1` answers exactly
    /// the historical 152 pp rather than a `nil`. The boundary check itself
    /// (`windowStart > first.at`) is held by the control halves of
    /// `testAResetHiddenInAHoleIsFoundThroughTheSchedule`, which is where it
    /// belongs.
    func testTheScheduleIsNotConsultedOverASeriesThatDidNotFall() throws {
        let afterTheReset = try history("acc2", [0, 12, 25, 40, 52], overHours: 48)
        let boundaryInside = seriesStart.addingTimeInterval((24 + 168) * 3600)
        XCTAssertEqual(try burnedPP(afterTheReset, resetsAt: boundaryInside), 52, accuracy: 0.001, """
            the series starts at zero and climbs: the window turned over before the interval opened, \
            not inside it, and a schedule asked without asking the readings charges the window a \
            second time — 152 pp for an account that spent 52
            """)
    }

    /// The same hidden reset with no schedule to place it. The fall is 3 pp,
    /// three times the sawtooth, so it is not jitter and `max(0, …)` would turn
    /// it into a confident 0 pp for an account that spent most of a window. There
    /// is no figure here (§2.7).
    ///
    /// The control for the other side of the boundary is the neighbouring
    /// `testAnIdleAccountJitteringDownDoesNotSubtractDemand`: a fall of exactly
    /// 1 pp is the sawtooth, and it is still answered rather than refused. The
    /// same refusal with a schedule that places the boundary outside is the
    /// control half of `testAResetHiddenInAHoleIsFoundThroughTheSchedule` — a
    /// known `resetsAt` buys no confidence here, it is evidence against the fall
    /// rather than the absence of evidence.
    func testAFallPastTheSawtoothWithNoScheduleHasNoAnswer() throws {
        let series = try history("main", [95, nil, nil, nil, 92], overHours: 48)
        XCTAssertNil(FleetCapacity.measure(series.points, resetsAt: nil),
                     "a reset nobody saw and nothing can place is a missing figure, not zero burn")
    }

    /// The refusal's boundary, and the reason it stands at −1 rather than −2.
    /// The two measuring sources disagree by one point and only downward — a
    /// reading is the truth or the truth minus one, never above it (measured
    /// 2026-08-17, see `FleetCapacity.measure`) — and the truth inside a window
    /// cannot fall, so an interval with no reset in it can read −1 and nothing
    /// lower. This one falls exactly 2 pp across a hole, one point past anything
    /// the sawtooth can make, with no schedule to place the reset that did it.
    ///
    /// It sits between the two fixtures that already exist and neither of them
    /// can ask this question: `testAnIdleAccountJitteringDownDoesNotSubtractDemand`
    /// falls 1 pp and is answered, `testAFallPastTheSawtoothWithNoScheduleHasNoAnswer`
    /// falls 3 pp and is refused, and with that gap the threshold can be written
    /// `< -2` while both stay green.
    func testAFallOfExactlyTwoPointsIsAlreadyPastTheSawtooth() throws {
        let series = try history("main", [95, nil, nil, nil, 93], overHours: 48)
        XCTAssertNil(FleetCapacity.measure(series.points, resetsAt: nil), """
            a one-sided ±1 tooth cannot take an interval two points below where it opened: something \
            restored this window, nothing here can place it, and a missing figure beats a confident 0
            """)
    }

    /// A `null` sample measured nothing; it is not a reading of zero. Read as
    /// zero it would look like a fall of 50 pp — a reset — and the account's
    /// burn would come out at 110 instead of 10.
    ///
    /// What it catches is `nil` being read as a value; what it cannot catch is
    /// the endpoint rule going away, because a sum of positive deltas over the
    /// two readings answers the same 10.
    func testAHoleIsSteppedOverRatherThanReadAsZero() throws {
        let series = try history("main", [50, nil, 60], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 10, accuracy: 0.001,
                       "a hole read as zero fakes a reset and adds a whole window to the burn")
    }

    /// An idle account whose reading wobbles down by a point has not un-burned
    /// anything. Left signed, its negative burn would make the rest of the fleet
    /// look cheaper than it is — every reader of this figure sums across accounts.
    func testAnIdleAccountJitteringDownDoesNotSubtractDemand() throws {
        let series = try history("main", [50, 49, 50, 49], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 0, accuracy: 0.001, "an account at rest burned 0, not −1")
    }

    // MARK: - The span, and when there is none

    /// The span runs between the first and last *readings*, not between the
    /// first and last points. A series whose tail is holes was measured up to
    /// its last reading and no further: stretched over the points it would be
    /// 48 h instead of 12, and every rate taken from it a quarter of what it is.
    func testTheSpanIsMeasuredBetweenReadingsRatherThanPoints() throws {
        let series = try history("main", [50, 60, nil, nil, nil], overHours: 48)
        let measured = try XCTUnwrap(FleetCapacity.measure(series.points, resetsAt: nil))
        XCTAssertEqual(measured.hours, 12, accuracy: 0.001,
                       "the last three samples said nothing, and hours nobody measured are not measured hours")
        XCTAssertEqual(measured.burnPP, 10, accuracy: 0.001)
    }

    /// Every sample said nothing about the seven-day window. That is no
    /// readings, which is not a reading of zero — and zero burn over an
    /// uncountable span is not 0 pp, it is no answer.
    func testASeriesOfNothingButHolesHasNoAnswer() throws {
        let series = try history("main", [nil, nil, nil], overHours: 48)
        XCTAssertNil(FleetCapacity.measure(series.points, resetsAt: nil))
    }

    /// A span shorter than the floor is refused, and the control half matters as
    /// much as the refusal — the same fixture stretched to the minimum has to
    /// come back with an answer, or this would pass on a function that refuses
    /// everything.
    ///
    /// **The floor is on the app's path again**, and it is the only one left: the
    /// whole-day floor belonged to the decomposition, which went with the
    /// allowance. Six hours is what the fleet figure now refuses under, and the
    /// window table over `UsageStore.historyWindowSeconds` records what that
    /// refusal looks like from the outside — asked over 6 h the live fleet has no
    /// answer at all, because the series comes back 5.99 h long.
    func testASpanShorterThanTheMinimumIsRefused() throws {
        let brief = try history("main", [0, 50], overHours: 4)
        XCTAssertNil(FleetCapacity.measure(brief.points, resetsAt: nil),
                     "four hours is under the floor and answers nothing rather than a noisy figure")

        let long = try history("main", [0, 50], overHours: FleetCapacity.minimumMeasuredHours)
        XCTAssertNotNil(FleetCapacity.measure(long.points, resetsAt: nil),
                        "the minimum is a floor to stand on, not a floor to fall through")
    }

    /// An account that spent the *whole* interval at 100 served nothing it was
    /// asked for: its series is flat, its burn reads as zero, and counting it
    /// would hand a fleet a whole window of capacity against no spending — from
    /// the one account that certainly had none to spare. Unknown is not zero
    /// (§2.7), and blocked spending is unknown spending.
    ///
    /// What it costs a fleet is the figure's own test
    /// (`FleetCapacityBurnTests.testAnAccountPinnedAtItsCeilingThroughoutIsNotCounted`);
    /// what is held here is that the refusal is in the burn rule itself.
    func testAnAccountPinnedAtItsCeilingIsNotMeasuredAtAll() throws {
        let exhausted = try history("acc2", [100, 100, 100, 100, 100], overHours: 48)
        XCTAssertNil(FleetCapacity.measure(exhausted.points, resetsAt: nil),
                     "a fleet of one exhausted account is not a fleet at rest, it is one nobody measured")
    }

    /// The other seed of the same flag, and only a series that goes below its
    /// ceiling on the *second* reading can tell the seed from the loop:
    /// `everBelowCeiling` starts from the first reading and is raised again
    /// inside a loop that begins at `dropFirst()`. Written `false`, the seed says
    /// this account was never below its ceiling and `measure` refuses it whole.
    func testAnAccountBelowItsCeilingOnlyOnTheFirstReadingIsStillMeasured() throws {
        let series = try history("acc2", [99, 100, 100, 100, 100], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 1, accuracy: 0.001, """
            the account was below its ceiling when the interval opened and blocked for the rest of \
            it: that is an account measured over a window it spent at the ceiling, not one nobody \
            measured at all
            """)
    }

    /// **The flag the fleet figure's `≥` is made of**, and it is raised from two
    /// places that only a series touching its ceiling on the *first* reading can
    /// tell apart: the seed is `first.value >= ceilingPercent` and the loop
    /// starts at `dropFirst()`. Seeded `false`, an account blocked only while the
    /// interval opened would answer a figure with nothing saying it is a floor.
    ///
    /// The control half is the same shape with the ceiling taken out, because a
    /// flag that is always raised marks nothing.
    func testTouchingTheCeilingAtAllMarksTheMeasurementAsAFloor() throws {
        let opened = try XCTUnwrap(FleetCapacity.measure(
            try history("acc2", [100, 60, 70, 80], overHours: 48).points, resetsAt: nil))
        XCTAssertTrue(opened.hitCeiling,
                      "the account was blocked when the interval opened, and the seed is the only witness")

        let closed = try XCTUnwrap(FleetCapacity.measure(
            try history("acc2", [50, 70, 100, 100], overHours: 48).points, resetsAt: nil))
        XCTAssertTrue(closed.hitCeiling, "and blocked at the end is the loop's half of the same flag")

        let free = try XCTUnwrap(FleetCapacity.measure(
            try history("acc2", [50, 70, 90, 99], overHours: 48).points, resetsAt: nil))
        XCTAssertFalse(free.hitCeiling,
                       "an account that never reached its ceiling burned everything it wanted to")
    }
}

/// The fleet figure: percentage points of quota burned over the window against
/// the percentage points the week refills over the same window.
///
/// One division over two sums, and every way of getting the sums wrong has a
/// fixture here: pooling the accounts instead of averaging their rates, letting
/// an account nobody measured widen the refill it contributes nothing to, and
/// publishing an answer for a fleet with no contributor at all.
///
/// **These replaced the allowance's tests**, and what went with the allowance
/// went for good: the price of a point in tokens, the split of the day into work
/// and sleep, and the week the nights ate before a working hour was allowed
/// anything. Both sides of the figure are percentage points of a week now, so
/// there is no conversion left to test. The burn rule underneath is unchanged
/// and lives in `FleetCapacityTests` above.
final class FleetCapacityBurnTests: XCTestCase {

    // MARK: - Fixtures

    /// 2026-08-14 00:00:00 UTC. An arbitrary instant, but a fixed one: a reset
    /// schedule is placed relative to it in one test, and a fixture that moved
    /// with the clock would place it somewhere else on every run.
    private let start = Date(timeIntervalSince1970: 1_786_665_600)

    /// One account's series: `readings` spread evenly over `overHours`, decoded
    /// through the wire format because that is the only initialiser
    /// `HistorySeries` has.
    private func history(_ label: String, _ readings: [Double?],
                         overHours: Double) throws -> HistorySeries {
        let step = readings.count > 1 ? overHours * 3600 / Double(readings.count - 1) : 0
        let points = readings.enumerated().map { index, value in
            "{\"ts\": \(start.timeIntervalSince1970 + Double(index) * step), " +
            "\"util_7d\": \(value.map { "\($0)" } ?? "null")}"
        }
        return try UsageFixtures.decode("""
        {"label": "\(label)", "since": \(start.timeIntervalSince1970), \
        "points": [\(points.joined(separator: ","))]}
        """, as: HistorySeries.self)
    }

    /// The fleet as `/gw/usage` names it: labels and nothing else, which is all
    /// the figure needs from an account that is not carrying a schedule.
    private func fleet(_ labels: [String]) throws -> [AccountUsage] {
        let body = labels.map { "\"\($0)\": {}" }.joined(separator: ",")
        return try UsageFixtures.decode("{\"accounts\": {\(body)}}", as: UsageReport.self).accounts
    }

    private func histories(_ all: [HistorySeries]) -> [String: HistorySeries] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.label, $0) })
    }

    /// What one account refills an hour: a whole quota over a week, and the
    /// figure both sides of every expectation below are built from. Written out
    /// rather than read off `FleetCapacity` so that moving the constant fails
    /// these tests instead of moving them with it.
    private let refillPerAccount = 100.0 / 168

    // MARK: - The figure

    /// The whole division in one fixture, every number redoable on paper.
    ///
    /// 50 pp over 48 h is 1.0417 pp/h; one account refills 100 pp over 168 h,
    /// which is 0.5952 pp/h; the quotient is exactly 1.75. A fleet burning its
    /// week's worth in four days.
    func testTheFigureIsTheBurnRateOverTheWeeksRefillRate() throws {
        let answer = try XCTUnwrap(FleetCapacity.burnAgainstRefill(
            histories: histories([try history("main", [0, 25, 50], overHours: 48)]),
            accounts: try fleet(["main"])))

        XCTAssertEqual(answer.burnRate, 50.0 / 48, accuracy: 0.0001, "50 pp over 48 measured hours")
        XCTAssertEqual(answer.refillRate, refillPerAccount, accuracy: 0.0001,
                       "one account is one quota a week and no more")
        XCTAssertEqual(answer.percent, 175, accuracy: 0.01,
                       "1.0417 pp/h burned against 0.5952 refilled")
        XCTAssertEqual(answer.accounts, 1)
        XCTAssertEqual(answer.measuredHours, 48, accuracy: 0.001)
        XCTAssertFalse(answer.isLowerBound, "nothing was blocked, so nothing is being under-reported")
    }

    /// **A rate per account, then summed — never one total over one span.**
    ///
    /// The accounts are watched over different depths (48.0 / 34.0 / 48.0 h over
    /// main / acc3 / acc2, measured 2026-09-05 **02:50Z**), so pooling the burns
    /// over the pooled refill credits the shallow account's unwatched hours to
    /// the others. On the live fleet that morning the two forms answered 112.8%
    /// and 120.2%, and the whole of the difference was acc3, whose series stopped
    /// 14 h before the other two. That staleness was a state of that morning and
    /// not a property of acc3 — at 15:35Z the same three read
    /// 43.09 / 47.88 / 47.91 h — but the spread outlived it, so the form does
    /// too (`FleetBurn.measuredHours`).
    ///
    /// The fixture is that shape with the arithmetic made checkable: 96 pp over
    /// 48 h is 2.0 pp/h and 12 pp over 24 h is 0.5, so the mean of the rates is
    /// 2.5 against a refill of 1.1905 — 210%. Pooled it is 108 pp over the
    /// 42.857 pp those two spans refill between them, which is 252%.
    func testTheRatesAreSummedPerAccountRatherThanPooledOverOneSpan() throws {
        let deep = try history("main", [0, 48, 96], overHours: 48)
        let shallow = try history("acc3", [0, 6, 12], overHours: 24)
        let answer = try XCTUnwrap(FleetCapacity.burnAgainstRefill(
            histories: histories([deep, shallow]), accounts: try fleet(["main", "acc3"])))

        XCTAssertEqual(answer.burnRate, 2.5, accuracy: 0.0001,
                       "2.0 pp/h and 0.5 pp/h, each measured over its own span")
        XCTAssertEqual(answer.percent, 210, accuracy: 0.01, """
            one total over the pooled refill answers 252% here: the shallow account is credited \
            with 24 hours nobody watched it over, and on the live fleet that is 7.4 points of \
            difference in the direction of alarm
            """)
    }

    /// The refill counts the accounts that could be measured and nobody else.
    ///
    /// An account the gateway names but nothing could be measured for
    /// contributes no burn, so counting it in the refill would widen a
    /// denominator its own numerator is missing from — a fleet reading calmer
    /// for having an account nobody can see. Here that is the difference between
    /// 175% and 87.5%.
    func testTheRefillCountsTheContributorsAndNobodyElse() throws {
        let answer = try XCTUnwrap(FleetCapacity.burnAgainstRefill(
            histories: histories([try history("main", [0, 25, 50], overHours: 48)]),
            accounts: try fleet(["main", "acc3"])))

        XCTAssertEqual(answer.accounts, 1, "acc3 sent no history: nobody measured it")
        XCTAssertEqual(answer.refillRate, refillPerAccount, accuracy: 0.0001,
                       "one contributor refills one quota a week")
        XCTAssertEqual(answer.percent, 175, accuracy: 0.01, """
            counting the silent account in the refill answers 87.5% for the same burn, which is a \
            fleet made to look calm by an account nobody could see
            """)
    }

    /// Membership comes from the account list and not from whatever histories
    /// are lying around: a series under a label the fleet does not have is not a
    /// contributor.
    func testAHistoryUnderALabelTheFleetDoesNotHaveIsNotCounted() throws {
        XCTAssertNil(FleetCapacity.burnAgainstRefill(
            histories: histories([try history("retired", [0, 25, 50], overHours: 48)]),
            accounts: try fleet(["main"])),
            "a retired account's series was counted as a live account's burn")
    }

    /// The shortest span, not the longest and not the mean: the answer is only
    /// as well measured as its worst-measured contributor, and what the surfaces
    /// print beside the figure is how much watching stands behind it.
    func testTheMeasuredSpanIsTheShortestContributorsAndNotTheLongest() throws {
        let answer = try XCTUnwrap(FleetCapacity.burnAgainstRefill(
            histories: histories([try history("main", [0, 25, 50], overHours: 48),
                                  try history("acc3", [0, 6, 12], overHours: 24)]),
            accounts: try fleet(["main", "acc3"])))
        XCTAssertEqual(answer.measuredHours, 24, accuracy: 0.001,
                       "the deeper account's 48 h says nothing about the hours the shallow one missed")
    }

    // MARK: - When there is no figure, and when it is only a floor

    /// **A fleet with no contributor has no figure, and that is a guard and not
    /// a formality.** The refill is the contributors times a constant, so with
    /// none of them the division is `0 / 0` — a `NaN` published as a reading,
    /// which every surface would draw: the popover would print `nan%`, the menu
    /// bar would ask the ramp about it and the bar's fill would be a length
    /// nobody can compute.
    ///
    /// Both ways in are asked, because they are different facts about a pass and
    /// the guard has to catch either: a gateway that named no accounts at all,
    /// and a gateway that named accounts whose every history is too short to
    /// measure.
    func testAFleetWithNoContributorHasNoFigure() throws {
        XCTAssertNil(FleetCapacity.burnAgainstRefill(histories: [:], accounts: []),
                     "no accounts is nothing to divide, not nought per cent")

        let brief = try history("main", [0, 50], overHours: 4)
        XCTAssertNil(FleetCapacity.measure(brief.points, resetsAt: nil),
                     "the fixture has to be unmeasurable, or it proves nothing")
        XCTAssertNil(FleetCapacity.burnAgainstRefill(histories: histories([brief]),
                                                     accounts: try fleet(["main"])),
                     "an account too shallow to measure is not a contributor either")
    }

    /// An account pinned at its ceiling for the whole window is not an account
    /// that spent nothing, it is one whose spending was refused and never
    /// measured — so it takes its refill out with it (§2.7).
    ///
    /// What that saves is the direction of the error. Two accounts burning 50 pp
    /// each over 48 h read 175%; add an exhausted third whose refill is counted
    /// and whose burn cannot be, and the same fleet reads 116.7% — the most
    /// alarming fact about it moving the figure 58 points towards calm.
    func testAnAccountPinnedAtItsCeilingThroughoutIsNotCounted() throws {
        let spending = [try history("main", [0, 25, 50], overHours: 48),
                        try history("acc2", [0, 25, 50], overHours: 48)]
        let pinned = try history("acc3", [100, 100, 100, 100, 100], overHours: 48)

        let answer = try XCTUnwrap(FleetCapacity.burnAgainstRefill(
            histories: histories(spending + [pinned]),
            accounts: try fleet(["main", "acc2", "acc3"])))
        XCTAssertEqual(answer.accounts, 2, "the exhausted account was measured over nothing at all")
        XCTAssertEqual(answer.percent, 175, accuracy: 0.01, """
            counting the blocked account's refill answers 116.7% for the same two spending \
            accounts: a fleet with an exhausted member in it reading calmer than the same fleet \
            without one
            """)
    }

    /// **What one reading is worth at the ceiling**, held on both sides of the
    /// boundary at once.
    ///
    /// The guard that excludes a pinned account is a one-sample probe —
    /// `everBelowCeiling` — so a series that touches 99 once is measured and one
    /// that never leaves 100 is refused outright. Beside the same spending
    /// account those two answer **87.5% with `≥`** and **175% without**: one
    /// reading, of exactly the width the ±1 pp sawtooth produces (§4), moves the
    /// published figure by 87.5 points and takes the caveat off it. Both halves
    /// were already asserted, in two different tests about two different things
    /// (`UsageTests.testTheFigureIsBuiltFromRawPointsRatherThanSmoothedOnes` for
    /// the smoothing, `testAnAccountPinnedAtItsCeilingThroughoutIsNotCounted` for
    /// the exclusion); what nothing said was that they are one step, and a step
    /// is not visible from either side of itself.
    ///
    /// **The behaviour is deliberate and this test pins it rather than judging
    /// it.** Two changes were considered on 2026-09-05 and both were refused:
    /// raising `isLowerBound` for an excluded account, which would be a claim
    /// nothing supports (the direction is unknown — see `FleetBurn.isLowerBound`
    /// for the worked example), and replacing the one-sample probe with a
    /// fraction-of-readings threshold, which would be a constant with nothing to
    /// calibrate it against (§2.7 records why: no account came near its ceiling
    /// at all on the day it was asked).
    func testOneReadingBelowTheCeilingIsTheWholeDifferenceBetweenMeasuredAndRefused() throws {
        let spending = try history("main", [0, 25, 50], overHours: 48)
        let touched = try history("acc2", [100, 99, 100, 100, 100], overHours: 48)
        let pinned = try history("acc2", [100, 100, 100, 100, 100], overHours: 48)

        let measured = try XCTUnwrap(FleetCapacity.burnAgainstRefill(
            histories: histories([spending, touched]), accounts: try fleet(["main", "acc2"])))
        XCTAssertEqual(measured.accounts, 2, "one reading below the ceiling is a measured account")
        XCTAssertEqual(measured.percent, 87.5, accuracy: 0.01,
                       "acc2 brings a week of refill and a burn of nothing")
        XCTAssertTrue(measured.isLowerBound, "and the burn it was blocked from is missing")

        let refused = try XCTUnwrap(FleetCapacity.burnAgainstRefill(
            histories: histories([spending, pinned]), accounts: try fleet(["main", "acc2"])))
        XCTAssertEqual(refused.accounts, 1, "a series that never leaves its ceiling is not measured")
        XCTAssertEqual(refused.percent, 175, accuracy: 0.01, """
            deleting a single 99 from acc2's series moves the fleet from 87.5% to 175%: the account \
            leaves with its refill share, and the figure it was dragging down doubles
            """)
        XCTAssertFalse(refused.isLowerBound, """
            and the mark goes with it — the excluded account loses a burn term and a refill share \
            at once, so the mean moves either way and `≥` would be a claim about a direction \
            nobody knows
            """)
    }

    /// **A ceiling over part of the window is a different thing and stays**, and
    /// what it costs the figure is the `≥` on both surfaces: the points that
    /// account was blocked from burning never entered its series, so the burn is
    /// understated and the ratio with it.
    ///
    /// The control half is the same fleet with the blocked stretch taken out.
    /// Without it this would pass on an implementation that raises the flag for
    /// every fleet.
    func testAnAccountBlockedForPartOfTheWindowMakesTheFigureAFloor() throws {
        let blocked = try history("acc2", [50, 70, 100, 100], overHours: 48)
        let answer = try XCTUnwrap(FleetCapacity.burnAgainstRefill(
            histories: histories([blocked]), accounts: try fleet(["acc2"])))
        XCTAssertTrue(answer.isLowerBound, """
            the account sat at 100 for the second half of the window: what it would have burned \
            there is missing from this figure, and the surfaces owe the reader a mark saying so
            """)
        XCTAssertEqual(answer.accounts, 1, "and it is still a contributor, unlike one blocked throughout")

        let free = try history("acc2", [50, 70, 90, 99], overHours: 48)
        let control = try XCTUnwrap(FleetCapacity.burnAgainstRefill(
            histories: histories([free]), accounts: try fleet(["acc2"])))
        XCTAssertFalse(control.isLowerBound, "nothing touched the ceiling, so nothing was suppressed")
    }

    /// One blocked account among several is enough: the flag is about the
    /// figure and the figure is one sum, so an account whose burn was suppressed
    /// understates the whole of it.
    func testOneBlockedAccountIsEnoughToMakeTheWholeFigureAFloor() throws {
        let answer = try XCTUnwrap(FleetCapacity.burnAgainstRefill(
            histories: histories([try history("main", [0, 25, 50], overHours: 48),
                                  try history("acc2", [50, 70, 100, 100], overHours: 48)]),
            accounts: try fleet(["main", "acc2"])))
        XCTAssertTrue(answer.isLowerBound,
                      "a sum with a suppressed term in it is a floor, whatever the other terms did")
    }

    /// The schedule reaches this figure through the accounts, and only through
    /// them: `measure` is handed `sevenDay.resetsAt` from the account the series
    /// belongs to, which is the one thing that can place a reset nobody's
    /// readings saw.
    ///
    /// The fixture is the hidden-reset shape from `FleetCapacityTests` inside a
    /// fleet: 95 across a hole to 92, which is a window that ended lower than it
    /// began and so burned 97 pp rather than un-burning 3. Handed no schedule
    /// the same fleet has no figure at all, and that pair is the whole of what
    /// this test is for — passing the wrong account's schedule, or none, is a
    /// mistake nothing else here can see.
    func testTheResetScheduleReachesTheFigureThroughItsOwnAccount() throws {
        let series = try history("main", [95, nil, nil, nil, 92], overHours: 48)
        let boundaryInside = start.addingTimeInterval((24 + 168) * 3600)
        let scheduled = try UsageFixtures.decode("""
        {"accounts": {"main": {"seven_day": {"utilization": 92, \
        "resets_at": "\(ISO8601DateFormatter().string(from: boundaryInside))"}}}}
        """, as: UsageReport.self).accounts

        let answer = try XCTUnwrap(FleetCapacity.burnAgainstRefill(histories: histories([series]),
                                                                   accounts: scheduled))
        XCTAssertEqual(answer.burnRate, 97.0 / 48, accuracy: 0.0001,
                       "the window that turned over inside the hole is 97 pp, not −3")

        XCTAssertNil(FleetCapacity.burnAgainstRefill(histories: histories([series]),
                                                     accounts: try fleet(["main"])),
                     "with no schedule to place that fall there is no figure, and this fleet has one")
    }
}
