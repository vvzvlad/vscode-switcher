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

    /// The accounts do not have the same depth of history — 2.59 / 2.29 / 2.59
    /// days live on 2026-08-17, because the gateway cuts one of them at
    /// `max_points`. A rate per account, then summed; dividing one total by the
    /// longest span would credit the shallow account with hours nobody measured
    /// it over.
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
    /// interval blocked, and it leaves both halves of the fraction: on the live
    /// fleet that moves the answer up by about 70 points.
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
    }
}
