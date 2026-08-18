import XCTest
@testable import VSCodeSwitcher

/// Supply against demand over a week, and the ways of getting it wrong.
///
/// The one that matters is the first test here: the utilisation series jitters
/// by ±1 pp, so anything that reads burn as "how much did this go up" reads a
/// quiet account as a busy one. Everything else holds the shape of the answer —
/// which accounts are counted, over what span, and when there is no answer at
/// all.
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

    /// The fleet's membership. `AccountUsage.label` is the key the object sat
    /// under rather than a field of its own, so the whole report is decoded to
    /// get labelled accounts — the same path the gateway's answer takes.
    ///
    /// `sevenDayResetsAt` is the end of the current window as the gateway
    /// announces it, given to every account in the list. Left out, the accounts
    /// come back the way the report reads when the window is unknown — with no
    /// schedule to place a reset that fell inside a hole.
    private func fleet(_ labels: [String], sevenDayResetsAt: Date? = nil) throws -> [AccountUsage] {
        let window = sevenDayResetsAt.map { "{\"seven_day\": {\"resets_at\": \"\($0.formatted(.iso8601))\"}}" }
        let body = labels.map { "\"\($0)\": \(window ?? "{}")" }.joined(separator: ",")
        return try UsageFixtures.decode("{\"accounts\": {\(body)}}", as: UsageReport.self).accounts
    }

    private func histories(_ series: [HistorySeries]) -> [String: HistorySeries] {
        Dictionary(uniqueKeysWithValues: series.map { ($0.label, $0) })
    }

    /// The percentage points one account burned, read back out of the answer:
    /// `percent = burn / hours x 168 / capacity x 100`, and for a one-account
    /// fleet capacity is exactly 100 pp. Only valid for such a fleet — with two
    /// accounts of different depth there is no single span to invert.
    private func burnedPP(_ load: FleetLoad) -> Double {
        load.percent * load.measuredHours / 168
    }

    // MARK: - Burn is the endpoints, not the steps

    /// The trap this whole file exists for.
    ///
    /// A series that rises 0 → 50 over 48 h while jittering by ±1 pp on single
    /// samples. Read by its endpoints it burned 50 pp; summed as positive
    /// deltas every jitter tooth is charged as spend and the answer triples. The
    /// live case is acc2 over 62 h: 158 pp against a true 50, from 111 spurious
    /// spikes of one point each.
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
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([series]),
                                                    accounts: try fleet(["main"])))

        XCTAssertEqual(burnedPP(load), 50, accuracy: 0.001, """
            burn must come from the endpoints and the resets between them, never from a sum of \
            positive deltas: this series carries \(Int(naive) - 50) jitter teeth of ±1 pp, and \
            summing its rises answers \(Int(naive)) pp for an account that burned 50. \
            Live: acc2 read 158 pp over 62 h where the true figure was 50.
            """)
    }

    /// The window turned over mid-interval: 100 → 0 → 50. Endpoints alone say
    /// the account gave 50 pp back.
    ///
    /// What it catches is the `+ 100` per reset going missing; what it cannot
    /// catch is the endpoint rule being replaced by a sum of positive deltas —
    /// over this fixture that sum is 25 + 25, the same 50 — and the test above
    /// is the only one that can.
    func testAResetInsideTheIntervalIsAHundredPointsRestored() throws {
        let series = try history("main", [100, 100, 0, 25, 50], overHours: 48)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([series]),
                                                    accounts: try fleet(["main"])))
        XCTAssertEqual(burnedPP(load), 50, accuracy: 0.001,
                       "the endpoints alone read −50 pp, which is an account that un-burned its quota")
    }

    /// Two falls over the threshold inside one 48 h span, and they collapse to a
    /// single reset: a seven-day window cannot turn over twice in two days, so
    /// the second fall is a lagging sample and charging it costs +100 pp that
    /// never happened.
    ///
    /// The clamp used to ask `hours <= hoursPerWeek` first, for a span long
    /// enough to hold two real resets. This test stands where that question used
    /// to be asked, because the gateway cannot produce such a span: `since` of
    /// 2, 7 and 30 days all come back with the same points, and the deepest
    /// account reaches 64.89 h — a week is four times that. The reasoning about
    /// weeks belongs in a comment now, not in a 15-day fixture built out of
    /// readings 90 hours apart by a source that samples once a minute.
    func testTwoFallsInsideOneSpanCollapseToASingleReset() throws {
        let series = try history("main", [10, 90, 5, 95, 30], overHours: 48)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([series]),
                                                    accounts: try fleet(["main"])))
        XCTAssertEqual(burnedPP(load), 120, accuracy: 0.001, """
            30 − 10 over the interval plus the one window that turned over inside it; counting both \
            falls answers 220 pp for an account that could not have spent two windows in two days
            """)
    }

    /// A single lagging sample beside a real reset: the series falls twice —
    /// 95 → 0 and 95 → 3 — but 48 h cannot hold two seven-day windows, so the
    /// second fall is the sample that lagged, not a window that turned over.
    /// Counted as one it is charged +100 pp that never happened.
    func testALaggingSampleBesideAResetIsNotASecondReset() throws {
        let series = try history("main", [95, 0, 95, 3, 10], overHours: 48)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([series]),
                                                    accounts: try fleet(["main"])))
        XCTAssertEqual(burnedPP(load), 15, accuracy: 0.001, """
            10 − 95 over the interval plus the one window that turned over inside it; counting the \
            lagging sample as a second reset answers 115 pp for an account that burned about 15
            """)
    }

    /// The reset threshold held from above. Not every reset falls a whole
    /// window: both resets on record are 99 → 0 and 100 → 0, but an account
    /// whose window turns over at 45 falls 40 pp, and 5 sits low enough to read
    /// that as the reset it is. Raise the constant past this fall and it goes
    /// uncounted: the interval then reads −25 pp, no schedule is offered to
    /// place what happened, and the account is refused altogether, leaving both
    /// halves of the fraction. From below the constant was already held: lower
    /// it to 1.5 and the 2 and 3 pp falls the hole fixtures are built on are
    /// charged as whole restored windows, which reddens three of them (checked
    /// by mutation, 2026-08-17). From above nothing held it at all.
    func testAFallDeeperThanTheSawtoothIsAResetEvenWithoutAWholeWindowBehindIt() throws {
        let series = try history("main", [45, 5, 10, 15, 20], overHours: 48)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([series]),
                                                    accounts: try fleet(["main"])))
        XCTAssertEqual(burnedPP(load), 75, accuracy: 0.001, """
            20 − 45 over the interval plus the window that turned over inside it; a threshold too \
            high to see this fall does not answer 25 pp or 0, it refuses the account and takes its \
            100 pp of capacity out with it
            """)
    }

    /// The threshold is the largest fall that is still the signal moving, not
    /// the smallest fall that is a reset: `>` and not `>=`. So a fall of exactly
    /// `resetDropThreshold` is the signal, and this account burned the 5 pp its
    /// endpoints say. Asked with `>=` the same series is charged a whole
    /// restored window — 105 pp for an account that spent 5 — and every other
    /// fixture here falls either well inside the threshold or well past it.
    func testAFallOfExactlyTheThresholdIsNotAReset() throws {
        let series = try history("main", [50, 50 - FleetCapacity.resetDropThreshold, 55], overHours: 48)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([series]),
                                                    accounts: try fleet(["main"])))
        XCTAssertEqual(burnedPP(load), 5, accuracy: 0.001,
                       "55 − 50 with nothing but the signal in between; counting that fall as a reset answers 105 pp")
    }

    /// The mirror of the phantom: a reset that fell entirely inside a hole is
    /// not a fall between two readings, but the readings still carry its
    /// signature — 95 → 92 across the hole is a window that ended lower than it
    /// began, which nothing but a reset does. The schedule is what places it:
    /// this window ends a week after a moment inside the interval, so it began
    /// inside the interval, and the account did not un-burn 3 pp — it spent 97.
    func testAResetHiddenInAHoleIsFoundThroughTheSchedule() throws {
        let series = try history("main", [95, nil, nil, nil, 92], overHours: 48)
        let boundaryInside = seriesStart.addingTimeInterval((24 + 168) * 3600)
        let load = try XCTUnwrap(FleetCapacity.load(
            histories: histories([series]),
            accounts: try fleet(["main"], sevenDayResetsAt: boundaryInside)))
        XCTAssertEqual(burnedPP(load), 97, accuracy: 0.001,
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
            XCTAssertNil(FleetCapacity.load(
                histories: histories([series]),
                accounts: try fleet(["main"], sevenDayResetsAt: seriesStart.addingTimeInterval(boundary))),
                         "a window that began \(side) cannot be the reset this interval hides")
        }
    }

    /// The phantom the schedule guard used to invent, in the shape that produces
    /// it live: the caller asks for `now − 48 h`, that edge slides past a reset
    /// instant, and the first reading of the series is then already the
    /// post-reset value. Nothing reset inside the interval — it starts at zero
    /// and rises — but the boundary still sits minutes before the first reading.
    ///
    /// Replayed from acc2 on 2026-08-17 (boundary 2026-08-15 21:00:00Z, first
    /// post-reset reading 285 s later, 52 by the end): asking the schedule
    /// without asking the readings answered 152 pp instead of 52, and took the
    /// three-account fleet from 134% to 255%. It is not a rare alignment either
    /// — every account passes through it for the quarter of an hour a week its
    /// boundary spends inside the old tolerance.
    func testAScheduleBoundaryBeforeARisingSeriesIsNotAHiddenReset() throws {
        let afterTheReset = try history("acc2", [0, 12, 25, 40, 52], overHours: 48)
        let boundaryJustBefore = seriesStart.addingTimeInterval(168 * 3600 - 5 * 60)
        let load = try XCTUnwrap(FleetCapacity.load(
            histories: histories([afterTheReset]),
            accounts: try fleet(["acc2"], sevenDayResetsAt: boundaryJustBefore)))
        XCTAssertEqual(burnedPP(load), 52, accuracy: 0.001, """
            the series starts at zero and climbs: the window turned over before the interval opened, \
            not inside it, and charging it again answers 152 pp for an account that spent 52
            """)
    }

    /// The same hidden reset with no schedule to place it. The fall is 3 pp,
    /// three times the sawtooth, so it is not jitter and `max(0, …)` would turn
    /// it into a confident 0% for an account that spent most of a window. There
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
        XCTAssertNil(FleetCapacity.load(histories: histories([series]), accounts: try fleet(["main"])),
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
        XCTAssertNil(FleetCapacity.load(histories: histories([series]), accounts: try fleet(["main"])), """
            a one-sided ±1 tooth cannot take an interval two points below where it opened: something \
            restored this window, nothing here can place it, and a missing figure beats a confident 0%
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
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([series]),
                                                    accounts: try fleet(["main"])))
        XCTAssertEqual(burnedPP(load), 10, accuracy: 0.001,
                       "a hole read as zero fakes a reset and adds a whole window to the burn")
    }

    /// An idle account whose reading wobbles down by a point has not un-burned
    /// anything. Left signed, its negative rate would make the rest of the fleet
    /// look cheaper than it is.
    func testAnIdleAccountJitteringDownDoesNotSubtractDemand() throws {
        let series = try history("main", [50, 49, 50, 49], overHours: 48)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([series]),
                                                    accounts: try fleet(["main"])))
        XCTAssertEqual(load.percent, 0, accuracy: 0.001, "a fleet at rest is 0% loaded, not −3.5%")
    }

    // MARK: - Rates per account, capacity over contributors

    /// The accounts do not have the same depth of history — 2.16 / 2.18 / 2.74
    /// days over acc2 / acc3 / main, live on 2026-08-17. It is not that the
    /// gateway cut one of them at `max_points`: it cut *two*, and the account it
    /// did not cut is the deepest of the three (see `FleetLoad.measuredHours`).
    /// A rate per account, then summed; dividing one total by the longest span
    /// would credit the shallow account with hours nobody measured it over.
    func testRatesAreSummedPerAccountRatherThanDividedByTheLongestSpan() throws {
        let deep = try history("acc2", [0, 48], overHours: 48)       // 1.0 pp/h
        let shallow = try history("acc3", [10, 22], overHours: 24)   // 0.5 pp/h
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([deep, shallow]),
                                                    accounts: try fleet(["acc2", "acc3"])))

        // (1.0 + 0.5) pp/h x 168 = 252 pp/week against 200 pp of capacity.
        XCTAssertEqual(load.percent, 126, accuracy: 0.001, """
            the naive 60 pp over the longest span of 48 h answers 105%, which is the shallow \
            account measured over hours it was never measured over
            """)
        XCTAssertEqual(load.measuredHours, 24, accuracy: 0.001,
                       "the answer is as well measured as its worst-measured contributor")
    }

    /// The span runs between the first and last *readings*, not between the
    /// first and last points. A series whose tail is holes was measured up to
    /// its last reading and no further: stretched over the points it would be
    /// 48 h instead of 12, and the rate a quarter of what it is.
    func testTheSpanIsMeasuredBetweenReadingsRatherThanPoints() throws {
        let series = try history("main", [50, 60, nil, nil, nil], overHours: 48)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([series]),
                                                    accounts: try fleet(["main"])))

        XCTAssertEqual(load.measuredHours, 12, accuracy: 0.001,
                       "the last three samples said nothing, and hours nobody measured are not measured hours")
        XCTAssertEqual(load.percent, 140, accuracy: 0.001,
                       "10 pp over 12 h is 140 pp/week; over the whole 48 h it would read 35%")
    }

    /// An account with no usable history contributes neither demand nor its
    /// 100 pp of capacity. Counting it into capacity alone would divide a
    /// measured demand by a supply we could not see the spending of.
    func testAnAccountWithoutHistoryDoesNotInflateCapacity() throws {
        let first = try history("acc2", [0, 50], overHours: 48)
        let second = try history("acc3", [20, 70], overHours: 48)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([first, second]),
                                                    accounts: try fleet(["acc2", "acc3", "main"])))

        XCTAssertEqual(load.accounts, 2, "main was never measured and is not a supply we can count")
        // 2 x (50 pp / 48 h) x 168 = 350 pp/week against 200 pp of capacity.
        XCTAssertEqual(load.percent, 175, accuracy: 0.001,
                       "capacity of 300 pp over three accounts would answer 116.7%")
    }

    // MARK: - A blocked account hides demand

    /// While an account is at its ceiling the requests it turns away never reach
    /// the series, so the demand behind them is invisible and the figure is a
    /// floor. Live: acc2 spent 34 samples at 100 during the last 48 h.
    func testASampleAtTheCeilingMakesTheAnswerALowerBound() throws {
        let series = try history("acc2", [90, 100, 100, 0, 20], overHours: 48)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([series]),
                                                    accounts: try fleet(["acc2"])))
        XCTAssertTrue(load.isLowerBound, "the demand an exhausted account turned away is not in its series")
    }

    /// The flag is seeded from the first reading and then raised again inside
    /// the loop, and only a series whose *first* sample is the ceiling can tell
    /// the seed from the loop: an account that entered the measured interval
    /// exhausted, reset out of it and never came near 100 again. Without this
    /// fixture the seed can be written `false` and nothing goes red.
    func testACeilingOnTheFirstReadingAloneIsStillALowerBound() throws {
        let series = try history("acc2", [100, 5, 10, 15, 20], overHours: 48)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([series]),
                                                    accounts: try fleet(["acc2"])))
        XCTAssertTrue(load.isLowerBound, """
            the account was at its ceiling when the interval opened, and the demand it turned away \
            then is missing from the series exactly as much as a ceiling in the middle of it
            """)
    }

    /// The other seed, and the same reason. `everBelowCeiling` is seeded from
    /// the first reading and raised again inside a loop that starts at
    /// `dropFirst()`, so only an account that entered the interval below its
    /// ceiling and reached it on the second sample can tell the seed from the
    /// loop — every other fixture that goes below the ceiling does so after the
    /// first reading. Written `false`, the seed says this account was never
    /// below its ceiling, `measure` refuses it as one that spent the whole
    /// interval blocked, and it leaves both halves of the fraction — its demand
    /// and its 100 pp of capacity — so the answer is recomputed over a fleet
    /// smaller by one.
    ///
    /// How far that moves the answer is not a live figure, and a live figure was
    /// claimed here. Replayed against the gateway on 2026-08-17 the delta is
    /// **zero**: no account has this shape — all three are below their ceiling
    /// somewhere after the first reading — so nothing changes hands and the seed
    /// is unobservable on today's data. What the break costs has to be asked of
    /// an account that has the shape, and then it is large: pinning each of the
    /// three at its ceiling from the second reading on and computing twice, the
    /// seed is worth +36.5, +37.7 and +56.8 points of load (same day, same three
    /// series, only the pinned account swapped). It moves with which account is
    /// pinned and with what the other two are burning, which is exactly why the
    /// number belongs to a construction rather than to "the live fleet".
    func testAnAccountBelowItsCeilingOnlyOnTheFirstReadingIsStillMeasured() throws {
        let series = try history("acc2", [99, 100, 100, 100, 100], overHours: 48)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([series]),
                                                    accounts: try fleet(["acc2"])))
        XCTAssertEqual(load.accounts, 1, """
            the account was below its ceiling when the interval opened and blocked for the rest of \
            it: that is an account measured over a window it spent at the ceiling, not one nobody \
            measured at all
            """)
        XCTAssertTrue(load.isLowerBound,
                      "it sat at 100 from the second sample on, and what it turned away is not in the series")
    }

    /// An account that spent the *whole* interval at 100 is a different case
    /// from one that touched the ceiling on the way: its series is flat, its
    /// burn reads as zero, and counting it hands the fleet a whole window of
    /// capacity against no demand — from the one account that certainly had none
    /// to spare. Two accounts burning 50 pp each over 48 h read 175%; with the
    /// exhausted one counted they read 116.7%, so the most alarming fact about a
    /// fleet moves the number 58 points towards calm. Unknown is not zero
    /// (§2.7), and blocked demand is unknown demand.
    func testAnAccountPinnedAtItsCeilingContributesNeitherDemandNorCapacity() throws {
        let exhausted = try history("acc2", [100, 100, 100, 100, 100], overHours: 48)
        let load = try XCTUnwrap(FleetCapacity.load(
            histories: histories([exhausted,
                                  try history("acc3", [0, 50], overHours: 48),
                                  try history("main", [20, 70], overHours: 48)]),
            accounts: try fleet(["acc2", "acc3", "main"])))

        XCTAssertEqual(load.accounts, 2, "an account blocked throughout was watched, not measured")
        XCTAssertEqual(load.percent, 175, accuracy: 0.001,
                       "counting the exhausted account into capacity alone answers 116.7%")
        XCTAssertFalse(load.isLowerBound, """
            the flag is for a counted account whose demand was partly suppressed; this one is not \
            counted at all, and where it went is `accounts`, which says 2 of 3
            """)
        XCTAssertNil(FleetCapacity.load(histories: histories([exhausted]), accounts: try fleet(["acc2"])),
                     "and on its own it is not a fleet with zero load, it is a fleet nobody measured")
    }

    /// An account that never touched its ceiling served everything it was asked
    /// for, and the figure is the figure.
    func testAFleetBelowItsCeilingIsNotALowerBound() throws {
        let series = try history("acc2", [90, 95, 99], overHours: 48)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([series]),
                                                    accounts: try fleet(["acc2"])))
        XCTAssertFalse(load.isLowerBound, "99 is not the ceiling; nothing was turned away")
    }

    // MARK: - No answer beats a wrong answer

    func testAFleetWithNoAccountsHasNoLoad() {
        XCTAssertNil(FleetCapacity.load(histories: [:], accounts: []))
    }

    /// Membership comes from the account list, not from whatever histories are
    /// lying around: a series under a label the fleet does not have is not
    /// demand anybody can serve.
    func testAHistoryUnderALabelTheFleetDoesNotHaveIsNotDemand() throws {
        let ghost = try history("retired", [0, 50], overHours: 48)
        XCTAssertNil(FleetCapacity.load(histories: histories([ghost]), accounts: try fleet(["acc2"])))
    }

    /// Every sample said nothing about the seven-day window. That is no
    /// readings, which is not a reading of zero — and zero burn over an
    /// uncountable span is not 0%, it is no answer.
    func testASeriesOfNothingButHolesHasNoLoad() throws {
        let series = try history("main", [nil, nil, nil], overHours: 48)
        XCTAssertNil(FleetCapacity.load(histories: histories([series]), accounts: try fleet(["main"])))
    }

    /// A rate from a couple of hours is noise multiplied by 168/span: at two
    /// hours one point of sawtooth is 84 pp/week. The control half matters as
    /// much as the refusal — the same fixture stretched to the minimum has to
    /// come back with an answer, or this would pass on a function that refuses
    /// everything.
    func testASpanShorterThanTheMinimumIsRefused() throws {
        let brief = try history("main", [0, 50], overHours: 4)
        XCTAssertNil(FleetCapacity.load(histories: histories([brief]), accounts: try fleet(["main"])),
                     "50 pp over 4 h extrapolates to 2100 pp/week, which is noise wearing a number")

        let long = try history("main", [0, 50], overHours: FleetCapacity.minimumMeasuredHours)
        XCTAssertNotNil(FleetCapacity.load(histories: histories([long]), accounts: try fleet(["main"])),
                        "the minimum is a floor to stand on, not a floor to fall through")
    }

    // MARK: - The live fleet

    /// The measurement this metric was built against, replayed.
    ///
    /// 2026-08-17, three accounts over 48 h: acc2 went 100 → reset → 50 (50 pp),
    /// acc3 went 54 → 93 (39 pp), main went 99 → reset → 18 (19 pp). That is
    /// 108 pp over 48 h — 2.25 pp/h, or 378 pp/week — against a capacity of
    /// 300 pp/week, so 126%. acc2 sat at its ceiling on the way, which makes the
    /// figure a floor.
    func testTheLiveThreeAccountFleetReadsAHundredAndTwentySixPerCent() throws {
        let acc2 = try history("acc2", [100, 100, 0, 25, 50], overHours: 48)
        let acc3 = try history("acc3", [54, 70, 93], overHours: 48)
        let main = try history("main", [99, 99, 0, 9, 18], overHours: 48)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([acc2, acc3, main]),
                                                    accounts: try fleet(["acc2", "acc3", "main"])))

        XCTAssertEqual(load.percent, 126, accuracy: 0.01, "378 pp of demand against 300 pp of capacity")
        XCTAssertTrue(load.isLowerBound, "acc2 was blocked at 100 and could not show what it was asked for")
        XCTAssertEqual(load.accounts, 3)
        XCTAssertEqual(load.measuredHours, 48, accuracy: 0.001)
        XCTAssertNil(load.projection, """
            no window was named, so the default one ran, and the default is a window of two days — \
            the average this whole file was built on
            """)
    }
}

/// The projection: demand as the recent work-hour rate over a week's work hours
/// plus the sleeping hours at their own rate.
///
/// The first section is the one everything else stands on. A per-hour
/// decomposition that does not add back up to the span method is not a finer
/// view of the same burn, it is a second and disagreeing answer — and the first
/// prototype of this disagreed by a whole restored window on the one account
/// whose history crossed a reset.
final class FleetCapacityProjectionTests: XCTestCase {

    // MARK: - Fixtures

    /// 2026-08-14 00:00:00 UTC, and it is midnight so the hour buckets line up
    /// with the numbers in the fixtures rather than with an offset nobody wrote
    /// down.
    private let midnight = Date(timeIntervalSince1970: 1_786_665_600)

    /// The zone the buckets are cut in. Fixed rather than `.current`: an
    /// hour-of-day profile read against the machine's zone would answer
    /// differently in Moscow and in London, and the fixtures name hours.
    private let utc = TimeZone(secondsFromGMT: 0)!

    /// A series given as timestamped readings, encoded and decoded the way the
    /// gateway's answer is — `HistorySeries` has only the wire format's
    /// initialiser.
    private func series(_ label: String, _ readings: [(Date, Double?)]) throws -> HistorySeries {
        let points = readings.map { at, value in
            "{\"ts\": \(at.timeIntervalSince1970), \"util_7d\": \(value.map { "\($0)" } ?? "null")}"
        }
        return try UsageFixtures.decode("""
        {"label": "\(label)", "since": \(midnight.timeIntervalSince1970), \
        "points": [\(points.joined(separator: ","))]}
        """, as: HistorySeries.self)
    }

    /// A series shaped like a day: `rates` is 24 hourly rates in pp/h, indexed by
    /// the hour of the day, and the reading climbs at that rate for `days` days
    /// from `midnight`. One sample every five minutes, which is the order the
    /// gateway takes them at (24 to 42 an hour, §2.7).
    private func shaped(_ label: String, rates: [Double], days: Int) throws -> HistorySeries {
        let step = 300.0
        var value = 0.0
        var readings: [(Date, Double?)] = [(midnight, 0)]
        for sample in 1...(days * 24 * 12) {
            let at = midnight.addingTimeInterval(Double(sample) * step)
            let hour = (sample - 1) / 12 % 24
            value += rates[hour] * step / 3600
            readings.append((at, value))
        }
        return try series(label, readings)
    }

    private func fleet(_ labels: [String], sevenDayResetsAt: Date? = nil) throws -> [AccountUsage] {
        let window = sevenDayResetsAt.map { "{\"seven_day\": {\"resets_at\": \"\($0.formatted(.iso8601))\"}}" }
        let body = labels.map { "\"\($0)\": \(window ?? "{}")" }.joined(separator: ",")
        return try UsageFixtures.decode("{\"accounts\": {\(body)}}", as: UsageReport.self).accounts
    }

    private func histories(_ all: [HistorySeries]) -> [String: HistorySeries] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.label, $0) })
    }

    /// A window that selects the projection. Any value under a day does; six
    /// hours is the default the setting documents.
    private let projecting: Double = 6

    // MARK: - The decomposition reconciles with the span method

    /// **The invariant the whole projection rests on.** Summing the hour buckets
    /// over a contiguous stretch must reproduce what `measure` answers for the
    /// same stretch — the endpoints plus a window per reset, which is the method
    /// three reviews approved.
    ///
    /// The two fixtures are the two ways a reset can sit against the grid, and
    /// the second is the one that broke the prototype. Measured against the live
    /// gateway on 2026-08-18, reading each hour's own first and last reading and
    /// adding 100 per reset seen between them answers 128 pp on main where the
    /// span method answers 27, and 231 pp over the fleet against 132 — a
    /// disagreement of 75%. The mechanism is not a hundred counted twice: a fall
    /// from 99 to 0 that lands *between* one hour's last reading and the next
    /// hour's first is straddled by neither hour's endpoints, so the −99 is never
    /// subtracted while the +100 is still charged.
    ///
    /// So the naive reading is computed here too, and asserted to be wrong. A
    /// fixture that cannot fool the broken method proves nothing about the
    /// working one.
    func testHourBucketsReconcileWithTheSpanMethod() throws {
        /// Each hour's own endpoints plus a window per reset across the gap —
        /// the prototype, kept here as the thing that must not be reproduced.
        func naive(_ points: [HistoryPoint]) -> Double {
            var byHour: [Int: [Double]] = [:]
            var order: [Int] = []
            for point in points {
                guard let value = point.sevenDay else { continue }
                let hour = Int(point.timestamp.timeIntervalSince1970 / 3600)
                if byHour[hour] == nil { order.append(hour) }
                byHour[hour, default: []].append(value)
            }
            var total = 0.0
            var previousLast: Double?
            for hour in order.sorted() {
                let values = byHour[hour] ?? []
                var resets = zip(values, values.dropFirst()).filter { $0 - $1 > FleetCapacity.resetDropThreshold }.count
                if let previousLast, previousLast - values[0] > FleetCapacity.resetDropThreshold { resets += 1 }
                total += (values.last ?? 0) - values[0] + 100 * Double(resets)
                previousLast = values.last
            }
            return total
        }

        // A reset wholly inside one hour, and a reset whose fall is the step
        // from one hour's last reading to the next hour's first. `phantom` is
        // what the naive reading gets wrong on each: the boundary case is where
        // the whole restored window appears out of nothing, and the inside case
        // is the one it survives — which is exactly the shape of the live
        // disagreement, acc2 and acc3 out by a point each and main out by 101.
        let cases: [(name: String, readings: [(Date, Double?)], phantom: ClosedRange<Double>)] = [
            ("a reset inside a bucket", (0..<(30 * 12)).map { sample in
                let at = midnight.addingTimeInterval(Double(sample) * 300)
                // Climbs to 99 by the middle of hour 10, turns over at 10:25,
                // climbs again — both readings of the fall are inside hour 10.
                let value: Double = sample < 125 ? min(99, Double(sample) * 0.8) : Double(sample - 125) * 0.1
                return (at, value)
            }, -30...(-1)),
            ("a reset exactly on a bucket boundary", (0..<(30 * 12)).map { sample in
                let at = midnight.addingTimeInterval(Double(sample) * 300)
                // 99 at 09:55:00, 0 at 10:00:00: the fall is the step that ends
                // exactly where the hour does.
                let value: Double = sample < 120 ? min(99, Double(sample) * 0.9) : Double(sample - 120) * 0.1
                return (at, value)
            }, 80...110),
        ]

        for (name, readings, phantom) in cases {
            let points = try series("main", readings).points
            let span = try XCTUnwrap(FleetCapacity.measure(points, resetsAt: nil), name)
            let hourly = try XCTUnwrap(FleetCapacity.measureHourly(points, resetsAt: nil, timeZone: utc), name)

            XCTAssertEqual(FleetCapacity.burn(over: hourly.buckets), span.burnPP, accuracy: 0.0001, """
                \(name): the buckets summed must be the span's own burn. They answered \
                \(FleetCapacity.burn(over: hourly.buckets)) against \(span.burnPP).
                """)
            XCTAssertTrue(phantom.contains(naive(points) - span.burnPP), """
                \(name): this fixture has to move the per-hour-endpoints reading by \(phantom), or it \
                proves nothing about the one that works. It moved it by \
                \(naive(points) - span.burnPP). Live, that reading answered 128 pp on main where \
                the span answers 27, and 56 and 47 against 57 and 48 on the two accounts whose \
                history holds no reset at all — the hundred appears only when the fall lands \
                between two hours.
                """)

            // And over every contiguous stretch of hours, not only the whole of
            // it: a decomposition that only adds up at the ends is not a
            // decomposition. The samples are five minutes apart and the hours
            // are sixty, so every hour boundary falls on a reading and the
            // stretch's endpoints are exactly the readings that bound it —
            // there is no straddling step for the comparison to argue about.
            for start in stride(from: 0, to: hourly.buckets.count - 4, by: 5) {
                let stretch = Array(hourly.buckets[start..<min(start + 5, hourly.buckets.count)])
                let from = stretch[0].start
                let to = stretch[stretch.count - 1].start.addingTimeInterval(3600)
                let inside = points.filter { $0.timestamp >= from && $0.timestamp <= to }
                    .compactMap(\.sevenDay)
                guard let first = inside.first, let last = inside.last, inside.count > 1 else { continue }
                let resets = zip(inside, inside.dropFirst())
                    .filter { $0 - $1 > FleetCapacity.resetDropThreshold }.count
                XCTAssertEqual(FleetCapacity.burn(over: stretch),
                               last - first + 100 * Double(min(resets, 1)),
                               accuracy: 0.0001,
                               "\(name): hours \(start)…\(start + 5) do not add up to their own endpoints")
            }
        }
    }

    /// The sawtooth is what the endpoint rule exists for, and the buckets inherit
    /// it: a series that jitters by ±1 pp on single samples must not be read as
    /// spending on every rising edge. Summed as positive deltas this fixture
    /// answers three times its burn (`testBurnIsTheEndpointsAndNeverASumOfPositiveDeltas`
    /// carries the live figure); the buckets have to answer the burn.
    func testTheBucketsCarryTheSawtoothRatherThanChargingIt() throws {
        var readings: [(Date, Double?)] = []
        for sample in 0..<(30 * 12) {
            let base = (50.0 * Double(sample) / Double(30 * 12 - 1)).rounded(.down)
            let tooth = sample > 0 && sample % 5 == 2 ? -1.0 : 0
            readings.append((midnight.addingTimeInterval(Double(sample) * 300), max(0, base + tooth)))
        }
        let points = try series("main", readings).points
        let deltas = zip(points.compactMap(\.sevenDay), points.compactMap(\.sevenDay).dropFirst())
            .reduce(0.0) { $0 + max(0, $1.1 - $1.0) }
        XCTAssertGreaterThan(deltas, 100, "the fixture has to be able to fool a delta sum")

        let hourly = try XCTUnwrap(FleetCapacity.measureHourly(points, resetsAt: nil, timeZone: utc))
        let span = try XCTUnwrap(FleetCapacity.measure(points, resetsAt: nil))
        XCTAssertEqual(FleetCapacity.burn(over: hourly.buckets), span.burnPP, accuracy: 0.0001,
                       "summing rises answers \(Int(deltas)) pp for an account that burned \(span.burnPP)")
    }

    /// A step is spread across the hours it spans, in proportion to time. The
    /// readings are levels: what happened between two of them is a stretch, and
    /// charging the whole of it to the hour the later reading landed in turns an
    /// outage into a spike — and turns a two-reading series into one that touched
    /// a single hour of the day, which the day-coverage guard would then refuse
    /// for a series that was watched the whole time.
    func testAStepIsSpreadAcrossTheHoursItSpans() throws {
        let readings: [(Date, Double?)] = [(midnight, 0), (midnight.addingTimeInterval(30 * 3600), 30)]
        let hourly = try XCTUnwrap(FleetCapacity.measureHourly(try series("main", readings).points,
                                                               resetsAt: nil, timeZone: utc))
        XCTAssertEqual(hourly.buckets.count, 30, "two readings 30 h apart cover 30 hours, not one")
        XCTAssertEqual(Set(hourly.buckets.map(\.hourOfDay)).count, 24,
                       "and they cover every hour of the day, which is what lets the day be split")
        for bucket in hourly.buckets {
            XCTAssertEqual(bucket.deltaPP, 1, accuracy: 0.0001, "1 pp an hour, evenly")
            XCTAssertEqual(bucket.hours, 1, accuracy: 0.0001)
        }
    }

    /// A reset step is *not* spread, and that is the same rule from the other
    /// side. Splitting one puts a share of the −99 in one hour and the whole
    /// +100 in the next, which is the prototype's failure written into a single
    /// step. Here the fall straddles an hour boundary with a gap around it, so a
    /// pro-rata split would have something to split.
    func testAResetStepIsChargedWholeToOneHour() throws {
        let readings: [(Date, Double?)] = [
            (midnight, 90),
            (midnight.addingTimeInterval(9 * 3600 + 3000), 99),
            (midnight.addingTimeInterval(10 * 3600 + 600), 0),      // the fall straddles 10:00
            (midnight.addingTimeInterval(30 * 3600), 12),
        ]
        let hourly = try XCTUnwrap(FleetCapacity.measureHourly(try series("main", readings).points,
                                                               resetsAt: nil, timeZone: utc))
        let carrying = hourly.buckets.filter { $0.resets > 0 }
        XCTAssertEqual(carrying.count, 1, "one fall, one hour charged with it")
        // The hour also holds fifty minutes of the long climb that follows, so
        // the figure is a shade above −99; what it must not be is a share of it.
        // Split pro rata over the twenty minutes the fall spans, the two hours
        // would read −49.5 each and the +100 would sit in only one of them.
        XCTAssertLessThan(carrying[0].deltaPP, -90, """
            the change and the reset move together: split, this hour would keep part of the −99 \
            and the next would take the +100 with nothing to cancel it
            """)
        XCTAssertEqual(FleetCapacity.burn(over: hourly.buckets), 22, accuracy: 0.0001,
                       "12 − 90 over the series plus the window that turned over inside it")
    }

    /// Two readings sharing a timestamp keep their change and buy no time.
    ///
    /// Found by the reconciliation refusing to close: a reference that dropped
    /// such steps as zero-length answered 67 pp on acc2 where the span method
    /// says 58. They are common — 31, 13 and 12 pairs in the 48 h window over
    /// acc2, acc3 and main on 2026-08-18 — and they are the gateway's own poll
    /// landing on the same second as a reading lifted from a response header,
    /// which is why they so often disagree by a point and why what they carry is
    /// mostly negative.
    func testTwoReadingsAtOneInstantKeepTheirChangeAndBuyNoTime() throws {
        let simultaneous = midnight.addingTimeInterval(10 * 3600)
        let readings: [(Date, Double?)] = [
            (midnight, 0),
            (simultaneous, 12),
            (simultaneous, 11),                                   // the other source, a point lower
            (midnight.addingTimeInterval(30 * 3600), 20),
        ]
        let points = try series("main", readings).points
        let span = try XCTUnwrap(FleetCapacity.measure(points, resetsAt: nil))
        let hourly = try XCTUnwrap(FleetCapacity.measureHourly(points, resetsAt: nil, timeZone: utc))

        XCTAssertEqual(FleetCapacity.burn(over: hourly.buckets), span.burnPP, accuracy: 0.0001, """
            dropping the instantaneous step as zero-length loses the point it carries and the \
            buckets stop adding up to the span — live, that is 9 pp of acc2's 58
            """)
        XCTAssertEqual(hourly.buckets.reduce(0) { $0 + $1.hours }, 30, accuracy: 0.0001,
                       "and it buys no time: the series is 30 h long however many readings share an instant")
    }

    // MARK: - The window picks the estimator

    /// The boundary is a day, and it is pinned from both sides at the place it
    /// is written rather than wherever a comparison happens to land. Same
    /// fixture, same fleet, one hundredth of an hour apart.
    func testAWindowOfExactlyADayIsTheAverageAndAnythingUnderItIsTheProjection() throws {
        let flat = try shaped("main", rates: Array(repeating: 1.0, count: 24), days: 2)
        let accounts = try fleet(["main"])

        let atADay = try XCTUnwrap(FleetCapacity.load(histories: histories([flat]), accounts: accounts,
                                                      windowHours: 24, timeZone: utc))
        XCTAssertNil(atADay.projection, """
            24 h holds a whole sleep cycle, so the plain average over it is honest on its own and \
            the projection would be machinery for nothing
            """)

        let justUnder = try XCTUnwrap(FleetCapacity.load(histories: histories([flat]), accounts: accounts,
                                                         windowHours: 23.9, timeZone: utc))
        XCTAssertNotNil(justUnder.projection,
                        "23.9 h cannot hold one, and an average over it is a statement about part of a day")
    }

    /// With a window of a day or more the answer is what the estimator four
    /// reviews approved produces, to the point. The fixture is the one the
    /// window average's own suite reads at 126%, run through the new entry point:
    /// if the dispatch ever routes it anywhere else, this is what says so.
    func testAWindowOfADayOrMoreDoesNotDriftFromTheApprovedFigure() throws {
        let deep = try series("acc2", [(midnight, 0), (midnight.addingTimeInterval(48 * 3600), 48)])
        let shallow = try series("acc3", [(midnight, 10), (midnight.addingTimeInterval(24 * 3600), 22)])
        for window in [24.0, 48.0, 168.0] {
            let load = try XCTUnwrap(FleetCapacity.load(histories: histories([deep, shallow]),
                                                        accounts: try fleet(["acc2", "acc3"]),
                                                        windowHours: window, timeZone: utc))
            XCTAssertEqual(load.percent, 126, accuracy: 0.001, "at a window of \(window) h")
            XCTAssertEqual(load.measuredHours, 24, accuracy: 0.001)
            XCTAssertNil(load.projection)
        }
    }

    // MARK: - The day is split from the data

    /// The whole model in one fixture, and every number in it is arithmetic the
    /// reader can redo.
    ///
    /// Eight hours of the day at 4 pp/h and sixteen at 0.05 pp/h. The mean is
    /// (8 x 4 + 16 x 0.05) / 24 = 1.3667 pp/h, so the threshold is 0.615 and the
    /// eight busy hours are the work hours. Demand is then
    /// 4 x 8 x 7 + 0.05 x 16 x 7 = 224 + 5.6 = 229.6 pp against one account's
    /// 100 pp of capacity.
    func testDemandIsTheWorkHoursAtTheRecentRatePlusTheSleepingHoursAtTheirOwn() throws {
        var rates = Array(repeating: 0.05, count: 24)
        for hour in [0, 1, 18, 19, 20, 21, 22, 23] { rates[hour] = 4 }
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([try shaped("main", rates: rates, days: 2)]),
                                                    accounts: try fleet(["main"]),
                                                    windowHours: projecting, timeZone: utc))
        let projection = try XCTUnwrap(load.projection)

        XCTAssertEqual(projection.workHoursPerDay, 8, "the eight hours above 0.45 of the fleet's own mean")
        XCTAssertEqual(projection.sleepHoursPerDay, 16, "and the day has 24 hours in it")
        XCTAssertEqual(projection.recentWorkRate, 4, accuracy: 0.01,
                       "the recent work hours are busy ones, whatever the clock hours behind them were")
        XCTAssertEqual(projection.sleepRate, 0.05, accuracy: 0.005,
                       "the sleeping hours keep their own small rate rather than being read as zero")
        XCTAssertEqual(load.percent, 229.6, accuracy: 0.5, "4 x 8 x 7 + 0.05 x 16 x 7 against 100 pp")
        XCTAssertGreaterThanOrEqual(projection.recentWorkHours, 6,
                                    "the window asked for six work hours and got at least six")
    }

    /// The sleeping hours are paid for, not assumed away. Same fixture with the
    /// sleeping rate set to zero: demand loses exactly the 5.6 pp those hours
    /// were charged, and nothing else moves.
    func testTheSleepingHoursAreNotReadAsZero() throws {
        var busy = Array(repeating: 0.05, count: 24)
        for hour in [0, 1, 18, 19, 20, 21, 22, 23] { busy[hour] = 4 }
        var silent = Array(repeating: 0.0, count: 24)
        for hour in [0, 1, 18, 19, 20, 21, 22, 23] { silent[hour] = 4 }

        let withNights = try XCTUnwrap(FleetCapacity.load(
            histories: histories([try shaped("main", rates: busy, days: 2)]),
            accounts: try fleet(["main"]), windowHours: projecting, timeZone: utc))
        let withoutNights = try XCTUnwrap(FleetCapacity.load(
            histories: histories([try shaped("main", rates: silent, days: 2)]),
            accounts: try fleet(["main"]), windowHours: projecting, timeZone: utc))

        XCTAssertEqual(withNights.percent - withoutNights.percent, 5.6, accuracy: 0.3, """
            the sleeping hours are 5.6 pp of the week here; dropping them from the model would hide \
            spending that is really there — 0.129 pp/h over the live fleet, measured 2026-08-18
            """)
        XCTAssertEqual(try XCTUnwrap(withoutNights.projection).sleepRate, 0, accuracy: 0.0001)
    }

    /// **Work hours, not clock hours.** The series ends deep inside a sleeping
    /// stretch, so the last six *clock* hours hold no work at all and a rate
    /// taken over them would read zero every morning. Scanning back through the
    /// work hours reaches the busy evening and answers the rate that is there.
    func testTheRecentRateScansBackThroughWorkHoursRatherThanClockHours() throws {
        var rates = Array(repeating: 0.02, count: 24)
        for hour in 12...20 { rates[hour] = 5 }
        // Two whole days, then nine more hours: the series stops at 09:00, which
        // is the middle of the sleeping block.
        let step = 300.0
        var value = 0.0
        var readings: [(Date, Double?)] = [(midnight, 0)]
        for sample in 1...((48 + 9) * 12) {
            value += rates[(sample - 1) / 12 % 24] * step / 3600
            readings.append((midnight.addingTimeInterval(Double(sample) * step), value))
        }
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([try series("main", readings)]),
                                                    accounts: try fleet(["main"]),
                                                    windowHours: projecting, timeZone: utc))
        let projection = try XCTUnwrap(load.projection)
        XCTAssertEqual(projection.recentWorkRate, 5, accuracy: 0.01, """
            the last six clock hours are sleeping ones and hold 0.02 pp/h; asking for clock hours \
            makes the figure undefined every morning and zero every morning it is not
            """)
        XCTAssertGreaterThanOrEqual(projection.recentWorkHours, 6)
    }

    // MARK: - Refusals

    /// A series shorter than a day has not seen every hour of the day even once,
    /// and an hour nobody watched is not a sleeping hour. The control half is the
    /// same series at exactly a day, and it has to come back with an answer or
    /// this would pass on a function that refuses everything.
    func testASeriesShorterThanADayCannotBeSplitAndIsRefused() throws {
        let short = try series("main", [(midnight, 0), (midnight.addingTimeInterval(23 * 3600), 20)])
        XCTAssertNil(FleetCapacity.load(histories: histories([short]), accounts: try fleet(["main"]),
                                        windowHours: projecting, timeZone: utc),
                     "23 h cannot say what the fleet does at the hour it never saw")

        let day = try series("main", [(midnight, 0), (midnight.addingTimeInterval(24 * 3600), 20)])
        XCTAssertNotNil(FleetCapacity.load(histories: histories([day]), accounts: try fleet(["main"]),
                                           windowHours: projecting, timeZone: utc),
                        "the minimum is a floor to stand on, not a floor to fall through")
    }

    /// Fewer usable work hours than the floor is no figure rather than a noisy
    /// one: the rate carries one point of sawtooth spread over its window, which
    /// at two hours is 18.6 points of load on a three-account fleet — most of the
    /// width of the warning band the colour ramp spends 30 points on.
    ///
    /// Two work hours a day over one day is two usable work hours. The control
    /// half doubles the fixture's depth, which doubles the work hours available
    /// and nothing else.
    func testFewerUsableWorkHoursThanTheFloorIsRefused() throws {
        var rates = Array(repeating: 0.0, count: 24)
        rates[3] = 10
        rates[4] = 10
        XCTAssertNil(FleetCapacity.load(histories: histories([try shaped("main", rates: rates, days: 1)]),
                                        accounts: try fleet(["main"]),
                                        windowHours: projecting, timeZone: utc),
                     "two work hours is under the floor of \(FleetCapacity.minimumRecentWorkHours)")

        let deeper = try XCTUnwrap(FleetCapacity.load(histories: histories([try shaped("main", rates: rates, days: 2)]),
                                                      accounts: try fleet(["main"]),
                                                      windowHours: projecting, timeZone: utc))
        XCTAssertEqual(try XCTUnwrap(deeper.projection).recentWorkHours, 4, accuracy: 0.001,
                       "four work hours is the floor itself, and the floor is answerable")
    }

    /// The refusal `measure` makes over a span, made over a step. The series
    /// falls 3 pp across a hole — three times the sawtooth, so not jitter — and
    /// nothing places a window inside it. `max(0, …)` would serve that as a
    /// confident zero for an account that spent most of a window (§2.7).
    ///
    /// It is asked of the step and not of the hour on purpose: spread across the
    /// hours a long hole spans, a 3 pp fall is a fraction of a point in each of
    /// them and no hour would ever look wrong.
    func testAFallPastTheSawtoothWithNothingToPlaceItRefusesTheAccount() throws {
        let readings: [(Date, Double?)] = [
            (midnight, 20),
            (midnight.addingTimeInterval(20 * 3600), 95),
            (midnight.addingTimeInterval(28 * 3600), 92),
            (midnight.addingTimeInterval(48 * 3600), 96),
        ]
        XCTAssertNil(FleetCapacity.load(histories: histories([try series("main", readings)]),
                                        accounts: try fleet(["main"]),
                                        windowHours: projecting, timeZone: utc),
                     "a reset nobody saw and nothing can place is a missing figure, not zero burn")

        // The same series with the schedule placing a window boundary inside the
        // fall: one variable moved, so a failure here is about the schedule and
        // nothing else.
        let inside = midnight.addingTimeInterval((24 + 168) * 3600)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([try series("main", readings)]),
                                                    accounts: try fleet(["main"], sevenDayResetsAt: inside),
                                                    windowHours: projecting, timeZone: utc))
        XCTAssertNotNil(load.projection)
    }

    /// An account pinned at its ceiling for the whole series is not a fleet with
    /// no demand, it is a fleet nobody measured — and it leaves both halves of
    /// the fraction, exactly as it does on the other path. A ceiling on part of
    /// the series is the other thing and stays, with the `≥` on it.
    func testTheCeilingRulesHoldOnThisPathToo() throws {
        let pinned = try shaped("acc2", rates: Array(repeating: 0.0, count: 24), days: 2)
        var readings: [(Date, Double?)] = []
        for sample in 0...(48 * 12) {
            readings.append((midnight.addingTimeInterval(Double(sample) * 300),
                             sample < 12 ? 100 : Double(sample - 12) * 0.05))
        }
        XCTAssertNil(FleetCapacity.load(histories: histories([try series("acc2", (0...(48 * 12)).map {
            (midnight.addingTimeInterval(Double($0) * 300), 100)
        })]), accounts: try fleet(["acc2"]), windowHours: projecting, timeZone: utc),
                     "flat at the ceiling throughout is an account that served nothing it was asked for")
        XCTAssertNotNil(pinned, "fixture kept so the two shapes sit side by side")

        let partly = try XCTUnwrap(FleetCapacity.load(histories: histories([try series("acc2", readings)]),
                                                       accounts: try fleet(["acc2"]),
                                                       windowHours: projecting, timeZone: utc))
        XCTAssertTrue(partly.isLowerBound, "what an exhausted account turned away is not in its series")
    }

    // MARK: - The degenerate shapes

    /// A fleet that burns evenly around the clock has no sleeping hours, and then
    /// the projection is arithmetically the window average with a fresher rate:
    /// 1 pp/h over 24 work hours is 168 pp of demand against 100 pp of capacity.
    /// A flat profile is not an ambiguity to refuse, it is the answer.
    func testAFleetThatBurnsAroundTheClockHasNoSleepingHours() throws {
        let flat = try shaped("main", rates: Array(repeating: 1.0, count: 24), days: 2)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([flat]), accounts: try fleet(["main"]),
                                                    windowHours: projecting, timeZone: utc))
        let projection = try XCTUnwrap(load.projection)
        XCTAssertEqual(projection.workHoursPerDay, 24)
        XCTAssertEqual(projection.sleepHoursPerDay, 0)
        XCTAssertEqual(load.percent, 168, accuracy: 0.5, "1 pp/h x 168 h against one account's 100 pp")
    }

    /// A fleet that burned nothing has no work hours either — no hour clears a
    /// threshold of zero — and every hour is a sleeping hour at a rate of zero.
    /// That is a fleet at rest reading 0%, which is what it is, and not a
    /// refusal: `testAnIdleAccountJitteringDownDoesNotSubtractDemand` holds the
    /// same thing on the other path.
    func testAFleetAtRestReadsZeroRatherThanRefusing() throws {
        let idle = try shaped("main", rates: Array(repeating: 0.0, count: 24), days: 2)
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([idle]), accounts: try fleet(["main"]),
                                                    windowHours: projecting, timeZone: utc))
        XCTAssertEqual(load.percent, 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(load.projection).workHoursPerDay, 0)
    }

    /// The threshold is held where a measurement put it, by an hour that sits
    /// between the candidates.
    ///
    /// Eight hours at 4 pp/h, fifteen at 0.05 and one at 0.485 — which is 0.35 of
    /// this fixture's mean, above a quarter of it and below `workHourFraction`.
    /// So the quiet hour is a sleeping hour here and would be a working one at
    /// the fraction the first prototype used. The live measurement behind the
    /// choice is on the constant: 0.45 answers the same 15 work hours over the
    /// whole history and over the 48 h the app fetches, where a quarter answers
    /// 16 over both and sits one hundredth of the mean from flipping.
    func testTheWorkHourThresholdPutsAQuietHourWithTheSleepingOnes() throws {
        var rates = Array(repeating: 0.05, count: 24)
        for hour in [0, 1, 18, 19, 20, 21, 22, 23] { rates[hour] = 4 }
        rates[12] = 0.485
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([try shaped("main", rates: rates, days: 2)]),
                                                    accounts: try fleet(["main"]),
                                                    windowHours: projecting, timeZone: utc))
        XCTAssertEqual(try XCTUnwrap(load.projection).workHoursPerDay, 8, """
            0.485 pp/h is 0.35 of this fixture's mean: under \(FleetCapacity.self)'s threshold and \
            over a quarter of the mean, so the fraction is what decides it
            """)
    }

    /// A lagging sample beside a real reset is not a second window, on this path
    /// either: two falls over the threshold inside one series would otherwise be
    /// charged 200 pp where the account spent 15. The rule lives in
    /// `burn(over:)` and is the same clamp `measure` makes over a span.
    func testALaggingSampleBesideAResetIsNotASecondResetHereEither() throws {
        let readings: [(Date, Double?)] = [
            (midnight, 95),
            (midnight.addingTimeInterval(8 * 3600), 0),
            (midnight.addingTimeInterval(16 * 3600), 95),
            (midnight.addingTimeInterval(20 * 3600), 3),
            (midnight.addingTimeInterval(30 * 3600), 10),
        ]
        let points = try series("main", readings).points
        let hourly = try XCTUnwrap(FleetCapacity.measureHourly(points, resetsAt: nil, timeZone: utc))
        let span = try XCTUnwrap(FleetCapacity.measure(points, resetsAt: nil))
        XCTAssertEqual(span.burnPP, 15, accuracy: 0.0001, "the fixture the span method reads as 15 pp")
        XCTAssertEqual(FleetCapacity.burn(over: hourly.buckets), 15, accuracy: 0.0001, """
            counting both falls answers 115 pp for an account that could not have spent two \
            seven-day windows inside thirty hours
            """)
    }

    /// An account whose reading wobbles down by a point has not un-burned
    /// anything, and left signed its negative rate would make the rest of the
    /// fleet look cheaper. The same fixture the window average reads as 0%
    /// (`testAnIdleAccountJitteringDownDoesNotSubtractDemand`), cut into hours.
    func testAnIdleAccountJitteringDownDoesNotSubtractDemandHereEither() throws {
        var readings: [(Date, Double?)] = []
        for sample in 0...(30 * 12) {
            readings.append((midnight.addingTimeInterval(Double(sample) * 300),
                             sample == 30 * 12 ? 49 : 50))
        }
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([try series("main", readings)]),
                                                    accounts: try fleet(["main"]),
                                                    windowHours: projecting, timeZone: utc))
        XCTAssertEqual(load.percent, 0, accuracy: 0.0001, "a fleet at rest is 0% loaded, not below it")
    }

    // MARK: - Capacity over contributors

    /// Capacity counts the accounts that gave a rate and nobody else, on this
    /// path as on the other: an account with no usable history must not widen the
    /// denominator its own demand is missing from.
    func testCapacityCountsTheContributorsOnly() throws {
        var rates = Array(repeating: 0.05, count: 24)
        for hour in 18...23 { rates[hour] = 4 }
        let measured = try shaped("acc2", rates: rates, days: 2)
        let tooShort = try series("acc3", [(midnight, 0), (midnight.addingTimeInterval(6 * 3600), 5)])
        let load = try XCTUnwrap(FleetCapacity.load(histories: histories([measured, tooShort]),
                                                    accounts: try fleet(["acc2", "acc3", "main"]),
                                                    windowHours: projecting, timeZone: utc))
        XCTAssertEqual(load.accounts, 1, "acc3 has six hours and main has none: neither is a supply we can count")

        let both = try XCTUnwrap(FleetCapacity.load(
            histories: histories([measured, try shaped("acc3", rates: rates, days: 2)]),
            accounts: try fleet(["acc2", "acc3"]), windowHours: projecting, timeZone: utc))
        XCTAssertEqual(both.accounts, 2)
        XCTAssertEqual(both.percent, load.percent, accuracy: 0.5, """
            two identical accounts double both halves of the fraction, so the load is the same — \
            which is what says capacity followed the contributors rather than the account list
            """)
    }
}
