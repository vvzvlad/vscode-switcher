import XCTest
@testable import VSCodeSwitcher

/// The burn rule (`FleetCapacity.measure`): how many percentage points an
/// account spent over a span, and the ways of getting it wrong.
///
/// The utilisation series jitters by ±1 pp, so reading burn as "how much did
/// this go up" reads a quiet account as a busy one. The rest holds the guards
/// around it: what counts as a reset, when the schedule may be consulted, when
/// there is no answer at all.
///
/// A reset is charged the level the series fell from, not a flat 100 pp. The
/// flat window survives only in `testAResetHiddenInAHoleIsFoundThroughTheSchedule`,
/// where nobody saw the fall.
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
    /// deltas every jitter tooth is charged as spend and the answer triples.
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
    /// Here the flat window and the observed level are the same number, so this
    /// catches only a missing reset credit; `testAResetIsChargedTheLevelItFellFrom`
    /// holds the level rule, and the test above holds the endpoint rule.
    func testAResetInsideTheIntervalRestoresTheWholeWindowWhenItFellFromTheCeiling() throws {
        let series = try history("main", [100, 100, 0, 25, 50], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 50, accuracy: 0.001,
                       "the endpoints alone read −50 pp, which is an account that un-burned its quota")
    }

    /// A reset restores the level the series fell from, not a whole window.
    ///
    /// acc2's live shape: 44 when the window opened, climbed to 66, turned over
    /// there, and stood at 20 when read. Burn is `(66 − 44) + 20 = 42` pp (§2.7);
    /// the flat rule charges 76. The fixture keeps `first`, the fall level and
    /// `last` all different, so "the burn is the last reading" cannot pass.
    ///
    /// A window's quota is 100 points of utilisation, and an account that never
    /// reached the top of the old window never had those points to spend.
    func testAResetIsChargedTheLevelItFellFrom() throws {
        let series = try history("acc2", [44, 55, 66, 0, 10, 20], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 42, accuracy: 0.001, """
            20 − 44 over the interval plus the 66 the window was standing at when it turned over; \
            a flat 100 answers 76 pp, which is the live over-charge that took the fleet from \
            112.8% to 157.2%, and the last reading alone answers 20
            """)
    }

    /// Two falls over the threshold inside one 48 h span collapse to a single
    /// reset: a seven-day window cannot turn over twice in two days, so the
    /// second fall is a lagging sample and charging it costs +100 pp that never
    /// happened. No span the gateway can serve (capped by `max_points`) holds two
    /// real resets.
    func testTwoFallsInsideOneSpanCollapseToASingleReset() throws {
        let series = try history("main", [10, 90, 5, 95, 30], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 110, accuracy: 0.001, """
            30 − 10 over the interval plus the 90 the first window was standing at when it turned \
            over; counting both falls answers 200 pp for an account that could not have spent two \
            windows in two days
            """)
    }

    /// The clamp on live data.
    ///
    /// The gateway measures each account two ways (its own poll and a response
    /// header), and across a reset the two disagree for about a minute, so the
    /// series flip-flops: acc2 fell `66 → 0` three times within 30 s. Charged the
    /// level each time, that is 198 pp of credit on a window that held 66.
    func testAFlipFloppingResetIsStillOneReset() throws {
        let series = try history("acc2", [66, 0, 66, 0, 66, 0, 42], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 42, accuracy: 0.001, """
            one window turned over, at 66: charging each of the three falls credits 198 pp and \
            answers 174 for an account that burned 42
            """)
    }

    /// What a window edge landing inside a flip-flop costs, both ways round.
    /// This test pins a known over-charge rather than a rule, and a fix to
    /// `measure` is expected to change it deliberately.
    ///
    /// The clamp keeps one reset out of three falls, but cannot say which side of
    /// the flip-flop the interval's ends fell on. A last reading on the pre-reset
    /// value, `[44, 66, 0, 66]`, counts the window twice (88 pp for 22 spent); a
    /// first reading on the post-reset zero, `[0, 66, 0, 10, 42]`, credits a reset
    /// the interval opened after (108 pp for 42). The third fixture is the control
    /// with the alignment the rule is written for.
    ///
    /// A flip-flop is about 23–65 s wide and the histories are re-asked every
    /// 600 s, so either edge catches it with probability about 8–22% per reset per
    /// account. Refusing such windows would be a design change: the interval
    /// genuinely holds a fall.
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

    /// What a fall after a hole costs: the level rule's blind spot, mirror of the
    /// flat rule's. This test pins a known under-charge rather than a rule, and a
    /// fix to `measure` is expected to change it deliberately.
    ///
    /// Across a hole the last pre-fall reading is stale: the window went on
    /// climbing unseen, so the level charged is too low, by up to the headroom at
    /// that reading. The flat rule errs loud; this one errs quiet, toward calm.
    ///
    /// The control is the same arithmetic with the level fresh. `measure` cannot
    /// tell the two apart, so no `≥` is raised: that would need a staleness
    /// threshold nothing calibrates (§2.7).
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
    /// window: an account whose window turns over at 45 falls 40 pp, and 5 sits
    /// low enough to read that as the reset it is. Raise the constant past this
    /// fall and the interval reads −25 pp, no schedule places it, and the account
    /// is refused. The hole fixtures hold the threshold from below.
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
    /// The one place a reset is still charged a flat 100 pp: nobody observed the
    /// fall, so there is no level to charge. It errs upward.
    func testAResetHiddenInAHoleIsFoundThroughTheSchedule() throws {
        let series = try history("main", [95, nil, nil, nil, 92], overHours: 48)
        let boundaryInside = seriesStart.addingTimeInterval((24 + 168) * 3600)
        XCTAssertEqual(try burnedPP(series, resetsAt: boundaryInside), 97, accuracy: 0.001,
                       "the endpoints alone read −3 pp, which the clamp would serve as a confident 0%")

        // The control half: the same series with only the schedule moved. A
        // window that began before the first reading or after the last did not
        // begin inside this interval, so readings and schedule contradict each
        // other and there is no figure (§2.7). No tolerance: the gateway's own lag
        // can only move an observed fall later, into the interval.
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

    /// The phantom the schedule guard must not invent: the caller asks for
    /// `now − 48 h`, that edge slides past a reset instant, and the first reading
    /// is already the post-reset value. Nothing reset inside the interval — it
    /// starts at zero and rises — and the schedule must not be consulted at all.
    /// Asking the schedule without the readings answers 152 pp instead of 52.
    ///
    /// The boundary is placed inside the interval, the one alignment where the
    /// `rawChange < -1` short-circuit is the only thing refusing the phantom. The
    /// boundary check itself (`windowStart > first.at`) is held by the control
    /// halves of `testAResetHiddenInAHoleIsFoundThroughTheSchedule`.
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
    /// is no figure here (§2.7). The 1 pp control is
    /// `testAnIdleAccountJitteringDownDoesNotSubtractDemand`.
    func testAFallPastTheSawtoothWithNoScheduleHasNoAnswer() throws {
        let series = try history("main", [95, nil, nil, nil, 92], overHours: 48)
        XCTAssertNil(FleetCapacity.measure(series.points, resetsAt: nil),
                     "a reset nobody saw and nothing can place is a missing figure, not zero burn")
    }

    /// The refusal's boundary, and why it stands at −1 rather than −2: the two
    /// measuring sources disagree by one point and only downward, and the truth
    /// inside a window cannot fall, so an interval with no reset reads −1 at
    /// worst. This one falls exactly 2 pp across a hole with no schedule. Without
    /// it, the 1 pp and 3 pp neighbours stay green with the threshold at `< -2`.
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
    /// would hand a fleet a whole window of capacity against no spending. Unknown
    /// is not zero (§2.7). The fleet-level cost is
    /// `FleetCapacityBurnTests.testAnAccountPinnedAtItsCeilingThroughoutIsNotCounted`;
    /// this holds that the refusal is in the burn rule itself.
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

    /// The flag the fleet figure's `≥` is made of, raised from two places that
    /// only a series touching its ceiling on the first reading can tell apart:
    /// the seed is `first.value >= ceilingPercent` and the loop starts at
    /// `dropFirst()`. The control half has the ceiling taken out, because a flag
    /// that is always raised marks nothing.
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
/// publishing an answer for a fleet with no contributor at all. The burn rule
/// underneath lives in `FleetCapacityTests` above.
final class FleetCapacityBurnTests: XCTestCase {

    // MARK: - Fixtures

    /// A fixed instant every fixture below ends at, handed to
    /// `burnAgainstRefill` as `now`, so it is also the right-hand edge of the
    /// trailing `FleetCapacity.burnWindowHours`.
    private let now = Date(timeIntervalSince1970: 1_786_665_600)

    /// One account's series: `readings` spread evenly over the `overHours` ending
    /// at `now`, decoded through the wire format because that is the only
    /// initialiser `HistorySeries` has. `overHours: 8` fills the measurement
    /// window exactly; anything less starts late inside it, which is how an
    /// account that went quiet is written here.
    private func history(_ label: String, _ readings: [Double?],
                         overHours: Double) throws -> HistorySeries {
        let step = readings.count > 1 ? overHours * 3600 / Double(readings.count - 1) : 0
        let start = now.timeIntervalSince1970 - overHours * 3600
        let points = readings.enumerated().map { index, value in
            "{\"ts\": \(start + Double(index) * step), " +
            "\"util_7d\": \(value.map { "\($0)" } ?? "null")}"
        }
        return try UsageFixtures.decode("""
        {"label": "\(label)", "since": \(start), \
        "points": [\(points.joined(separator: ","))]}
        """, as: HistorySeries.self)
    }

    /// The figure over a fleet nobody has switched off, anchored at `now`. Named
    /// so the two arguments this suite almost never varies stay out of the way of
    /// the two it does.
    private func burn(_ all: [HistorySeries], _ labels: [String],
                      switchedOff: Set<String> = []) throws -> FleetCapacity.FleetBurn? {
        FleetCapacity.burnAgainstRefill(histories: histories(all),
                                        accounts: try fleet(labels),
                                        switchedOff: switchedOff,
                                        now: now)
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
    /// 10 pp over the 8 h window is 1.25 pp/h; one account refills 100 pp over
    /// 168 h, which is 0.5952 pp/h; the quotient is exactly 2.1. At
    /// `burnWindowHours` a burn of `B` points reads `21 x B` per cent, which is
    /// what makes every expectation in this file a whole number.
    func testTheFigureIsTheBurnRateOverTheWeeksRefillRate() throws {
        let answer = try XCTUnwrap(try burn([try history("main", [0, 5, 10], overHours: 8)],
                                            ["main"]))

        XCTAssertEqual(answer.burnRate, 10.0 / 8, accuracy: 0.0001, "10 pp over 8 measured hours")
        XCTAssertEqual(answer.refillRate, refillPerAccount, accuracy: 0.0001,
                       "one account is one quota a week and no more")
        XCTAssertEqual(answer.percent, 210, accuracy: 0.01,
                       "1.25 pp/h burned against 0.5952 refilled")
        XCTAssertEqual(answer.accounts, 1)
        XCTAssertEqual(answer.measuredHours, 8, accuracy: 0.001)
        XCTAssertFalse(answer.isLowerBound, "nothing was blocked, so nothing is being under-reported")
    }

    /// A rate per account, then summed — never one total over one span.
    ///
    /// Accounts are watched over different spans (one the gateway stopped polling
    /// part-way holds readings over only the end of the window), so pooling the
    /// burns over the pooled refill credits the shallow account's unwatched hours
    /// to the others. Here: 1.25 + 0.5 pp/h against 1.1905 is 147%; pooled, 13 pp
    /// over the 8.333 pp the two spans refill is 156%.
    func testTheRatesAreSummedPerAccountRatherThanPooledOverOneSpan() throws {
        let deep = try history("main", [0, 5, 10], overHours: 8)
        let shallow = try history("acc3", [0, 1.5, 3], overHours: 6)
        let answer = try XCTUnwrap(try burn([deep, shallow], ["main", "acc3"]))

        XCTAssertEqual(answer.burnRate, 1.75, accuracy: 0.0001,
                       "1.25 pp/h and 0.5 pp/h, each measured over the span it was awake for")
        XCTAssertEqual(answer.percent, 147, accuracy: 0.01, """
            one total over the pooled refill answers 156% here: the account that was quiet for the \
            first two hours is credited with hours nobody watched it over
            """)
    }

    /// The refill counts the accounts that could be measured and nobody else.
    ///
    /// An account the gateway names but nothing could be measured for
    /// contributes no burn, so counting it in the refill would widen a
    /// denominator its own numerator is missing from — a fleet reading calmer
    /// for having an account nobody can see. Here that is the difference between
    /// 210% and 105%.
    func testTheRefillCountsTheContributorsAndNobodyElse() throws {
        let answer = try XCTUnwrap(try burn([try history("main", [0, 5, 10], overHours: 8)],
                                            ["main", "acc3"]))

        XCTAssertEqual(answer.accounts, 1, "acc3 sent no history: nobody measured it")
        XCTAssertEqual(answer.refillRate, refillPerAccount, accuracy: 0.0001,
                       "one contributor refills one quota a week")
        XCTAssertEqual(answer.percent, 210, accuracy: 0.01, """
            counting the silent account in the refill answers 105% for the same burn, which is a \
            fleet made to look calm by an account nobody could see
            """)
    }

    /// Membership comes from the account list and not from whatever histories
    /// are lying around: a series under a label the fleet does not have is not a
    /// contributor.
    func testAHistoryUnderALabelTheFleetDoesNotHaveIsNotCounted() throws {
        XCTAssertNil(try burn([try history("retired", [0, 5, 10], overHours: 8)], ["main"]),
                     "a retired account's series was counted as a live account's burn")
    }

    /// The shortest span, not the longest and not the mean: the answer is only
    /// as well measured as its worst-measured contributor, and what the surfaces
    /// print beside the figure is how much watching stands behind it.
    func testTheMeasuredSpanIsTheShortestContributorsAndNotTheLongest() throws {
        let answer = try XCTUnwrap(try burn([try history("main", [0, 5, 10], overHours: 8),
                                             try history("acc3", [0, 1.5, 3], overHours: 6)],
                                            ["main", "acc3"]))
        XCTAssertEqual(answer.measuredHours, 6, accuracy: 0.001,
                       "the awake account's 8 h says nothing about the hours the quiet one missed")
    }

    // MARK: - When there is no figure, and when it is only a floor

    /// A fleet with no contributor has no figure: the refill is the contributors
    /// times a constant, so with none the division is `0 / 0`, a `NaN` every
    /// surface would draw.
    ///
    /// All three ways in are asked: no accounts named, every history too short,
    /// and every account switched off (which reaches the guard past a series that
    /// would otherwise answer, so an unconsulted `switchedOff` fails it).
    func testAFleetWithNoContributorHasNoFigure() throws {
        XCTAssertNil(FleetCapacity.burnAgainstRefill(histories: [:], accounts: [],
                                                     switchedOff: [], now: now),
                     "no accounts is nothing to divide, not nought per cent")

        let brief = try history("main", [0, 50], overHours: 4)
        XCTAssertNil(FleetCapacity.measure(brief.points, resetsAt: nil),
                     "the fixture has to be unmeasurable, or it proves nothing")
        XCTAssertNil(try burn([brief], ["main"]),
                     "an account too shallow to measure is not a contributor either")

        let measurable = try history("main", [0, 5, 10], overHours: 8)
        XCTAssertNotNil(try burn([measurable], ["main"]),
                        "the fixture has to answer while it is switched on, or the half below proves nothing")
        XCTAssertNil(try burn([measurable], ["main"], switchedOff: ["main"]),
                     "a fleet whose every account is switched off has nobody to measure, not 0%")
    }

    /// An account pinned at its ceiling for the whole window is not an account
    /// that spent nothing, it is one whose spending was refused and never
    /// measured — so it takes its refill out with it (§2.7). Counted, the same
    /// fleet would read 140% instead of 210%, moving towards calm.
    func testAnAccountPinnedAtItsCeilingThroughoutIsNotCounted() throws {
        let spending = [try history("main", [0, 5, 10], overHours: 8),
                        try history("acc2", [0, 5, 10], overHours: 8)]
        let pinned = try history("acc3", [100, 100, 100, 100, 100], overHours: 8)

        let answer = try XCTUnwrap(try burn(spending + [pinned], ["main", "acc2", "acc3"]))
        XCTAssertEqual(answer.accounts, 2, "the exhausted account was measured over nothing at all")
        XCTAssertEqual(answer.percent, 210, accuracy: 0.01, """
            counting the blocked account's refill answers 140% for the same two spending \
            accounts: a fleet with an exhausted member in it reading calmer than the same fleet \
            without one
            """)
    }

    /// What one reading is worth at the ceiling, held on both sides of the
    /// boundary at once.
    ///
    /// The guard that excludes a pinned account is a one-sample probe
    /// (`everBelowCeiling`), so a series that touches 99 once is measured and one
    /// that never leaves 100 is refused. Beside the same spending account those
    /// answer 105% with `≥` and 210% without: one sawtooth-wide reading (§4) moves
    /// the figure by 105 points and removes the caveat.
    ///
    /// The behaviour is deliberate and this test pins it. Raising `isLowerBound`
    /// for an excluded account would claim a direction nobody knows
    /// (`FleetBurn.isLowerBound`), and a fraction-of-readings threshold would be a
    /// constant with nothing to calibrate it (§2.7).
    func testOneReadingBelowTheCeilingIsTheWholeDifferenceBetweenMeasuredAndRefused() throws {
        let spending = try history("main", [0, 5, 10], overHours: 8)
        let touched = try history("acc2", [100, 99, 100, 100, 100], overHours: 8)
        let pinned = try history("acc2", [100, 100, 100, 100, 100], overHours: 8)

        let measured = try XCTUnwrap(try burn([spending, touched], ["main", "acc2"]))
        XCTAssertEqual(measured.accounts, 2, "one reading below the ceiling is a measured account")
        XCTAssertEqual(measured.percent, 105, accuracy: 0.01,
                       "acc2 brings a week of refill and a burn of nothing")
        XCTAssertTrue(measured.isLowerBound, "and the burn it was blocked from is missing")

        let refused = try XCTUnwrap(try burn([spending, pinned], ["main", "acc2"]))
        XCTAssertEqual(refused.accounts, 1, "a series that never leaves its ceiling is not measured")
        XCTAssertEqual(refused.percent, 210, accuracy: 0.01, """
            deleting a single 99 from acc2's series moves the fleet from 105% to 210%: the account \
            leaves with its refill share, and the figure it was dragging down doubles
            """)
        XCTAssertFalse(refused.isLowerBound, """
            and the mark goes with it — the excluded account loses a burn term and a refill share \
            at once, so the mean moves either way and `≥` would be a claim about a direction \
            nobody knows
            """)
    }

    /// A ceiling over part of the window is a different thing and stays: the
    /// points that account was blocked from burning never entered its series, so
    /// the figure is understated and both surfaces show `≥`. The control half is
    /// the same fleet with the blocked stretch taken out.
    func testAnAccountBlockedForPartOfTheWindowMakesTheFigureAFloor() throws {
        let blocked = try history("acc2", [50, 70, 100, 100], overHours: 8)
        let answer = try XCTUnwrap(try burn([blocked], ["acc2"]))
        XCTAssertTrue(answer.isLowerBound, """
            the account sat at 100 for the second half of the window: what it would have burned \
            there is missing from this figure, and the surfaces owe the reader a mark saying so
            """)
        XCTAssertEqual(answer.accounts, 1, "and it is still a contributor, unlike one blocked throughout")

        let free = try history("acc2", [50, 70, 90, 99], overHours: 8)
        let control = try XCTUnwrap(try burn([free], ["acc2"]))
        XCTAssertFalse(control.isLowerBound, "nothing touched the ceiling, so nothing was suppressed")
    }

    /// One blocked account among several is enough: the flag is about the
    /// figure and the figure is one sum, so an account whose burn was suppressed
    /// understates the whole of it.
    func testOneBlockedAccountIsEnoughToMakeTheWholeFigureAFloor() throws {
        let answer = try XCTUnwrap(try burn([try history("main", [0, 5, 10], overHours: 8),
                                             try history("acc2", [50, 70, 100, 100], overHours: 8)],
                                            ["main", "acc2"]))
        XCTAssertTrue(answer.isLowerBound,
                      "a sum with a suppressed term in it is a floor, whatever the other terms did")
    }

    /// The schedule reaches this figure through the accounts, and only through
    /// them: `measure` is handed `sevenDay.resetsAt` from the account the series
    /// belongs to, the one thing that can place a reset nobody's readings saw.
    ///
    /// The fixture is the hidden-reset shape from `FleetCapacityTests`: 95 across
    /// a hole to 92, which burned 97 pp. Handed no schedule the same fleet has no
    /// figure at all, so passing the wrong account's schedule, or none, fails.
    func testTheResetScheduleReachesTheFigureThroughItsOwnAccount() throws {
        let series = try history("main", [95, nil, nil, nil, 92], overHours: 8)
        // Four hours before `now`, so a week before that is a window boundary
        // strictly inside the measured interval — which is the only placement
        // `measure` will act on.
        let boundaryInside = now.addingTimeInterval((168 - 4) * 3600)
        let scheduled = try UsageFixtures.decode("""
        {"accounts": {"main": {"seven_day": {"utilization": 92, \
        "resets_at": "\(ISO8601DateFormatter().string(from: boundaryInside))"}}}}
        """, as: UsageReport.self).accounts

        let answer = try XCTUnwrap(FleetCapacity.burnAgainstRefill(histories: histories([series]),
                                                                   accounts: scheduled,
                                                                   switchedOff: [], now: now))
        XCTAssertEqual(answer.burnRate, 97.0 / 8, accuracy: 0.0001,
                       "the window that turned over inside the hole is 97 pp, not −3")

        XCTAssertNil(try burn([series], ["main"]),
                     "with no schedule to place that fall there is no figure, and this fleet has one")
    }

    // MARK: - The trailing window

    /// The figure is measured over the trailing `burnWindowHours`, not over
    /// whatever the series happens to hold.
    ///
    /// An account holds 46 h of series: 38 flat hours, then 10 pp over the last
    /// 8. Over the whole span the fleet reads 37%; over the trailing window, 210%.
    /// The series reaches past the window because every other fixture here is
    /// 8 h long, so an implementation that ignores the trim passes them all.
    func testAnAccountIsMeasuredOverTheTrailingWindowAndNotItsWholeSeries() throws {
        // 47 readings an hour apart: 38 flat hours, then a point every 48 min over
        // the last 8. The window's left edge lands inside the flat stretch.
        var readings: [Double?] = Array(repeating: 0, count: 39)
        readings += (1...8).map { Double($0) * 1.25 }
        let long = try history("acc2", readings, overHours: 46)

        let answer = try XCTUnwrap(try burn([long], ["acc2"]))
        XCTAssertEqual(answer.percent, 210, accuracy: 1.0, """
            the trailing window is what makes this figure about now: read over the whole 46 h of \
            series the same account answers 37%, because 38 quiet hours are averaged in with the \
            8 busy ones. A 2 h burst at three times the refill rate moves an 8 h window by 50 \
            points and a 48 h one by 8
            """)
        // A literal, not `burnWindowHours`: built from the constant, this would
        // hold for every window, and the two assertions above do not pin the value
        // either (any window inside the last 8 h reads the same 210%).
        XCTAssertEqual(answer.measuredHours, 8, accuracy: 0.2, """
            the span the answer is divided by is the window's and not the series', or the rate is \
            a burn over 8 h spread across 46
            """)

        // And the value itself, because nothing above can fail for 7 h or 9.
        XCTAssertEqual(FleetCapacity.burnWindowHours, 8, """
            8 h, and it is chosen inside a measured band rather than at a plateau — the docblock \
            on the constant says so out loud. Below, the floor forbids it: a 6.00 h window held \
            5.912 h of readings on the live acc2 and every account was refused (2026-09-09 \
            17:43Z). Above, the burst the figure exists to show is diluted — busy stretches on \
            this fleet run 3.0 h at the median and 7.0 h at p90, and a window shows a burst at \
            min(1, T/W) of its strength. Move it and re-measure both ends
            """)
        XCTAssertGreaterThan(FleetCapacity.burnWindowHours, FleetCapacity.minimumMeasuredHours, """
            a window no wider than the floor can never answer at all: the first reading inside it \
            always falls after its left edge, so the readings always span less than the width. \
            The two constants are one decision and this is the half that is not a preference
            """)
    }

    /// The other half of the same rule: readings older than the window are
    /// dropped, not merely under-weighted. Two series with the same last 8 h and
    /// different histories before them (flat, or 90 pp burned) answer the same
    /// figure; reading the span from `first` while summing burn from the window
    /// would separate them.
    func testReadingsOlderThanTheWindowDoNotMoveTheAnswer() throws {
        let recent: [Double?] = (0...8).map { Double($0) * 1.25 + 90 }
        var quietBefore: [Double?] = Array(repeating: 90, count: 38)
        quietBefore += recent
        var busyBefore: [Double?] = (0..<38).map { Double($0) * 90 / 38 }
        busyBefore += recent

        let quiet = try XCTUnwrap(try burn([try history("acc2", quietBefore, overHours: 46)],
                                           ["acc2"]))
        let busy = try XCTUnwrap(try burn([try history("acc2", busyBefore, overHours: 46)],
                                          ["acc2"]))
        XCTAssertEqual(quiet.percent, busy.percent, accuracy: 0.0001, """
            one of these accounts burned 90 pp before the window opened and the other burned \
            nothing, and the figure is about neither: it is about the eight hours they share
            """)
        XCTAssertEqual(quiet.percent, 210, accuracy: 1.0, "and that shared stretch is 10 pp over 8 h")
    }

    // MARK: - The operator's switch

    /// An account the operator has switched off leaves both sides of the
    /// division.
    ///
    /// Three accounts: two burn 1.25 pp/h, the switched-off one 0.25 pp/h, so
    /// each wrong implementation gives a separable answer:
    ///
    ///     excluded from both sides   2.50 / (2 x 0.5952) = 210%   <- correct
    ///     left in both sides         2.75 / (3 x 0.5952) = 154%   <- no exclusion
    ///     burn dropped, refill kept  2.50 / (3 x 0.5952) = 140%   <- half done
    func testASwitchedOffAccountLeavesTheNumeratorAndTheDenominatorTogether() throws {
        let all = [try history("main", [0, 5, 10], overHours: 8),
                   try history("acc2", [0, 5, 10], overHours: 8),
                   try history("acc3", [0, 1, 2], overHours: 8)]
        let labels = ["main", "acc2", "acc3"]

        let answer = try XCTUnwrap(try burn(all, labels, switchedOff: ["acc3"]))
        XCTAssertEqual(answer.accounts, 2, "the switched-off account is not a contributor")
        XCTAssertEqual(answer.refillRate, 2 * refillPerAccount, accuracy: 0.0001, """
            an account nobody can route to refills nothing the fleet can spend: leaving its share \
            in the denominator is what made the live fleet read 90% instead of 210
            """)
        XCTAssertEqual(answer.burnRate, 2.5, accuracy: 0.0001,
                       "and its own 0.25 pp/h is not in the numerator either")
        XCTAssertEqual(answer.percent, 210, accuracy: 0.01, """
            leaving it in both sides answers 154% and taking only its burn out answers 140%: three \
            different numbers, so this can pass only by removing the account from both
            """)

        let included = try XCTUnwrap(try burn(all, labels))
        XCTAssertEqual(included.percent, 154, accuracy: 0.5,
                       "the fixture has to move when the switch is thrown, or it proves nothing")
    }

    /// And it must not raise `≥`, which is where the switch differs from every
    /// other reason a figure is a floor: an excluded account takes a burn term and
    /// a refill share out together, so the mean moves whichever way its rate sat
    /// against its neighbours' (`FleetBurn.isLowerBound`).
    ///
    /// The control half is the same call with the account left in: without it this
    /// would pass on an implementation that never raises the flag at all.
    func testASwitchedOffAccountDoesNotMakeTheFigureAFloor() throws {
        let all = [try history("main", [0, 5, 10], overHours: 8),
                   try history("acc3", [0, 1, 2], overHours: 8)]

        let answer = try XCTUnwrap(try burn(all, ["main", "acc3"], switchedOff: ["acc3"]))
        XCTAssertFalse(answer.isLowerBound, """
            excluding an account moves the mean either way, so `≥` would be a claim about a \
            direction that reverses inside a day on the live fleet
            """)

        let blocked = [try history("main", [0, 5, 10], overHours: 8),
                       try history("acc3", [50, 70, 100, 100], overHours: 8)]
        let control = try XCTUnwrap(try burn(blocked, ["main", "acc3"]))
        XCTAssertTrue(control.isLowerBound, """
            the flag has to be raisable by this suite at all, or the assertion above is green for \
            an implementation that has no flag
            """)
    }
}
