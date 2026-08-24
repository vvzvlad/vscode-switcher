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
/// is `measure`'s, so the fixtures are unchanged and the question is asked one
/// step closer to where it is answered — a one-account fleet's `percent` was only
/// ever `burnPP` multiplied and divided back again.
///
/// **And `measure` is not on the app's path any more either.** Its reader is
/// `FleetCapacityProjectionTests.testHourBucketsReconcileWithTheSpanMethod`: the
/// hour-by-hour decomposition everything else stands on has to add back up to
/// this, and this is the only thing it can be checked against. The guards below
/// all live twice — once here over a span, once in `hourBuckets` over each step —
/// and the tests that the *app* runs through are the ones in the two classes
/// after this.
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
    /// What it catches is the `+ 100` per reset going missing; what it cannot
    /// catch is the endpoint rule being replaced by a sum of positive deltas —
    /// over this fixture that sum is 25 + 25, the same 50 — and the test above
    /// is the only one that can.
    func testAResetInsideTheIntervalIsAHundredPointsRestored() throws {
        let series = try history("main", [100, 100, 0, 25, 50], overHours: 48)
        XCTAssertEqual(try burnedPP(series), 50, accuracy: 0.001,
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
        XCTAssertEqual(try burnedPP(series), 120, accuracy: 0.001, """
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
        XCTAssertEqual(try burnedPP(series), 15, accuracy: 0.001, """
            10 − 95 over the interval plus the one window that turned over inside it; counting the \
            lagging sample as a second reset answers 115 pp for an account that burned about 15
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
        XCTAssertEqual(try burnedPP(series), 75, accuracy: 0.001, """
            20 − 45 over the interval plus the window that turned over inside it; a threshold too \
            high to see this fall does not answer 25 pp or 0, it refuses the account outright
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
        XCTAssertEqual(try burnedPP(series), 5, accuracy: 0.001,
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
    /// and rises — but the boundary still sits minutes before the first reading.
    ///
    /// Replayed from acc2 on 2026-08-17 (boundary 2026-08-15 21:00:00Z, first
    /// post-reset reading 285 s later, 52 by the end): asking the schedule
    /// without asking the readings answered 152 pp instead of 52. It is not a
    /// rare alignment either — every account passes through it for the quarter of
    /// an hour a week its boundary spends inside the old tolerance.
    func testAScheduleBoundaryBeforeARisingSeriesIsNotAHiddenReset() throws {
        let afterTheReset = try history("acc2", [0, 12, 25, 40, 52], overHours: 48)
        let boundaryJustBefore = seriesStart.addingTimeInterval(168 * 3600 - 5 * 60)
        XCTAssertEqual(try burnedPP(afterTheReset, resetsAt: boundaryJustBefore), 52, accuracy: 0.001, """
            the series starts at zero and climbs: the window turned over before the interval opened, \
            not inside it, and charging it again answers 152 pp for an account that spent 52
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
    /// The floor is `measure`'s own and no longer anything the app can reach:
    /// what the app runs is `measureHourly`, whose floor is a whole day. The
    /// reasoning that chose six hours is on the constant, along with that.
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
    /// What it costs a fleet is the allowance's own test
    /// (`testAnAccountPinnedAtItsCeilingContributesNeitherAllowanceNorCapacity`);
    /// what is held here is that the refusal is in the burn rule itself, on both
    /// paths through a series.
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
}

/// The hour-by-hour decomposition of a series, and the split of the day it
/// feeds.
///
/// The first section is the one everything else stands on. A per-hour
/// decomposition that does not add back up to the span method is not a finer
/// view of the same burn, it is a second and disagreeing answer — and the first
/// prototype of this disagreed by a whole restored window on the one account
/// whose history crossed a reset.
///
/// **The demand estimator these were written for is gone**, so every test that
/// asked it something asks `sustainable` instead — the one reader the buckets
/// and the split have left. What went with the estimator went for good: the
/// arithmetic that turned a rate into a week's demand, the recent-work-hour
/// window it took that rate over, and the boundary that chose between two ways
/// of estimating. The rules underneath are all still here, one caller along.
final class FleetCapacityDecompositionTests: XCTestCase {

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

    /// A spend big enough to price a point by. Nothing here reads the allowance
    /// itself — these tests ask the split and the refusals — so the figure only
    /// has to be above zero.
    private let spend: Double = 1_000_000

    // MARK: - The decomposition reconciles with the span method

    /// **The invariant the whole projection rests on.** Summing the hour buckets
    /// over a contiguous stretch must reproduce what `measure` answers for the
    /// same stretch — the endpoints plus a window per reset, which is the method
    /// three reviews approved.
    ///
    /// The three fixtures are the three ways a reset can sit against the grid —
    /// wholly inside one hour, ending exactly on an hour boundary, and straddling
    /// one — and the second is the one that broke the prototype. This header said
    /// "two" for one round after the third fixture was added under it; the
    /// comment inside the function, §2.7 and the memo all said three. Measured
    /// against the live
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

        // Three ways a reset can sit against the grid, and the third is the one
        // that makes this test earn its name. `phantom` is what the naive reading
        // gets wrong on each: the two boundary cases are where the whole restored
        // window appears out of nothing, and the inside case is the one it
        // survives — which is exactly the shape of the live disagreement, acc2
        // and acc3 out by a point each and main out by 101.
        //
        // The difference between the second and the third is the whole of the
        // attribution rule. In the second the fall *ends* on the hour, so the
        // step lies inside one hour and a pro-rata split would put every part of
        // it in that same hour — which is why that fixture cannot tell whole
        // attribution from spreading, and why the claim that it held both cases
        // was wrong. In the third the fall straddles 10:00 with readings either
        // side of it, so spreading has something to spread and the rule is
        // exercised.
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
            ("a reset step across a bucket boundary", (0..<(30 * 12)).map { sample in
                let at = midnight.addingTimeInterval(Double(sample) * 300)
                // 99 at 09:50:00 and 0 at 10:10:00, with the samples between them
                // measuring nothing: the fall is one step and 10:00 falls inside
                // it.
                if sample > 118 && sample < 122 { return (at, nil) }
                let value: Double = sample < 120 ? min(99, Double(sample) * 0.9) : Double(sample - 122) * 0.1
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
            // decomposition. **Exactly, when the stretch's own edges fall on
            // readings**, and in these fixtures they always do — the samples are
            // five minutes apart and start on the hour, so every boundary is a
            // sample.
            //
            // An edge falling *inside* a step is where the two methods part, and
            // it parts two different ways. A **reset** step is charged whole to
            // the hour its fall began in, so the stretch holding that hour
            // carries the entire −99 and 100 while the endpoint method, stopping
            // at the last reading before the edge, has not seen the fall at all:
            // the divergence is that step's whole burn. An **ordinary** step is
            // spread pro rata, so the stretch carries only the part of the change
            // that fell inside it, and the divergence is that part rather than
            // the whole. Only the first shape can occur here — the fixtures are
            // aligned, and the third one widens its reset step on purpose so that
            // a boundary lands inside it — which is exactly 1 pp on the stretch
            // ending at 10:00. Live it is the ordinary shape that is the common
            // one: over the 48 h the app fetches on 2026-08-18, 1 hour boundary
            // out of 48 / 45 / 48 landed on a reading, 46 / 44 / 47 fell inside
            // an ordinary step and 1 (main) inside a reset step.
            let readings: [(at: Date, value: Double)] = points.compactMap { point in
                point.sevenDay.map { (at: point.timestamp, value: $0) }
            }
            /// The burn of the reset step an instant falls strictly inside, when
            /// that step began at or after `from` — which is when the bucket the
            /// step was charged to is one of the stretch's own.
            ///
            /// **It models the reset case only, and that is correct only for
            /// these fixtures.** An ordinary step containing the edge diverges
            /// too, by the pro-rata part of its change the buckets charged inside
            /// the stretch; here no ordinary step can contain a boundary, because
            /// the samples are five minutes apart and start on the hour. Move the
            /// sampling off the grid and this helper starts returning 0 for a
            /// divergence that is really there, and the assertion below fails
            /// with a number rather than telling anyone why.
            func straddled(_ edge: Date, notBefore from: Date) -> Double {
                for (previous, next) in zip(readings, readings.dropFirst())
                where previous.at < edge && next.at > edge && previous.at >= from
                    && previous.value - next.value > FleetCapacity.resetDropThreshold {
                    return next.value - previous.value + 100
                }
                return 0
            }
            var straddledStretches = 0
            for start in stride(from: 0, to: hourly.buckets.count - 4, by: 5) {
                let stretch = Array(hourly.buckets[start..<min(start + 5, hourly.buckets.count)])
                let from = stretch[0].start
                let to = stretch[stretch.count - 1].start.addingTimeInterval(3600)
                let inside = points.filter { $0.timestamp >= from && $0.timestamp <= to }
                    .compactMap(\.sevenDay)
                guard let first = inside.first, let last = inside.last, inside.count > 1 else { continue }
                let resets = zip(inside, inside.dropFirst())
                    .filter { $0 - $1 > FleetCapacity.resetDropThreshold }.count
                let carried = straddled(to, notBefore: from)
                if carried != 0 { straddledStretches += 1 }
                XCTAssertEqual(FleetCapacity.burn(over: stretch),
                               last - first + 100 * Double(min(resets, 1)) + carried,
                               accuracy: 0.0001,
                               "\(name): hours \(start)…\(start + 5) do not add up to their own "
                               + "endpoints (a step straddling the edge is worth \(carried) pp)")
            }
            XCTAssertEqual(straddledStretches, name.hasSuffix("across a bucket boundary") ? 1 : 0, """
                \(name): the fixture has to put a step across a stretch edge exactly where the \
                qualification says it can, or the qualification is untested
                """)
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

    // MARK: - The day is split from the data

    /// The sleeping hours are paid for, not assumed away. Same fixture with the
    /// sleeping rate set to zero: the week keeps exactly the 5.6 pp those hours
    /// were charged, and a working hour is allowed more because of it.
    func testTheSleepingHoursAreNotReadAsZero() throws {
        var busy = Array(repeating: 0.05, count: 24)
        for hour in [0, 1, 18, 19, 20, 21, 22, 23] { busy[hour] = 4 }
        var silent = Array(repeating: 0.0, count: 24)
        for hour in [0, 1, 18, 19, 20, 21, 22, 23] { silent[hour] = 4 }

        let withNights = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try shaped("main", rates: busy, days: 2)]),
            accounts: try fleet(["main"]), spentTokens: spend, timeZone: utc))
        let withoutNights = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try shaped("main", rates: silent, days: 2)]),
            accounts: try fleet(["main"]), spentTokens: spend, timeZone: utc))

        XCTAssertEqual(withNights.sleepRate, 0.05, accuracy: 0.005,
                       "the sleeping hours keep their own small rate rather than being read as zero")
        XCTAssertEqual(withoutNights.sleepRate, 0, accuracy: 0.0001)
        // 0.05 x 16 x 7 = 5.6 pp of the week goes to the nights, and what is left
        // is spread over 8 x 7 = 56 working hours.
        XCTAssertEqual(withoutNights.allowedWorkRate - withNights.allowedWorkRate,
                       5.6 / 56, accuracy: 0.001, """
            dropping the sleeping hours from the model would hand a working hour spending that is \
            really happening at night — 0.350 pp/h over the live fleet, measured 2026-08-18
            """)
    }

    // MARK: - Refusals

    /// A series shorter than a day has not seen every hour of the day even once,
    /// and an hour nobody watched is not a sleeping hour. The control half is the
    /// same series at exactly a day, and it has to come back with an answer or
    /// this would pass on a function that refuses everything.
    func testASeriesShorterThanADayCannotBeSplitAndIsRefused() throws {
        let short = try series("main", [(midnight, 0), (midnight.addingTimeInterval(23 * 3600), 20)])
        XCTAssertNil(FleetCapacity.sustainable(histories: histories([short]),
                                               accounts: try fleet(["main"]),
                                               spentTokens: spend, timeZone: utc),
                     "23 h cannot say what the fleet does at the hour it never saw")

        let day = try series("main", [(midnight, 0), (midnight.addingTimeInterval(24 * 3600), 20)])
        XCTAssertNotNil(FleetCapacity.sustainable(histories: histories([day]),
                                                  accounts: try fleet(["main"]),
                                                  spentTokens: spend, timeZone: utc),
                        "the minimum is a floor to stand on, not a floor to fall through")
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
        XCTAssertNil(FleetCapacity.sustainable(histories: histories([try series("main", readings)]),
                                               accounts: try fleet(["main"]),
                                               spentTokens: spend, timeZone: utc),
                     "a reset nobody saw and nothing can place is a missing figure, not zero burn")

        // The same series with the schedule placing a window boundary inside the
        // fall: one variable moved, so a failure here is about the schedule and
        // nothing else.
        let inside = midnight.addingTimeInterval((24 + 168) * 3600)
        XCTAssertNotNil(FleetCapacity.sustainable(
            histories: histories([try series("main", readings)]),
            accounts: try fleet(["main"], sevenDayResetsAt: inside),
            spentTokens: spend, timeZone: utc))
    }

    /// An account pinned at its ceiling for the whole series is not a fleet that
    /// spent nothing, it is a fleet nobody measured — and it leaves both halves of
    /// the fraction. A ceiling on *part* of the series is the other thing and
    /// stays, with the `≥` on it: the points it was blocked from burning are
    /// missing from the price of a point, so the allowance came out too generous
    /// and everything drawn against it is a floor.
    ///
    /// **The flag is `SustainableRate`'s now**, and it used to be the demand
    /// estimate's. Where it goes on screen is the menu bar's accessibility
    /// description and `--dump`, both of which write the ratio out as a number —
    /// a colour cannot carry a `≥`, and no other surface prints this figure.
    func testTheCeilingRulesHoldOnThisPathToo() throws {
        var readings: [(Date, Double?)] = []
        for sample in 0...(48 * 12) {
            readings.append((midnight.addingTimeInterval(Double(sample) * 300),
                             sample < 12 ? 100 : Double(sample - 12) * 0.05))
        }
        var pinned: [(Date, Double?)] = []
        for sample in 0...(48 * 12) {
            pinned.append((midnight.addingTimeInterval(Double(sample) * 300), 100))
        }
        XCTAssertNil(FleetCapacity.sustainable(histories: histories([try series("acc2", pinned)]),
                                               accounts: try fleet(["acc2"]),
                                               spentTokens: spend, timeZone: utc),
                     "flat at the ceiling throughout is an account that served nothing it was asked for")

        let partly = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try series("acc2", readings)]),
            accounts: try fleet(["acc2"]), spentTokens: spend, timeZone: utc))
        XCTAssertTrue(partly.isLowerBound,
                      "what an exhausted account was blocked from burning is not in its series, "
                      + "so the price of a point reads high and the allowance with it")

        // The seed of the same flag, and only a series whose *first* reading is
        // the ceiling can tell it from the loop: an account that entered the
        // window exhausted, reset out of it and never came near 100 again.
        var fromTheCeiling: [(Date, Double?)] = [(midnight, 100)]
        for sample in 1...(48 * 12) {
            fromTheCeiling.append((midnight.addingTimeInterval(Double(sample) * 300),
                                   Double(sample) * 0.05))
        }
        XCTAssertTrue(try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try series("acc2", fromTheCeiling)]),
            accounts: try fleet(["acc2"]), spentTokens: spend, timeZone: utc)).isLowerBound, """
            the account was at its ceiling when the window opened, and what it was blocked from \
            burning then is missing from the measurement exactly as much as a ceiling in the middle
            """)

        // And an account that never touched its ceiling served everything it was
        // asked for: the figure is the figure. 99 is not the ceiling.
        var clear: [(Date, Double?)] = []
        for sample in 0...(48 * 12) {
            clear.append((midnight.addingTimeInterval(Double(sample) * 300),
                          50 + Double(sample) * 0.08))
        }
        XCTAssertFalse(try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try series("acc2", clear)]), accounts: try fleet(["acc2"]),
            spentTokens: spend, timeZone: utc)).isLowerBound,
                       "nothing was turned away, so nothing is a floor")
    }

    // MARK: - The degenerate shapes

    /// A fleet that burns evenly around the clock has no sleeping hours, and then
    /// the whole week is working hours: 100 pp spread over 24 x 7 of them.
    /// A flat profile is not an ambiguity to refuse, it is the answer.
    func testAFleetThatBurnsAroundTheClockHasNoSleepingHours() throws {
        let flat = try shaped("main", rates: Array(repeating: 1.0, count: 24), days: 2)
        let answer = try XCTUnwrap(FleetCapacity.sustainable(histories: histories([flat]),
                                                             accounts: try fleet(["main"]),
                                                             spentTokens: spend, timeZone: utc))
        XCTAssertEqual(answer.workHoursPerDay, 24)
        XCTAssertEqual(answer.sleepHoursPerDay, 0)
        XCTAssertEqual(answer.sleepRate, 0, "there are no sleeping hours to have a rate")
        XCTAssertEqual(answer.allowedWorkRate, 100.0 / 168, accuracy: 0.0001,
                       "nothing is taken out for the nights, so the whole window is the week's")
    }

    /// The threshold is held where a measurement put it, by an hour that sits
    /// between the candidates.
    ///
    /// Eight hours at 4 pp/h, fifteen at 0.05 and one at 0.485 — which is 0.35 of
    /// this fixture's mean, above a quarter of it and below `workHourFraction`.
    /// So the quiet hour is a sleeping hour here and would be a working one at
    /// the fraction the first prototype used. What the live measurement behind
    /// the choice actually says is on the constant, and it is not what this
    /// comment used to claim: today's history answers **14** work hours at 0.45
    /// and no fraction at all answers 15, the count stepping 16 → 14 because two
    /// hours share a rate. The fraction stays because every alternative measured
    /// moves the answer more across sub-windows, not because a plateau holds it.
    func testTheWorkHourThresholdPutsAQuietHourWithTheSleepingOnes() throws {
        var rates = Array(repeating: 0.05, count: 24)
        for hour in [0, 1, 18, 19, 20, 21, 22, 23] { rates[hour] = 4 }
        rates[12] = 0.485
        let answer = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try shaped("main", rates: rates, days: 2)]),
            accounts: try fleet(["main"]), spentTokens: spend, timeZone: utc))
        XCTAssertEqual(answer.workHoursPerDay, 8, """
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

    /// **A class of hours that nets downwards burns at zero, not below it.** The
    /// buckets carry the ±1 sawtooth signed — that is what makes them telescope —
    /// so a stretch of quiet hours can add up to a negative change, and a rate
    /// left signed there would *widen* what a working hour is allowed. That is
    /// the unsafe direction: the fleet would be told it may spend more because
    /// one of its readings wobbled.
    ///
    /// The fixture works twelve hours a day at 4 pp/h and spends the other twelve
    /// asleep, dropping a point a day and never recovering it: −2 pp over the two
    /// days across every sleeping bucket. The clamp inside `rate(over:)` is what
    /// turns that into 0.000 pp/h, and with it the nights take nothing out of the
    /// week — `allowedWorkRate` is exactly 100 pp over 12 x 7 working hours.
    /// Unclamped the same fixture pays the nights −7 pp of the week and hands a
    /// working hour 1.274 pp/h instead of 1.190.
    ///
    /// Asked through `sustainable` rather than of the clamp directly, because
    /// that is where the number goes: `rate(over:)` is private, and a test that
    /// reached past the reader would be checking arithmetic nobody consumes.
    func testAClassOfHoursThatNetsDownwardsBurnsAtZero() throws {
        var value = 0.0
        var readings: [(Date, Double?)] = [(midnight, 0)]
        for sample in 1...(48 * 12) {
            let hour = (sample - 1) / 12 % 24
            if hour >= 12 {
                value += 4 * 300 / 3600
            } else if hour == 6, (sample - 1) % 12 == 0 {
                // One step down a day, inside the sawtooth and so not a reset.
                value -= 1
            }
            readings.append((midnight.addingTimeInterval(Double(sample) * 300), value))
        }
        let answer = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try series("main", readings)]),
            accounts: try fleet(["main"]), spentTokens: spend, timeZone: utc))
        XCTAssertEqual(answer.workHoursPerDay, 12, "the fixture is not the day it was meant to be")
        XCTAssertEqual(answer.sleepRate, 0, accuracy: 0.0001,
                       "the sleeping hours net −2 pp; signed, they would give the week 7 pp back")
        XCTAssertEqual(answer.allowedWorkRate, 100.0 / (12 * 7), accuracy: 0.0001,
                       "a wobble downwards widened what a working hour may spend")
    }


}

/// The allowance: what the fleet may spend an hour of work and still have the
/// week last, in the same unit the gateway reports spending in.
///
/// The arithmetic is a chain — points burned, tokens spent, the price of a
/// point, the day split into work and sleep, and what a working hour is left
/// with — and every link can fail on its own. The refusals are half of this
/// file, and each of them is reached by a series that satisfies every link but
/// one.
final class FleetCapacityAllowanceTests: XCTestCase {

    // MARK: - Fixtures

    /// 2026-08-14 00:00:00 UTC, midnight so the hour buckets line up with the
    /// numbers in the fixtures. The same instant and the same zone the
    /// projection's tests use, and for the same reason.
    private let midnight = Date(timeIntervalSince1970: 1_786_665_600)
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func series(_ label: String, _ readings: [(Date, Double?)]) throws -> HistorySeries {
        let points = readings.map { at, value in
            "{\"ts\": \(at.timeIntervalSince1970), \"util_7d\": \(value.map { "\($0)" } ?? "null")}"
        }
        return try UsageFixtures.decode("""
        {"label": "\(label)", "since": \(midnight.timeIntervalSince1970), \
        "points": [\(points.joined(separator: ","))]}
        """, as: HistorySeries.self)
    }

    /// A series shaped like a day, exactly as the projection's fixtures are
    /// shaped: 24 hourly rates in pp/h, climbed at one sample every five
    /// minutes.
    private func shaped(_ label: String, rates: [Double], days: Int) throws -> HistorySeries {
        let step = 300.0
        var value = 0.0
        var readings: [(Date, Double?)] = [(midnight, 0)]
        for sample in 1...(days * 24 * 12) {
            value += rates[(sample - 1) / 12 % 24] * step / 3600
            readings.append((midnight.addingTimeInterval(Double(sample) * step), value))
        }
        return try series(label, readings)
    }

    private func fleet(_ labels: [String]) throws -> [AccountUsage] {
        let body = labels.map { "\"\($0)\": {}" }.joined(separator: ",")
        return try UsageFixtures.decode("{\"accounts\": {\(body)}}", as: UsageReport.self).accounts
    }

    private func histories(_ all: [HistorySeries]) -> [String: HistorySeries] {
        Dictionary(uniqueKeysWithValues: all.map { ($0.label, $0) })
    }

    /// The day every test here works from: eight hours at 4 pp/h and sixteen at
    /// 0.05, which is the projection's own fixture. The mean is 1.3667 pp/h, the
    /// threshold 0.615, and the eight busy hours are the work hours.
    private func workingDay(_ label: String = "main", sleeping: Double = 0.05,
                            working: Double = 4, days: Int = 2) throws -> HistorySeries {
        var rates = Array(repeating: sleeping, count: 24)
        for hour in [0, 1, 18, 19, 20, 21, 22, 23] { rates[hour] = working }
        return try shaped(label, rates: rates, days: days)
    }

    /// The tokens that make one point cost exactly a million over the standard
    /// fixture: it burns 2 x (8 x 4 + 16 x 0.05) = 65.6 pp over its two days.
    private let tokensForAMillionAPoint = 65_600_000.0

    // MARK: - The allowance itself

    /// The whole chain in one fixture, every number redoable on paper.
    ///
    /// 65.6 pp burned and 65.6M tokens spent make a point cost 1.000M. The
    /// sleeping hours take 0.05 x 16 x 7 = 5.6 pp of the week, so 94.4 pp are
    /// left for 8 x 7 = 56 working hours: 1.6857 pp/h, which at a million a
    /// point is 1,685,714 tokens an hour.
    func testTheAllowanceIsWhatTheSleepingHoursLeaveSpreadOverTheWorkingOnes() throws {
        let answer = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try workingDay()]), accounts: try fleet(["main"]),
            spentTokens: tokensForAMillionAPoint, timeZone: utc))

        XCTAssertEqual(answer.tokensPerPoint, 1_000_000, accuracy: 100,
                       "65.6M tokens over the 65.6 pp they cost")
        XCTAssertEqual(answer.workHoursPerDay, 8, "the eight hours above 0.45 of the fleet's own mean")
        XCTAssertEqual(answer.sleepHoursPerDay, 16, "and the day has 24 hours in it")
        XCTAssertEqual(answer.sleepRate, 0.05, accuracy: 0.005,
                       "the sleeping hours keep their own rate rather than being read as zero")
        XCTAssertEqual(answer.allowedWorkRate, 1.6857, accuracy: 0.001, "(100 − 5.6) / 56")
        XCTAssertEqual(answer.tokensPerHour, 1_685_714, accuracy: 500, "1.6857 pp/h at a million a point")
        XCTAssertEqual(answer.accounts, 1)
        XCTAssertEqual(answer.measuredHours, 48, accuracy: 0.1)
    }

    /// **It is the working rate and never the flat weekly average**, and the
    /// difference is the whole reason this is not one division.
    ///
    /// What the allowance is compared against is measured over five minutes,
    /// which is to say while somebody is working. Spread the same capacity over
    /// all 168 hours of the week and this fixture would allow 595k tokens an
    /// hour — so a fleet working at its true sustainable rate would read 283% and
    /// every healthy working day would look like an overrun. That is the reading
    /// this project already threw the gateway's own `pace` away for (§2.7).
    func testTheAllowanceIsNotTheCapacitySpreadOverTheWholeWeek() throws {
        let answer = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try workingDay()]), accounts: try fleet(["main"]),
            spentTokens: tokensForAMillionAPoint, timeZone: utc))
        let flat = 100.0 / 168 * answer.tokensPerPoint

        XCTAssertEqual(flat, 595_238, accuracy: 500, "capacity over every hour of the week")
        XCTAssertEqual(answer.tokensPerHour / flat, 2.83, accuracy: 0.05, """
            the working hours carry the week, so an hour of work is allowed nearly three times what \
            an hour of the week averages to — and against a rate measured while somebody works, the \
            flat figure calls a healthy day an overrun
            """)
    }

    /// The exchange rate is the window's tokens over the window's points and
    /// nothing else: twice the tokens for the same burn is twice the allowance.
    ///
    /// It is the one link in the chain that comes from outside the histories,
    /// and a fixture that never varied it would pass on an allowance that
    /// ignored the tokens altogether.
    func testTheAllowanceScalesWithWhatAPointCosts() throws {
        func allowance(spending tokens: Double) throws -> Double {
            try XCTUnwrap(FleetCapacity.sustainable(
                histories: histories([try workingDay()]), accounts: try fleet(["main"]),
                spentTokens: tokens, timeZone: utc)).tokensPerHour
        }
        XCTAssertEqual(try allowance(spending: 2 * tokensForAMillionAPoint),
                       2 * (try allowance(spending: tokensForAMillionAPoint)), accuracy: 1, """
            the same week's quota buys half as many hours when an hour costs twice as much — the \
            allowance is a price, and the price is measured rather than assumed
            """)
    }

    /// The sleeping hours are paid before the working ones are allowed anything.
    /// Same shape, a sleeping rate ten times higher: 8.4 pp more of the week goes
    /// to the nights, and the working hours are allowed exactly that much less.
    func testTheSleepingHoursAreTakenOutOfTheWeekBeforeTheWorkingOnesAreAllowed() throws {
        let quiet = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try workingDay(sleeping: 0.05)]), accounts: try fleet(["main"]),
            spentTokens: tokensForAMillionAPoint, timeZone: utc))
        let noisy = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try workingDay(sleeping: 0.5)]), accounts: try fleet(["main"]),
            spentTokens: tokensForAMillionAPoint, timeZone: utc))

        XCTAssertEqual(noisy.workHoursPerDay, 8, "the split has not moved, so only the sleeping bill has")
        XCTAssertLessThan(noisy.allowedWorkRate, quiet.allowedWorkRate, """
            background agents spend at night, and a week that ignored them would allow the day \
            hours a budget the nights have already taken
            """)
        XCTAssertEqual(quiet.allowedWorkRate - noisy.allowedWorkRate, (0.5 - 0.05) * 16 * 7 / 56,
                       accuracy: 0.001, "the extra nightly spend, spread over the week's work hours")
    }

    /// Capacity counts the accounts that could be measured and nobody else, the
    /// rule both estimators follow: a second identical account doubles capacity,
    /// doubles the points burned and doubles the tokens, so the allowance per
    /// hour of the fleet's work doubles with it.
    func testCapacityCountsTheContributorsOnly() throws {
        let one = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try workingDay("acc2")]), accounts: try fleet(["acc2", "acc3"]),
            spentTokens: tokensForAMillionAPoint, timeZone: utc))
        XCTAssertEqual(one.accounts, 1, "acc3 sent no history: it is not a supply anybody can count")

        let two = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try workingDay("acc2"), try workingDay("acc3")]),
            accounts: try fleet(["acc2", "acc3"]),
            spentTokens: 2 * tokensForAMillionAPoint, timeZone: utc))
        XCTAssertEqual(two.accounts, 2)
        XCTAssertEqual(two.tokensPerHour, 2 * one.tokensPerHour, accuracy: 1, """
            two accounts hold two weeks' quota and their work is spread over the same hours of the \
            day, so the fleet may work twice as fast — the figure follows the contributors
            """)
    }

    /// **A rate per account, then summed — never one total over one span.** The
    /// accounts are watched over different depths (2.16 / 2.18 / 2.74 days over
    /// acc2 / acc3 / main, live 2026-08-17), so dividing one total by the longest
    /// of them credits the shallow account with hours nobody measured it over.
    ///
    /// The fixture is two identical days, one account watched for two of them and
    /// one for one. Both sleep at 0.05 pp/h, so the fleet sleeps at 0.100; a
    /// single total over the deeper account's 32 sleeping hours answers 0.075,
    /// and the whole shape of the rule is the difference between those two.
    func testTheSleepingRateIsSummedPerAccountRatherThanDividedByTheLongestSpan() throws {
        let answer = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try workingDay("acc2", days: 2), try workingDay("acc3", days: 1)]),
            accounts: try fleet(["acc2", "acc3"]),
            spentTokens: tokensForAMillionAPoint, timeZone: utc))

        XCTAssertEqual(answer.accounts, 2)
        XCTAssertEqual(answer.sleepRate, 0.100, accuracy: 0.002, """
            one total over the deeper account's span answers 0.075 pp/h, which is the shallow \
            account measured over hours it was never measured over
            """)
        XCTAssertEqual(answer.measuredHours, 24, accuracy: 0.001,
                       "the answer is as well measured as its worst-measured contributor")
    }

    /// A fleet with no accounts at all is not a fleet spending nothing, and the
    /// tokens beside it do not make one: there is nothing to price them against.
    func testAFleetWithNoAccountsHasNoAllowance() {
        XCTAssertNil(FleetCapacity.sustainable(histories: [:], accounts: [],
                                               spentTokens: tokensForAMillionAPoint, timeZone: utc))
    }

    /// Membership comes from the account list and not from whatever histories are
    /// lying around: a series under a label the fleet does not have is not
    /// capacity anybody can spend.
    func testAHistoryUnderALabelTheFleetDoesNotHaveIsNotCapacity() throws {
        let ghost = try workingDay("retired")
        XCTAssertNil(FleetCapacity.sustainable(histories: histories([ghost]),
                                               accounts: try fleet(["acc2"]),
                                               spentTokens: tokensForAMillionAPoint, timeZone: utc),
                     "a retired account's series was counted as a live account's capacity")
    }

    // MARK: - Refusals

    /// A series shorter than a day cannot be split into work and sleep, so it
    /// contributes neither an allowance nor its 100 pp of capacity — the same
    /// refusal the projection makes, for the same reason: an hour nobody watched
    /// is not a sleeping hour.
    func testAnAccountWithoutAWholeDayOfHistoryIsRefused() throws {
        let short = try series("main", [(midnight, 0), (midnight.addingTimeInterval(23 * 3600), 20)])
        XCTAssertNil(FleetCapacity.sustainable(histories: histories([short]), accounts: try fleet(["main"]),
                                               spentTokens: tokensForAMillionAPoint, timeZone: utc),
                     "23 h has not seen the hour it never watched")

        let day = try series("main", [(midnight, 0), (midnight.addingTimeInterval(24 * 3600), 20)])
        XCTAssertNotNil(FleetCapacity.sustainable(histories: histories([day]), accounts: try fleet(["main"]),
                                                  spentTokens: tokensForAMillionAPoint, timeZone: utc),
                        "the minimum is a floor to stand on, not one to fall through")
    }

    /// **A fleet at rest has no allowance**, and that is a different answer from
    /// the projection's, which reads such a fleet as 0% loaded. The question here
    /// is what an hour of work may cost, and a fleet that has not worked has not
    /// said. Answering the flat weekly average instead would be exactly the
    /// comparison this figure exists to avoid.
    func testAFleetAtRestHasNoAllowance() throws {
        let idle = try shaped("main", rates: Array(repeating: 0, count: 24), days: 2)
        XCTAssertNil(FleetCapacity.sustainable(histories: histories([idle]), accounts: try fleet(["main"]),
                                               spentTokens: tokensForAMillionAPoint, timeZone: utc),
                     "nothing burned is nothing to price an hour of work by")
    }

    /// **The invariant that keeps the week of work hours from being zero hours
    /// long**, and the reason there is no separate guard for it.
    ///
    /// A fleet that burned something always has at least one working hour: the
    /// threshold is a fraction of the fleet's own rate, so an hour clears it
    /// whenever that rate is above zero — and the rate is above zero exactly when
    /// the burn is, both being the same clamped sum over the same buckets. A
    /// guard asking it a second time was written and taken back out, because no
    /// series reaches it and a branch that cannot execute is not a safeguard.
    /// This is what stands in its place, and it is asked over every shape this
    /// file can make: a working day, a flat fleet that never sleeps, a day with
    /// one busy hour in it, and a series of two readings a day apart.
    func testAnAnswerAlwaysHasWorkHoursToSpreadTheWeekOver() throws {
        var oneBusyHour = Array(repeating: 0.0, count: 24)
        oneBusyHour[3] = 10
        let shapes: [(String, HistorySeries)] = [
            ("a working day", try workingDay()),
            ("a fleet that never sleeps", try shaped("main", rates: Array(repeating: 2, count: 24), days: 2)),
            ("one busy hour", try shaped("main", rates: oneBusyHour, days: 2)),
            ("two readings a day apart",
             try series("main", [(midnight, 0), (midnight.addingTimeInterval(24 * 3600), 20)])),
        ]
        for (name, shape) in shapes {
            let answer = try XCTUnwrap(FleetCapacity.sustainable(
                histories: histories([shape]), accounts: try fleet(["main"]),
                spentTokens: tokensForAMillionAPoint, timeZone: utc), "\(name) had no answer at all")
            XCTAssertGreaterThanOrEqual(answer.workHoursPerDay, 1, """
                \(name) burned points and answered zero work hours: the week the allowance is \
                spread over is then zero hours long, and the figure is an infinity
                """)
            XCTAssertTrue(answer.tokensPerHour.isFinite, "\(name) answered an allowance that is not a number")
        }
    }

    /// **The invariant that makes a guard on an empty contributor set
    /// unnecessary**, and the sibling of the one above.
    ///
    /// The burn the price of a point divides by is the sum over the contributors
    /// and nothing else. An account nobody could measure is not in that sum, so
    /// a fleet where nobody could be measured sums nothing and `burned > 0`
    /// refuses it. A `!measured.isEmpty` stood in front of that and decided
    /// nothing on any input: removing it killed 0 of the 531 tests the suite then
    /// held (2026-08-24), so it is gone.
    ///
    /// **Asking only whether such a fleet is refused would not hold this**, which
    /// is why the two tests that look like its cover are not it: the capacity of
    /// no contributors is zero, so `capacity - sleepingWeek > 0` refuses the same
    /// fleet a second time and the answer stays `nil` however the burn is formed.
    /// What is asked instead is the sum itself, through the one figure that
    /// prints it — `tokensPerPoint` is the fleet's tokens over exactly that sum —
    /// and then the step from "the sum over the contributors" to "an empty sum is
    /// zero": an account nobody could measure joins the fleet and moves neither
    /// the price nor the count.
    func testThePriceOfAPointDividesByTheContributorsAndNothingElse() throws {
        let day = try workingDay()
        let measured = try XCTUnwrap(FleetCapacity.measureHourly(day.points, resetsAt: nil,
                                                                 timeZone: utc))
        let burned = max(0, FleetCapacity.burn(over: measured.buckets))

        let answer = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([day]), accounts: try fleet(["main"]),
            spentTokens: tokensForAMillionAPoint, timeZone: utc))
        XCTAssertEqual(answer.tokensPerPoint, tokensForAMillionAPoint / burned, accuracy: 0.001, """
            the price of a point is not the fleet's tokens over the burn its contributors summed \
            to, so an empty set of them is not a division by nothing either
            """)

        // The second link, and the one the removed guard was standing on: an
        // account that cannot be measured is not a contributor, so it adds
        // nothing to that sum — which is what makes the sum over *no* contributor
        // a zero rather than something a guard had to catch first.
        let unmeasurable = try series("acc2", [(midnight, 0),
                                               (midnight.addingTimeInterval(23 * 3600), 20)])
        XCTAssertNil(FleetCapacity.measureHourly(unmeasurable.points, resetsAt: nil, timeZone: utc),
                     "the fixture has to be unmeasurable, or it proves nothing")
        let joined = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([day, unmeasurable]), accounts: try fleet(["main", "acc2"]),
            spentTokens: tokensForAMillionAPoint, timeZone: utc))
        XCTAssertEqual(joined.tokensPerPoint, answer.tokensPerPoint, accuracy: 0.001,
                       "an account nobody could measure moved the burn it is not part of")
        XCTAssertEqual(joined.accounts, 1, "and it was counted as a contributor")
    }

    /// **A fleet that worked and came back to where it started burned nothing**,
    /// and a point cannot be priced by dividing into that.
    ///
    /// This is the shape that keeps the second guard from being the first one
    /// again: the series climbs 5 pp over the small hours and gives every point
    /// back a tenth at a time — falls inside the sawtooth, so nothing is refused
    /// as a hidden reset — and it plainly has work hours. What it has not got is
    /// a net burn.
    func testASeriesThatEndsWhereItBeganPricesNoPoint() throws {
        var readings: [(Date, Double?)] = [(midnight, 0)]
        var value = 0.0
        for sample in 1...(48 * 12) {
            let hour = (sample - 1) / 12 % 24
            // Up through the first five hours of the day, back down through the
            // rest of it, a tenth of a point at a time.
            value += hour < 5 ? 0.5 : -0.5 * 5 / 19
            readings.append((midnight.addingTimeInterval(Double(sample) * 300), max(0, value)))
        }
        let there = try series("main", readings)
        let hourly = try XCTUnwrap(FleetCapacity.measureHourly(there.points, resetsAt: nil, timeZone: utc))
        XCTAssertEqual(FleetCapacity.burn(over: hourly.buckets), 0, accuracy: 0.5,
                       "the fixture has to end where it began, or it proves nothing")

        XCTAssertNil(FleetCapacity.sustainable(histories: histories([there]), accounts: try fleet(["main"]),
                                               spentTokens: tokensForAMillionAPoint, timeZone: utc),
                     "no points burned, so nothing says what a point costs")
    }

    /// The other half of the same guard: points were burned and the gateway
    /// reported no spending to price them with. Unknown is not zero (§2.7), and
    /// a price of nothing an hour would be drawn as a fleet with no budget at
    /// all rather than as a figure nobody measured.
    func testAWindowWithNoSpendingInItPricesNoPoint() throws {
        XCTAssertNil(FleetCapacity.sustainable(histories: histories([try workingDay()]),
                                               accounts: try fleet(["main"]),
                                               spentTokens: 0, timeZone: utc),
                     "the sessions half named no tokens: that is silence, not a week that cost nothing")
    }

    /// **A week whose nights already spend the whole quota leaves the days
    /// nothing**, and the honest answer is no figure rather than "zero an hour".
    ///
    /// Eight hours at 10 pp/h and sixteen at 0.9 — the threshold is 1.77, so the
    /// nights stay nights — and 0.9 x 16 x 7 = 100.8 pp of a 100 pp week is gone
    /// before a working hour is allowed anything. The control drops the nights to
    /// 0.85, which is 95.2 pp and leaves 4.8 to spread.
    func testAWeekAlreadySpentOnItsNightsHasNoAllowance() throws {
        XCTAssertNil(FleetCapacity.sustainable(
            histories: histories([try workingDay(sleeping: 0.9, working: 10, days: 1)]),
            accounts: try fleet(["main"]), spentTokens: tokensForAMillionAPoint, timeZone: utc), """
            100.8 pp of nights against a 100 pp week: the subtraction has gone negative, and a floor \
            at zero would draw that as a budget rather than as arithmetic with no answer
            """)

        let control = try XCTUnwrap(FleetCapacity.sustainable(
            histories: histories([try workingDay(sleeping: 0.85, working: 10, days: 1)]),
            accounts: try fleet(["main"]), spentTokens: tokensForAMillionAPoint, timeZone: utc))
        XCTAssertGreaterThan(control.allowedWorkRate, 0, "95.2 pp of nights still leaves 4.8 pp to spread")
    }

    /// An account pinned at its ceiling for the whole window is not an account
    /// that spent nothing, it is one whose spending was refused and never
    /// measured — so it takes its capacity out with it, exactly as it does on
    /// both estimators (§2.7).
    func testAnAccountPinnedAtItsCeilingContributesNeitherAllowanceNorCapacity() throws {
        let pinned = try series("acc3", (0...48).map {
            (midnight.addingTimeInterval(Double($0) * 3600), Double?(100))
        })
        XCTAssertNil(FleetCapacity.sustainable(histories: histories([pinned]),
                                               accounts: try fleet(["acc3"]),
                                               spentTokens: tokensForAMillionAPoint, timeZone: utc),
                     "a flat 100 is a blocked account, and its demand was never zero")

        // The control: the same account with one reading below the ceiling is
        // measured again, which is what says the refusal is about the ceiling
        // rather than about the shape of the fixture.
        var below = (0...48).map { (midnight.addingTimeInterval(Double($0) * 3600), Double?(60)) }
        for hour in [18, 19, 20, 42, 43, 44] { below[hour].1 = Double(60 + hour) }
        XCTAssertNotNil(FleetCapacity.sustainable(histories: histories([try series("acc3", below)]),
                                                  accounts: try fleet(["acc3"]),
                                                  spentTokens: tokensForAMillionAPoint, timeZone: utc))
    }
}
