import Charts
import Combine
import Foundation
import SwiftUI

// MARK: - Period

/// The window the history chart covers. The user's list, verbatim.
enum HistoryPeriod: String, CaseIterable, Identifiable, Sendable {
    case hour, sixHours, day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hour: return "1h"
        case .sixHours: return "6h"
        case .day: return "1d"
        case .week: return "7d"
        case .month: return "30d"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .sixHours: return 6 * 3600
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }

    /// What the panel's own state does not survive. The panel clears its search
    /// and re-freezes its row order at every appearance (§4) because every
    /// appearance is a fresh question; the popover is the opposite — the period
    /// is a preference, and being asked for it again on every open would be the
    /// annoyance. So it lives in `UserDefaults` rather than in any view model.
    static let defaultsKey = "usagePopoverHistoryPeriod"
}

// MARK: - History

/// One sample the chart can actually draw: a moment and a reading.
struct UsageReading: Sendable, Equatable {
    var timestamp: Date
    var value: Double
}

/// One account's utilisation over time, already cut into the pieces the chart
/// draws.
struct AccountSeries: Identifiable, Sendable, Equatable {
    var id: String { label }
    var label: String
    /// Contiguous runs of readings, in order.
    var segments: [Segment]

    /// A run of consecutive samples that all had a reading.
    ///
    /// The gateway sends `null` for a sample that said nothing about the window,
    /// and that is a hole in the line rather than a reading of zero. Swift
    /// Charts has no optional `Plottable`, so a hole cannot be expressed inside
    /// one series: dropping the sample would join the two sides across the gap
    /// and draw a line through a period nobody measured. Hence one series per
    /// run, all of them wearing the account's colour.
    struct Segment: Identifiable, Sendable, Equatable {
        /// Unique within the account, which is what makes it a series key.
        var id: Int
        var readings: [UsageReading]
    }

    /// Splits the gateway's samples into runs at every `null`.
    ///
    /// The seven-day window is the one taken, because it is the quantity the
    /// headline and the menu bar show — a chart of a different window under the
    /// same heading would be two scales in one view with nothing marking the
    /// boundary, which is what §4 removed from the row.
    static func make(label: String, points: [HistoryPoint]) -> AccountSeries {
        var segments: [Segment] = []
        var current: [UsageReading] = []
        for point in points {
            guard let value = point.sevenDay else {
                if !current.isEmpty { segments.append(Segment(id: segments.count, readings: current)) }
                current = []
                continue
            }
            current.append(UsageReading(timestamp: point.timestamp, value: value))
        }
        if !current.isEmpty { segments.append(Segment(id: segments.count, readings: current)) }
        return AccountSeries(label: label, segments: segments)
    }

    var isEmpty: Bool { segments.isEmpty }
}

/// The fleet's utilisation over time: the chart's main line.
///
/// Worked out here rather than fetched. The gateway has no such series and does
/// not need one — the quantity is a function of the account series already in
/// hand, and it is the same quantity the headline states in one number: the mean
/// over the accounts that have a reading.
///
/// Carried forward, never interpolated. Utilisation moves only when the gateway
/// takes a sample; between two samples an account is worth its last reading.
/// Interpolating would invent readings nobody took, which is the same lie a line
/// drawn across a `null` tells one type up.
struct FleetSeries: Sendable, Equatable {

    /// One moment of the line.
    struct Point: Sendable, Equatable {
        var timestamp: Date
        var value: Double
        /// How many accounts had a reading by this moment. A mean over two
        /// accounts and a mean over three are different statements, and this is
        /// what tells them apart — the gateway keeps the same count beside its
        /// own `fleet` block, for the same reason.
        ///
        /// Nothing on screen shows it: the chart has no place to say it that is
        /// not a second scale in one picture (§4). It is here because the tests
        /// are entitled to ask which accounts a point is a mean of — "the mean
        /// did not silently become a mean of one" is not visible in the value
        /// alone.
        var accounts: Int
    }

    /// In time order, and one run rather than several: see `make`.
    var points: [Point]

    static let empty = FleetSeries(points: [])

    var isEmpty: Bool { points.isEmpty }

    /// The key this line's colour and its place in the scale hang on. Nothing on
    /// screen reads it any more — the legend is hidden (§4) and the headline's own
    /// caption is what names this line now — but the scale still needs a domain
    /// entry no label anybody would configure can equal.
    ///
    /// Hence the NUL: an account's label comes out of the gateway's config, and
    /// a plain word is a label somebody may already have. `average` was one, and
    /// the collision is silent in the worst way — the domain gets the same key
    /// twice, Charts keeps the last colour for it, and the mean is drawn in that
    /// account's hue, one hue among hues rather than the one line in ink. No
    /// palette test notices: both lines are then chromatic and both dots still
    /// match a line of their own hue.
    ///
    /// Unreachable in practice rather than impossible: JSON spells a NUL as
    /// `\u0000` and the decoding path takes it, so a label written that way on
    /// purpose brings the collision straight back.
    static let label = "\u{0}average"

    /// The mean of the readings there are, and nothing at all when there are
    /// none: the average of no accounts is not zero — the rule `FleetWindow`
    /// applies to the gateway's own mean, applied to ours.
    ///
    /// Named and shared rather than written inline, because this is the
    /// arithmetic the headline figure is made of upstream. The two numbers come
    /// from two endpoints and cannot be computed in one place, so what is held
    /// instead is the rule: `testTheLastPointOfTheMeanIsTheHeadlineFigure` feeds
    /// this the same last-known readings the last point of the line is built
    /// from, and requires the two to agree to the rounding.
    static func mean(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Averages the accounts over the union of their sample times.
    ///
    /// Takes the raw samples rather than the drawn `AccountSeries`, and the
    /// difference is the moments at which a sample said nothing (`util_7d:
    /// null`): those moments belong in the union. Before anybody's first reading
    /// such a moment has no mean at all, and no point is emitted for it — the
    /// line starts where the measurements start, rather than at a zero nobody
    /// measured. A `null` later on is not a hole in this line, though: it says
    /// the gateway took no reading then, not that the account's reading changed,
    /// so the account keeps the value it was last measured at.
    ///
    /// The head is the only hole there can be, which is why this is one run of
    /// points and not the list of runs `AccountSeries` keeps: from an account's
    /// first reading onwards its value is carried for ever, so every later
    /// moment in the union has at least that one account in it.
    ///
    /// Each account's samples are taken in the order the gateway sent them,
    /// which is ascending — the same assumption `AccountSeries.make` already
    /// makes when it cuts them into runs.
    static func make(from samples: [[HistoryPoint]]) -> FleetSeries {
        let moments = Set(samples.flatMap { $0.map(\.timestamp) }).sorted()
        guard !moments.isEmpty else { return .empty }
        // One cursor and one carried reading per account: the walk is a merge
        // over the union, so every account's samples are consumed once in total
        // rather than once per moment.
        var cursors = [Int](repeating: 0, count: samples.count)
        var carried = [Double?](repeating: nil, count: samples.count)
        var points: [Point] = []
        points.reserveCapacity(moments.count)
        for moment in moments {
            var values: [Double] = []
            for account in samples.indices {
                let series = samples[account]
                while cursors[account] < series.count, series[cursors[account]].timestamp <= moment {
                    // The seven-day window, the one the headline and the menu bar
                    // show — the same choice, for the same reason, as
                    // `AccountSeries.make`.
                    if let value = series[cursors[account]].sevenDay { carried[account] = value }
                    cursors[account] += 1
                }
                // An account nobody has read yet is left out entirely. Counting
                // it as zero would drag the mean down with a figure that was
                // never measured.
                if let value = carried[account] { values.append(value) }
            }
            guard let value = mean(of: values) else { continue }
            points.append(Point(timestamp: moment, value: value, accounts: values.count))
        }
        return FleetSeries(points: points)
    }
}

/// The chart's data: fetched while the popover is open, and never otherwise.
///
/// `UsageStore` polls the two summary endpoints once a minute for the whole life
/// of the process, because the menu bar shows one of its numbers all the time.
/// The history is different: it is one request per account per pass, it is only
/// ever looked at inside an open popover, and a popover is open for seconds at a
/// time. So the schedule is tied to the popover — `open` starts it, `close`
/// stops it — and `fetch` refuses to run outside that, which is what makes the
/// closed state provably free rather than merely cheap.
@MainActor
final class UsageHistoryModel: ObservableObject {

    /// Utilisation over time, one entry per account, ordered by label so the
    /// chart's colours do not swap between two passes.
    @Published private(set) var series: [AccountSeries] = []
    /// The mean of those, which is the line the chart is mainly about. Computed
    /// in the same pass and assigned in the same places as `series`, so the two
    /// can never describe different fetches — a mean of lines that are no longer
    /// on screen is the picture lying about its own axis one level down.
    @Published private(set) var fleet: FleetSeries = .empty
    /// Why the last pass was incomplete, if it was. Kept beside the previous
    /// series rather than replacing them, exactly as `UsageStore` does.
    @Published private(set) var failure: String?
    /// When the lines on screen arrived, or `nil` while there are none.
    ///
    /// The age of the *series*, never the age of the attempt: the attempt has its
    /// own stamp below, and the two are kept apart for the same reason
    /// `UsageSnapshot.quotaFetchedAt` dates the figures rather than the pass. One
    /// stamp for both moved on every pass that finished, including the one where
    /// not a single account answered, and the chart then reported that the period
    /// held no data on the strength of an answer nobody had given.
    @Published private(set) var fetchedAt: Date?
    /// When the last pass finished, whatever came of it. Not published: it is
    /// the refresh schedule's clock, and the schedule has to go on ticking
    /// while the gateway is down — which is precisely when `fetchedAt` stands
    /// still.
    private(set) var checkedAt: Date?
    /// The window the lines on screen were fetched for, or `nil` when there are
    /// none. Not the same thing as `period`: the picker moves first and the
    /// answer lands after, so this is the only way to tell lines that answer the
    /// question being asked from lines that answer the previous one.
    ///
    /// The view asks it before drawing anything: for the seconds between the two
    /// it has lines in hand that answer the wrong question, and drawing them
    /// under the new tab is the picture lying about its own axis that `apply`
    /// refuses to keep one moment later.
    ///
    /// Not `@Published` all the same, and that is not an oversight. Its one
    /// writer is `apply`, which unconditionally ends by assigning `now` — and
    /// that one is published, so the change is announced in the same turn
    /// either way. A wrapper here would be the modifier that changes nothing
    /// AGENTS.md keeps a note about; removing it changed no test, which is the
    /// point.
    private(set) var seriesPeriod: HistoryPeriod?
    /// Ticks while the popover is open, so "as of N ago" stays true without a
    /// timer running behind a popover nobody is looking at.
    @Published private(set) var now: Date = Date()

    /// The chosen window. Writing it refetches, because the whole chart changes.
    @Published var period: HistoryPeriod {
        didSet {
            guard period != oldValue else { return }
            defaults.set(period.rawValue, forKey: HistoryPeriod.defaultsKey)
            fetch()
        }
    }

    /// How often the series are asked for again while the popover stays open.
    static let refreshSeconds: TimeInterval = 60
    /// How often the clock behind "as of N ago" is nudged. Coarse on purpose:
    /// the footer's own wording is not finer than a minute.
    static let tickSeconds: TimeInterval = 15

    private(set) var isOpen = false
    private let client: UsageClient
    private let defaults: UserDefaults
    private var labels: [String] = []
    private var timer: Timer?
    /// The pass in flight, if there is one. Not private, so a test can wait for
    /// the requests to land rather than race them: the promise this class makes
    /// is about requests that do and do not happen, and that is only observable
    /// at the transport.
    private(set) var fetchTask: Task<Void, Never>?

    init(client: UsageClient, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        period = defaults.string(forKey: HistoryPeriod.defaultsKey)
            .flatMap(HistoryPeriod.init(rawValue:)) ?? .day
    }

    convenience init(config: Config, defaults: UserDefaults = .standard) {
        self.init(client: UsageClient(baseURL: config.resolvedUsageBaseURL), defaults: defaults)
    }

    // MARK: Lifecycle

    /// The popover appeared. Driven from the controller that shows it rather
    /// than from the view's `onAppear`: `NSPopover` keeps its content view
    /// controller alive between showings, so whether SwiftUI calls `onDisappear`
    /// on a close is AppKit's business, and "no requests while closed" is too
    /// flat a promise to hang on it.
    func open(labels: [String]) {
        self.labels = labels
        isOpen = true
        now = Date()
        fetch()
        schedule()
    }

    /// The accounts changed under an open popover. Nothing to do when they did
    /// not: this is called from the view on every rebuild.
    func update(labels: [String]) {
        guard isOpen, labels != self.labels else { return }
        self.labels = labels
        fetch()
    }

    func close() {
        isOpen = false
        timer?.invalidate()
        timer = nil
        fetchTask?.cancel()
        fetchTask = nil
    }

    // MARK: Fetching

    /// One pass over every account, if the popover is open.
    func fetch() {
        guard isOpen else { return }
        let client = client
        let labels = labels
        // Carried into the answer rather than read again when it lands: the
        // period is what the request means, and by the time it comes back the
        // picker may be naming another one.
        let period = period
        let since = Date().addingTimeInterval(-period.seconds)
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            // `load` is `nonisolated`, so the requests do not inherit the main
            // actor and only the finished value hops back — the same rule, and
            // for the same reason, as `UsageStore.poll` (SPEC §6).
            let loaded = await UsageHistoryModel.load(client: client, labels: labels, since: since)
            guard let self, !Task.isCancelled else { return }
            self.apply(loaded, period: period)
        }
    }

    /// What one pass produced. A `Sendable` value so it can cross back to the
    /// main actor whole.
    struct Loaded: Sendable {
        var series: [AccountSeries]
        var fleet: FleetSeries
        var failure: String?
    }

    /// One request per account, in parallel, with each account's failure kept as
    /// text instead of an error: an account the gateway will not answer for is
    /// an ordinary state, and the others still have a chart to draw.
    ///
    /// The mean is folded here, off the main actor, and out of the same answers
    /// the account lines are cut from — an account that did not answer is absent
    /// from both. Doing it in the view instead would redo the fold on every
    /// redraw of an open popover, which is once every tick for as long as it is
    /// up.
    nonisolated static func load(client: UsageClient,
                                 labels: [String],
                                 since: Date) async -> Loaded {
        struct Fetched: Sendable {
            var label: String
            var points: [HistoryPoint]
            var failure: String?
        }
        var answered: [Fetched] = []
        var failures: [String] = []
        await withTaskGroup(of: Fetched.self) { group in
            for label in labels {
                group.addTask {
                    do {
                        let answer = try await client.history(label: label, since: since)
                        // Filtered once, here, and both the lines and the mean
                        // are built from the result below. What matters is that
                        // it is one path and not two: applied to the account
                        // lines alone, or to the mean alone, the bold line and
                        // the lines under it would describe different data.
                        // Filtering twice would merely be wasted work — the rule
                        // is idempotent (`f(f(x)) == f(x)` on all 5484 live
                        // samples of 17.08.2026), because a filtered series has
                        // no fall of one point left inside a window for a second
                        // pass to find.
                        return Fetched(label: label,
                                       points: withoutSourceLag(answer.points),
                                       failure: nil)
                    } catch {
                        return Fetched(label: label, points: [], failure: "\(label): \(error)")
                    }
                }
            }
            for await item in group {
                if let failure = item.failure {
                    failures.append(failure)
                } else {
                    answered.append(item)
                }
            }
        }
        answered.sort { $0.label < $1.label }
        failures.sort()
        return Loaded(series: answered.map { AccountSeries.make(label: $0.label, points: $0.points) },
                      fleet: FleetSeries.make(from: answered.map(\.points)),
                      failure: failures.isEmpty ? nil : failures.joined(separator: "; "))
    }

    /// The gateway's samples with the lag between its two measuring sources taken
    /// out of `util_7d`: inside a quota window utilisation only accumulates, so a
    /// fall of exactly one point per cent is the slower source talking and the
    /// reading before it is carried through.
    ///
    /// The sawtooth is real and it is not the quota's. A sample carries the
    /// `source` it was taken from — `poll` (the gateway asked the API for the state
    /// of the quota) or `headers` (the figure was read out of the headers of an
    /// ordinary request) — and `headers` trails `poll` by about one five-minute
    /// poll cycle, so for the length of that lag the two report figures one point
    /// per cent apart. Shuffled together in time they draw a comb.
    ///
    /// The window is hard, not sliding, which is what makes "utilisation does not
    /// fall" a rule rather than a guess: the two resets in the history drop 100 → 0
    /// at 2026-08-15 21:00Z and 99 → 0 at 2026-08-16 15:00Z, and each account then
    /// announces a `resets_at` exactly 7×24 h later. Inside such a window spend
    /// only accumulates.
    ///
    /// Measured against the live gateway on 17.08.2026 (3 accounts, 5437 samples,
    /// 2.3–2.6 days each — all the history there is, SPEC §4): 322 falls, every one
    /// of them exactly 1 pp deep, and after this rule at most one — the last
    /// sample of a series, when it is the trailing source that took it, which the
    /// rule may not touch. Half an hour later the same three answered 327 and none.
    /// A fall lasts 3 to 5 samples, so a median of three could only ever reach the
    /// 43 that lasted a single sample — 42 of them, the last sample of a series
    /// being beyond any filter. The rest it "cured" by deleting the *higher*
    /// reading instead, which pinned the line to the trailing source: of the 352
    /// samples it changed, it lowered 310. Figures in SPEC §4.
    ///
    /// Filtering by `source` was tried and rejected: `poll` alone throws away 3298
    /// of the 5437 samples and guts the resolution of the short windows, and every
    /// one of the 322 falls is made of `headers` samples — 10 of them with a
    /// `headers` reading on top as well, so dropping `poll` does not help either.
    /// The numbers and the method are in SPEC §4.
    ///
    /// Three things it deliberately does not do. A fall into zero is taken as it
    /// came however small it is, because a reset is the one event this chart exists
    /// to show. A level is never carried across a `null`: a hole is "nobody
    /// measured" (§4), a reset may have happened inside one, and after it the rule
    /// starts again with no inherited level. And **the last reading is never
    /// moved** — the end of the bold line is the reading as it arrived, because
    /// the freshest figure is the one thing the rule may not guess on the
    /// gateway's behalf. It is emphatically not a promise that the end of the
    /// line equals the headline: those are two endpoints (`/gw/usage` and the
    /// history) with the same source lag over both, and only the arithmetic is
    /// shared (§4). About one sample in four arrives inside a lag — 1348 of 5484
    /// on 17.08.2026 — so the two standing 1 pp apart is an ordinary state and
    /// not a rarity of the moment one measures in. It goes either way: in 39 of 60
    /// observations that evening the window had already reached a point above the
    /// last sample, so it was the exemption that kept the end of the line level
    /// with the headline rather than a point over it.
    ///
    /// That last exemption has to be spelled out here, where under the median it
    /// followed from the shape of the window: a reading with nothing but holes
    /// after it used to be declined because the window would have had to reach
    /// across a `null`, and this rule looks only backwards, so it would happily
    /// raise it. Hence `lastIndex(where:)` rather than `dropLast()`.
    /// `testTheLastReadingIsNeverMoved` asks it in both forms.
    ///
    /// Where it lies, and it is worth naming because the chart will not show it.
    /// Telling a lag from a reset by the *depth* of the fall is an indirect test
    /// and it blurs at both ends. A genuine reset exactly 1 pp deep and not into
    /// zero — the window rolls over at 2 % and the first sample of the new one
    /// reads 1 % — is taken for a lag and pulled back up to 2, and since the rule
    /// never lowers a level, that point of overstatement stays to the end of the
    /// series or to the next hole. Live data holds no such case (all 334 falls of
    /// the control run were 1 pp deep, and both real resets fell from 100 and from
    /// 99), and the line it draws comes out smooth and plausible, which is exactly
    /// why it goes in writing. The other end is a lag 2 pp deep, when two points
    /// burn inside one poll cycle: that fall is read as a reset, the sample is
    /// taken as it came, and the rule stands down over the stretch. Nothing is
    /// falsified — the sample is drawn as it arrived — but the comb stays, and that
    /// is the tell: a sawtooth back on the chart while only a handful of samples
    /// were changed. A sawtooth at 24 % changed is the ordinary lag, handled.
    ///
    /// `util_5h` is left as it came: no line on this chart is drawn from it.
    ///
    /// **This result is for drawing the line and for nothing else.** Spend over a
    /// stretch is the two ends of it plus 100 pp for every reset crossed, and no
    /// series here may be differenced for it. On the raw samples the comb makes
    /// that arithmetic nonsense: the positive deltas of acc2 add up to 167 pp over
    /// 63.4 h against the 50 pp actually spent (192 against 55, 86 against 19 on
    /// the other two). This filtered series happens to give the right total by the
    /// same method, but only because the rule left it monotone inside a window,
    /// where the sum of the rises *is* the difference of the ends — it buys
    /// nothing and would hide the error the day the rule changes. And a level read
    /// off it is up to 1 pp above what arrived, for as long as the lag lasts.
    /// `load` above is the only caller, on purpose.
    nonisolated static func withoutSourceLag(_ points: [HistoryPoint]) -> [HistoryPoint] {
        // Everything past the last reading is a hole, and holes are never moved,
        // so the pass stops here — which is also the exemption that leaves the
        // end of the bold line as the gateway sent it (§4).
        guard let last = points.lastIndex(where: { $0.sevenDay != nil }) else { return points }
        var filtered = points
        // The figure this window is known to have reached. `nil` before the first
        // reading and after every hole.
        var carried: Double?
        for index in 0..<last {
            guard let value = points[index].sevenDay else {
                carried = nil
                continue
            }
            // A fall of exactly one point that is not a fall into zero: the
            // trailing source, and the reading before it stands. The tolerance is
            // for a percentage that arrives as a fraction — the gateway sends
            // whole numbers today (0 of 5437 samples were fractional), and the
            // field is a `Double` all the same.
            if let level = carried, value > 0, abs(level - value - 1) < 1e-6 {
                filtered[index] = HistoryPoint(timestamp: points[index].timestamp,
                                               fiveHour: points[index].fiveHour,
                                               sevenDay: level)
            } else {
                carried = value
            }
        }
        return filtered
    }

    private func apply(_ loaded: Loaded, period: HistoryPeriod) {
        let moment = Date()
        if !loaded.series.isEmpty {
            // Somebody answered: these are the lines, and this is when they
            // arrived. An account that answered with nothing but holes is still
            // an answer — its entry is here, empty, and the chart may then
            // honestly say the period held no data.
            series = loaded.series
            fleet = loaded.fleet
            seriesPeriod = period
            fetchedAt = moment
        } else if loaded.failure == nil || seriesPeriod != period {
            // Nothing came back, and what is on screen may not stand in for it.
            // A failed pass otherwise keeps the previous lines — slightly stale
            // beats blank, with the reason in the footer — but only while they
            // still answer the question being asked: after a change of period
            // they are a `1d` chart under a `30d` label, a picture lying about
            // its own axis. Without a failure there was simply nobody to ask.
            // The stamp goes with them: nothing arrived, and a footer dating
            // lines that are not there is the same lie one level down.
            series = []
            fleet = .empty
            seriesPeriod = nil
            fetchedAt = nil
        }
        failure = loaded.failure
        checkedAt = moment
        now = moment
    }

    // MARK: Timer

    private func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.tickSeconds, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // `.common`, like every other timer here: dragging inside the popover
        // must not stop the clock.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// `checkedAt`, not `fetchedAt`: the schedule is about attempts, and asking
    /// again is exactly what a gateway that is not answering needs. Keyed on the
    /// arrival of the lines it would stop dead the moment the first pass failed
    /// — the popover would then sit there for as long as it is open, retrying
    /// nothing.
    ///
    /// The clock is an argument so that rule can be checked without waiting a
    /// minute of real time for it; the timer above always hands it the real one.
    func tick(now moment: Date = Date()) {
        guard isOpen else { return }
        now = moment
        guard let checkedAt, moment.timeIntervalSince(checkedAt) >= Self.refreshSeconds else { return }
        fetch()
    }
}

// MARK: - Popover

/// What the left click on the status item opens: the fleet's weekly quota in
/// full size, then each account's two windows, then utilisation over time — and,
/// only when there is something to say about it, how old all of it is.
struct UsagePopoverView: View {

    @ObservedObject var usage: UsageStore
    @ObservedObject var history: UsageHistoryModel

    /// Which plate this popover is drawn on, which is what the ramp's colour has
    /// to be legible against (`ratioColor(atPercent:on:)`).
    ///
    /// From the environment rather than from `NSApp`, because the popover follows
    /// whatever appearance it is presented in and SwiftUI is the only thing that
    /// knows it here. The menu bar answers the same question for itself from the
    /// appearance it rasterises against (`MenuBarIcon.background(for:)`) — the
    /// two surfaces sit on two different plates and cannot share an answer, only
    /// the rule that reads it.
    @Environment(\.colorScheme) private var colorScheme

    private var background: RampBackground { colorScheme == .dark ? .dark : .light }

    /// The width of the popover. Wide enough for the chart's axis labels and a
    /// reset time on the same line as its bar.
    static let width: CGFloat = 320

    /// The inset around everything in the popover. Named rather than written into
    /// `body`, because it is also the answer to "how wide is a full-width rule
    /// here": `UsagePopoverPaintTests` measures a `Divider` against the content
    /// width, and against the picture's width the same rule would be a different
    /// figure every time this number changed.
    static let padding: CGFloat = 14

    /// The one symbol in this view. Held by `testEverySymbolNameActuallyResolves`
    /// along with the row's four: an unknown name draws nothing at all.
    static let failureSymbolName = "exclamationmark.triangle.fill"

    /// What the big figure is a figure of, and in what size. Constants for the
    /// reason the dot's size is one: the test that holds this line at one line
    /// (`testTheHeadlineCaptionIsDrawnOnOneLine`) measures the string drawn on its
    /// own against the same string drawn in the popover, and a copy of the wording
    /// or of the size in the test would compare a rendering with a rendering of
    /// something else.
    static let headlineCaption = "weekly quota, average across accounts"
    static let headlineCaptionSize: CGFloat = 11

    /// What the spend ratio is called where it is written out in words, which
    /// since the lead became a pair of rates is the menu bar's accessibility
    /// description and nothing else (`MenuBarIcon.describe`). The menu bar's
    /// picture prints the ratio as a bare percentage under its bar, where the
    /// bar it stands on is the caption.
    ///
    /// It stays in this file because it belongs with `ratioLabel`, the string it
    /// qualifies, and the two are read together in one place. No jargon and no
    /// internal vocabulary — the word this metric is called by inside the app
    /// appears in no string on any surface (§4). "Sustainable" is the one word
    /// borrowed from the code, and it is borrowed the other way round: the lead's
    /// own caption has said `of 19.5M/h sustainable` since the rates arrived, so
    /// a reader who hears this one has already read that one.
    static let ratioCaption = "of the sustainable spend rate"

    /// The words under the lead figure, which now name the allowance rather than
    /// the quantity the figure is a percentage of — because the figure is no
    /// longer a percentage of anything. `23.8M/h` over `of 19.5M/h sustainable`
    /// states the spending and the budget in one unit, and their ratio is the
    /// bar underneath.
    ///
    /// Built rather than constant, and that is the whole change to this caption:
    /// the second half of the sentence is a measurement. The pieces are named so
    /// the layout test can draw the same string free-standing without copying
    /// the wording (`testTheHeadlineCaptionIsDrawnOnOneLine`).
    static func sustainableCaption(_ tokensPerHour: Double) -> String {
        "of " + rateLabel(tokensPerHour) + " sustainable"
    }

    /// The headline's bar, taller than the ones on the account rows because it
    /// belongs to the figure this popover is opened for.
    ///
    /// A constant for the reason the dot's size is one: the test that holds its
    /// colour finds it by its size — nothing else in the picture is a patch
    /// exactly this tall — and a copy of the number in the test would be a test
    /// about a bar that no longer exists.
    static let headlineBarHeight: CGFloat = 8

    /// The lead figure and the supporting one under it, and the gap between the
    /// two readings.
    ///
    /// The sizes are what make the pair read as a lead and a second reading
    /// rather than as twins, and they are named because the tests draw the two
    /// figures free-standing to measure what the popover drew (a copy of a size
    /// there would be comparing a rendering with a rendering of something else).
    ///
    /// **The lead slot no longer prints a percentage**, so the measurement that
    /// used to stand here is history: it sized the slot from `≥300%` and
    /// `≥999999999999%`, which is `ratioLabel`, and `ratioLabel` reaches this
    /// surface nowhere any more — the lead prints `rateLabel`, and the quota's
    /// percentage prints under it at `supportingFigureSize`. The old numbers are
    /// left named rather than deleted only so nobody re-derives them: `≥300%` was
    /// 104.00 pt of *layout* at 30 pt, twelve digits fitted and thirteen did not
    /// (2026-08-18). They are not comparable with what follows — layout width
    /// counts the side bearings that ink does not.
    ///
    /// **Re-measured against what the slot draws now** (2026-08-24, ink from a
    /// rendering at `scale = 2`, by the same `figureWidth` the layout tests
    /// measure with, against a content line of 292 pt):
    ///
    ///     lead, 30 pt     23.8M/h       115.00 pt      999.9M/h    134.50
    ///                     999.9B/h      128.00         999/h        82.00
    ///                     100% (no rates)  79.50       —            24.50
    ///     second, 17 pt   52%            36.00         100%         46.00
    ///     captions, 11 pt  of 19.9M/h sustainable  117.00
    ///                      weekly quota, average across accounts  205.50
    ///
    /// So a rate this fleet can produce leaves well over half the line free, and
    /// no figure can crowd its caption off its own row — the thing this layout
    /// was rebuilt for.
    ///
    /// **And unlike the percentage it replaced, this string has no argument that
    /// it cannot overflow.** Nothing clamps the rate; `perHour` refuses only an
    /// infinity, so any finite body is printed. The slot holds eleven digits
    /// before the decimal point (`99999999999.9B/h`, 282.50 pt) and the twelfth
    /// is the first over the line (302.00 pt) — which is 1e20 tokens an hour,
    /// thirteen orders of magnitude above the live fleet's 2.13e7 ie/h
    /// (2026-08-24).
    /// The sizes are still chosen against the captions rather than against that,
    /// because a gateway reporting 1e20 tokens an hour has a worse problem than
    /// its layout.
    ///
    /// That each caption does come out on one line under its own figure is a
    /// rendering and not an inference: `testTheHeadlineCaptionIsDrawnOnOneLine`
    /// for the lead's and `testTheHeadlineDrawsTheSpendAndTheWeeklyQuotaAtOnce`
    /// for the pair.
    ///
    /// The gap is wider than the 6 pt inside a reading and narrower than the
    /// 12 pt between the popover's sections: the two belong together, and they
    /// are still two.
    static let headlineFigureSize: CGFloat = 30
    static let supportingFigureSize: CGFloat = 17
    static let headlineReadingSpacing: CGFloat = 10

    /// The supporting reading's bar — the height an account's window row gets,
    /// which is the point: the lead's 8 pt says which figure the popover is for,
    /// and the quota is drawn at the weight of the readings it summarises.
    static let supportingBarHeight: CGFloat = 6

    /// The slot the reset time gets at the right end of a window row. Wide enough
    /// for everything `resetLabel` writes about a quota window, which is measured
    /// rather than asserted (`testTheResetTimeFitsItsSlotWhole`): a truncated
    /// `in 5d 0h` would be an hour count reading as a day count, which is the very
    /// defect the hours were added for.
    ///
    /// Not "the longest thing the function can write" — there is no such thing.
    /// The 30 days of the chart's widest period cap the *chart*; `resetLabel`
    /// prints as many days as the gateway names, and 56 years of them still fit
    /// (§4 records the figures). What is measured is the slot.
    static let resetColumnWidth: CGFloat = 74

    /// The dot in front of an account's name — the sample of that account's line
    /// on the chart, which is why the chart has no legend.
    ///
    /// A constant because the test that holds the colours finds the dots by their
    /// size: nothing else in this view is both opaque and coloured in a square
    /// this small. Written into the frame in two places, the number would be a
    /// copy in the test, and changing the dot — pure decoration — would fail a
    /// test about the palette.
    static let accountDotSize: CGFloat = 7

    var body: some View {
        // Worked out once here rather than inside `footer`, because the divider
        // above it depends on the answer: a footer with nothing to say must not
        // leave a rule hanging across the bottom of the popover.
        let age = Self.footerAgeLabel(quotaFetchedAt: usage.snapshot.quotaFetchedAt,
                                      quotaFailed: usage.snapshot.quotaFailure != nil,
                                      chartFetchedAt: history.fetchedAt,
                                      seriesPeriod: history.seriesPeriod,
                                      period: history.period,
                                      chartFailed: history.failure != nil,
                                      allowanceFailed: usage.snapshot.allowanceFailure != nil,
                                      now: history.now)
        let failure = Self.failureText(quota: usage.snapshot.quotaFailure,
                                       history: history.failure,
                                       allowance: usage.snapshot.allowanceFailure)
        return VStack(alignment: .leading, spacing: 12) {
            headline
            Divider()
            accounts
            Divider()
            chart
            if !Self.footerIsSilent(age: age, failure: failure) {
                Divider()
                footer(age: age, failure: failure)
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        // The accounts come from the summary poll, which runs whether or not
        // this view is up; an account appearing under an open popover should get
        // its line.
        .onChange(of: usage.snapshot.accounts.map(\.label)) { _, labels in
            history.update(labels: labels)
        }
    }

    // MARK: Headline

    /// The weekly quota, rounded in one place (`UsageSnapshot.fleetSevenDayPercent`)
    /// so that two readers cannot round it two ways.
    ///
    /// **This surface is the only one that draws it now.** The menu bar drew the
    /// same figure until 2026-08-24 and drew it under a colour that meant
    /// something else; it now carries the spend ratio, number, fill and colour
    /// alike, and the quota is what this block says under the lead (§4). What the
    /// two surfaces still share is the reading and not the rule: this side may
    /// keep a figure the last pass failed to refresh, because there is room under
    /// it for the footer to say how old it is. Gating this line on freshness put
    /// a dash over the account rows right below it, which go on showing their
    /// stored percentages — two contradicting statements on one screen, and the
    /// dash was the false one: the number is known, it is merely old.
    /// Three rows to a reading rather than "figure, caption beside it, bar", and
    /// the reason is measured (§4): the caption is 206 pt of a 292 pt line, so
    /// beside a figure it only fits while the figure is short. `52%` leaves it
    /// 219 pt and `100%` leaves 199.5 — the caption then wraps, and a wrapped
    /// caption is the complaint this headline was rebuilt for. On its own row it
    /// has the whole width and one line is one line whatever the figure says.
    ///
    /// **What stands in the lead three is a pair of rates in one unit**: how fast
    /// tokens are going now, and how fast they may go and still last the week.
    /// `23.8M/h` over `of 19.5M/h sustainable`, and the bar is their ratio. No
    /// per cent anywhere in the block, because a per cent of a seven-day window
    /// is not a thing the five minutes it is measured over can be held against
    /// without arithmetic nobody does in their head.
    ///
    /// The numerator needs no estimating at all — the gateway measures it and
    /// publishes it (`TokenRate`) — and the denominator is the week's capacity
    /// priced in tokens (`FleetCapacity.sustainable`). The mean utilisation
    /// stands there instead when either is missing, and all three rows switch
    /// together. The caption names the figure and the bar is that figure drawn
    /// against its allowance, so a bar left showing one quantity under a caption
    /// naming another would be the two contradicting statements on one screen
    /// that this very headline already refused once (see `headlinePercent`).
    ///
    /// **And the colour of the block is that same ratio**, which it was not
    /// until this round: the ramp used to read a separately *estimated* week's
    /// load, so the shade and the numbers under it were two answers to two
    /// different questions. On the live fleet 2026-08-24 the estimate answered
    /// 92.3% while these figures answered 174.9% — a green over a red reading.
    /// The estimate is gone with the estimators.
    ///
    /// **Two readings, one under the other, and the quota is not the lead any
    /// more.** The spend against its allowance answers "will the week last",
    /// which is why the popover gets opened, so it takes the big figure; the
    /// weekly quota answers "how much is gone", which is a different question
    /// and still worth an answer, so
    /// it keeps a figure, a caption and a bar of its own underneath at
    /// `supportingFigureSize` against the lead's `headlineFigureSize`. What the
    /// branch above refused was a *bar* showing one quantity under a caption
    /// naming the other; a second reading that names itself is the opposite of
    /// that, and putting the quota back is the owner's call — the branch that
    /// replaced it took a reading off the screen rather than adding one.
    ///
    /// **A missing rate falls back to exactly the old drawing, and nothing is
    /// invented in its place.** `headlineRates` answers `nil` for everything
    /// `FleetCapacity.sustainable` refuses on — no account with a whole day of
    /// history, every account pinned at its ceiling, nothing burned or nothing
    /// spent to price a point by, a week already eaten by its nights — for
    /// histories nobody has confirmed recently enough, and for a gateway that
    /// named no live rate at all. From here they are one state, because none of
    /// them hands back a way to tell it from the others.
    /// Some are an honest "unknown" and one is a fleet in the worst trouble it
    /// can be in; a number that split the difference would be wrong for all of
    /// them (§2.7). Then the quota is the lead and the supporting block is not
    /// drawn at all: the fallback already states it, and drawn anyway it would be
    /// the same percentage twice on one surface.
    private var headline: some View {
        // The clock the whole popover reads, which ticks while it is open: one
        // of the lead's two rules is an age, so a figure that goes stale under an
        // open popover has to leave the headline without waiting for a click.
        let rates = Self.headlineRates(for: usage.snapshot, now: history.now)
        let percent = Self.headlinePercent(for: usage.snapshot)
        return VStack(alignment: .leading, spacing: Self.headlineReadingSpacing) {
            // Past the allowance the bar is full and the two figures carry the
            // rest: a scale that stretched to fit three times the allowance
            // would make the allowance itself — the point the whole reading
            // turns on — a mark a third of the way along.
            //
            // The menu bar's bar now fills with the same quantity and clamps at
            // the same place (`MenuBarIcon.fillWidth`), and that is one rule
            // rather than a coincidence: each bar sits under its own number, and
            // since 2026-08-24 both numbers are this ratio. It was not so while
            // the item drew the mean — the mean cannot reach the clamp at all,
            // topping out at exactly 100 — and the clamp was the only thing the
            // two bars had in common.
            reading(figure: Self.headlineFigureLabel(for: usage.snapshot, now: history.now),
                    color: Self.headlineFigureColor(for: usage.snapshot, now: history.now,
                                                    on: background),
                    size: Self.headlineFigureSize,
                    caption: rates.map { Self.sustainableCaption($0.allowance) } ?? Self.headlineCaption,
                    fraction: rates.map(\.ratio) ?? percent.map { Double($0) / 100 },
                    barHeight: Self.headlineBarHeight,
                    tint: rates.map { Self.ratioColor(atPercent: $0.percent, on: background) })
            if rates != nil {
                // The quota exactly as it was drawn before the rates arrived,
                // only smaller: ink for the figure, and the bar left to
                // `QuotaBar.color(for:)` — that scale's 60 and 85 per cent are
                // thresholds on *this* quantity, how much of a window is gone,
                // which is the one reading on this surface they belong to.
                reading(figure: Self.quotaLabel(for: usage.snapshot),
                        color: .primary,
                        size: Self.supportingFigureSize,
                        caption: Self.headlineCaption,
                        fraction: percent.map { Double($0) / 100 },
                        barHeight: Self.supportingBarHeight,
                        tint: nil)
            }
        }
    }

    /// One reading of the headline: a figure, the words that name it, and the bar
    /// it draws as. Written once because the two readings are the same shape and
    /// differ only in their sizes and in what colours them.
    private func reading(figure: String,
                         color: Color,
                         size: CGFloat,
                         caption: String,
                         fraction: Double?,
                         barHeight: CGFloat,
                         tint: Color?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Tighter than the gap above the bar, because the words belong to the
            // figure: they say which quota it is.
            VStack(alignment: .leading, spacing: 2) {
                Text(figure)
                    .font(.system(size: size, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Text(caption)
                    .font(.system(size: Self.headlineCaptionSize))
                    .foregroundStyle(.secondary)
            }
            QuotaBar(fraction: fraction, height: barHeight, tint: tint)
        }
    }

    // MARK: Accounts

    @ViewBuilder private var accounts: some View {
        if usage.snapshot.accounts.isEmpty {
            Text(Self.accountsEmptyLabel(usage.snapshot))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            let labels = usage.snapshot.accounts.map(\.label)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(usage.snapshot.accounts, id: \.label) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            // This account's line on the chart below, which is
                            // why the chart has no legend of its own: a row of
                            // swatches under the plot said the same thing twice
                            // as far from the names as it could be put.
                            Circle()
                                .fill(Self.accountColor(for: account.label, in: labels))
                                .frame(width: Self.accountDotSize, height: Self.accountDotSize)
                            Text(account.label)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        windowRow("5h", account.fiveHour)
                        windowRow("7d", account.sevenDay)
                    }
                }
            }
        }
    }

    /// One quota window of one account: what it is, how full it is, and when it
    /// starts over. An unknown window is a dash in both places — the gateway
    /// saying nothing is not the same as an untouched quota, and this is the
    /// line where a confident `0%` would be read as good news.
    private func windowRow(_ title: String, _ window: UsageWindow?) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 20, alignment: .leading)
            QuotaBar(fraction: window?.utilization.map { $0 / 100 }, height: 6)
            Text(Self.percentLabel(window?.utilization))
                .font(.system(size: 11))
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
            Text(Self.resetLabel(window?.resetsAt, now: history.now))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: Self.resetColumnWidth, alignment: .trailing)
                .lineLimit(1)
        }
    }

    // MARK: Chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $history.period) {
                ForEach(HistoryPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            plot
                .frame(height: 130)
        }
    }

    /// Not private, so a test can render this branch rather than only the
    /// question it asks: which of the two it takes is the whole rule about lines
    /// that answer the period being asked about, and the rule was missing here
    /// while the question it asks was under test.
    @ViewBuilder var plot: some View {
        // Lines are drawn only while they answer the period the picker names.
        // The picker moves first and the answer lands after — up to five seconds
        // later through the tunnel — and the lines in hand meanwhile are the
        // previous window's. `seriesPeriod` exists to tell the two apart, and
        // this is the place that has to ask it: `period.didSet` only refetches.
        if history.seriesPeriod != history.period || history.series.allSatisfy(\.isEmpty) {
            Text(Self.plotEmptyLabel(snapshot: usage.snapshot,
                                     seriesFetchedAt: history.fetchedAt,
                                     seriesPeriod: history.seriesPeriod,
                                     period: history.period,
                                     historyFailure: history.failure))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(history.series) { account in
                    // One series per run of readings, so a `null` sample leaves
                    // a gap instead of a line drawn through a period nobody
                    // measured. The colour is keyed on the account, so all the
                    // runs of one account share it rather than getting one hue
                    // per run.
                    ForEach(account.segments) { segment in
                        if segment.readings.count == 1, let only = segment.readings.first {
                            // A run of one draws no line at all — a reading
                            // alone between two holes would simply be missing.
                            PointMark(x: .value("time", only.timestamp),
                                      y: .value("%", only.value))
                            .foregroundStyle(by: .value("account", account.label))
                            .symbolSize(8)
                            .opacity(Self.accountOpacity)
                        } else {
                            ForEach(segment.readings, id: \.timestamp) { reading in
                                LineMark(x: .value("time", reading.timestamp),
                                         y: .value("%", reading.value),
                                         series: .value("segment", "\(account.label)#\(segment.id)"))
                                .foregroundStyle(by: .value("account", account.label))
                                .lineStyle(StrokeStyle(lineWidth: Self.accountLineWidth))
                                .opacity(Self.accountOpacity)
                            }
                        }
                    }
                }
                // The mean, drawn last so that the line this whole popover is
                // about ends up on top of the ones that explain it rather than
                // under whichever account happens to cross it.
                if history.fleet.points.count == 1, let only = history.fleet.points.first {
                    PointMark(x: .value("time", only.timestamp),
                              y: .value("%", only.value))
                    .foregroundStyle(by: .value("account", FleetSeries.label))
                    .symbolSize(24)
                } else {
                    ForEach(history.fleet.points, id: \.timestamp) { point in
                        LineMark(x: .value("time", point.timestamp),
                                 y: .value("%", point.value),
                                 series: .value("segment", FleetSeries.label))
                        .foregroundStyle(by: .value("account", FleetSeries.label))
                        .lineStyle(StrokeStyle(lineWidth: Self.fleetLineWidth))
                    }
                }
            }
            // An explicit scale rather than the automatic one, for the one thing
            // it decides that the picture depends on: which colour each key gets
            // — the mean's is ink itself, and no account may be handed it, which
            // is why `FleetSeries.label` is a key no configured label equals.
            //
            // The account colours are keyed on the snapshot's list of accounts,
            // not on the position in `history.series`: the dots beside the names
            // upstairs are keyed the same way, and the two lists are not the same
            // list. `series` holds the accounts that *answered* the history
            // request, so one account failing would shift every colour after it
            // by one and the dot beside a name would then lie about which line is
            // that account's.
            .chartForegroundStyleScale(domain: Self.styleDomain(history.series),
                                       range: Self.styleRange(history.series,
                                                              labels: usage.snapshot.accounts.map(\.label)))
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3))
            }
            // No legend. It said what the dots beside the account names now say,
            // as far from those names as the popover could put it, and it cost
            // the plot about 16 of its 130 points: with it gone the plot area
            // runs to 84% of the picture's height instead of 72% (§4, where the
            // tests' measured bands are recorded).
            .chartLegend(.hidden)
            .font(.system(size: 9))
        }
    }

    // MARK: Chart styling

    /// The mean is the figure this popover exists to show, so it is the one line
    /// drawn at full strength; the accounts explain it and stay behind it. Two
    /// differences rather than one, because either alone is weak on a 320 pt
    /// chart: width separates the lines where they run apart, opacity where they
    /// run together.
    static let fleetLineWidth: CGFloat = 2.5
    static let accountLineWidth: CGFloat = 1
    static let accountOpacity: Double = 0.55

    /// Ink itself, so the mean is the one line that is not a hue among hues —
    /// and semantic, so it follows light and dark appearance like everything
    /// else on this surface.
    static let fleetColor = Color.primary

    /// The accounts, taken in the order the snapshot keeps them (by label), so a
    /// colour belongs to an account for as long as the account list does not
    /// change rather than for one pass. Cycled, because how many accounts there
    /// are is the gateway's business.
    static let accountColors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]

    /// The colour of one account, everywhere it is drawn: its line on the chart
    /// and the dot beside its name.
    ///
    /// Keyed on the account's place in the snapshot's list, which is the one list
    /// both surfaces have. The dots are drawn from the snapshot and the lines from
    /// the accounts that answered the history request, and those two differ
    /// exactly when an account did not answer — keyed on its own list, each side
    /// would then hand out a different colour from the same palette, and the dot
    /// beside a name would point at somebody else's line.
    ///
    /// An account the snapshot does not list has no place in the palette at all,
    /// and grey is the answer: a line whose account the poll no longer names is
    /// not worth a hue that belongs to somebody.
    static func accountColor(for label: String, in labels: [String]) -> Color {
        guard let index = labels.firstIndex(of: label) else { return .gray }
        return accountColors[index % accountColors.count]
    }

    /// The mean first — the scale's order, and the one place the mean's own key
    /// gets its colour.
    static func styleDomain(_ series: [AccountSeries]) -> [String] {
        [FleetSeries.label] + series.map(\.label)
    }

    /// One colour per entry of `styleDomain`, in the same order: a shorter range
    /// would leave the tail of the domain unstyled.
    static func styleRange(_ series: [AccountSeries], labels: [String]) -> [Color] {
        [fleetColor] + series.map { accountColor(for: $0.label, in: labels) }
    }

    // MARK: Footer

    /// How old what is on screen is, and why it might be stale — and neither line
    /// when there is nothing to say. Both are worked out by `body`, which needs
    /// the answers before it to decide whether to draw the divider above.
    private func footer(age: String?, failure: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let age {
                Text(age)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if let failure {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: Self.failureSymbolName)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text(failure)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Labels

    /// The figure over the headline bar: the fleet's weekly quota as it last
    /// arrived, stale or not.
    ///
    /// A named function rather than the property inline, so the rule is a thing a
    /// test can hold rather than a claim in a comment. It had a counterpart in
    /// `MenuBarIcon.percent` — the same reading with the menu bar's own freshness
    /// rule on it — until the menu bar stopped drawing the quota at all.
    static func headlinePercent(for snapshot: UsageSnapshot) -> Int? {
        snapshot.fleetSevenDayPercent
    }

    /// Past this age the allowance is not drawn at all — on this surface or on
    /// the menu bar — and the lead goes back to the weekly quota.
    ///
    /// Two of its own polling intervals (`UsageStore.allowanceIntervalSeconds`),
    /// built the same way `footerStaleSeconds` is built out of the fast halves':
    /// a figure that is *meant* to be up to ten minutes old is not stale at ten
    /// minutes, and past two intervals nothing is refreshing it at all.
    ///
    /// One constant because one rule: `historiesAreFresh` below is the whole of
    /// it, and it is read by this surface and by `MenuBarIcon.rates(for:now:)`.
    static let allowanceStaleSeconds: TimeInterval = 2 * UsageStore.allowanceIntervalSeconds

    /// Whether the half of the pass that brings the histories has said anything
    /// recently enough to draw. The one rule both surfaces read.
    ///
    /// **It asks the stamps and the blame and nothing else, which is one guard
    /// fewer than it used to ask.** The old form handed back the load figure and
    /// so required one to exist; that half of the condition could not decide
    /// anything, because the allowance it now gates is the stricter of the two —
    /// `sustainable` needs an account with a whole day of splittable history and
    /// a burn and a spend to price it by, and any account that clears that clears
    /// the six hours the load figure asked for. There was no snapshot in which a
    /// fresh allowance stood beside a missing load.
    ///
    /// **A failure of its own half.** The figure is frozen then, and the error is
    /// not one-directional, which is the whole of it. Measured with `/gw/usage`
    /// and `/gw/sessions` answering while `/history` returned HTTP 500 — the menu
    /// bar correctly dropped its colour and this line went on stating a red
    /// `≥134%` over a full red bar, with nothing on screen saying the figure had
    /// not been confirmed. A frozen 134% over a fleet that has since calmed down
    /// is a false alarm; a frozen green 80% over one that has gone to 200% is
    /// exactly the failure this metric was built to prevent. And the gateway's
    /// own bodies make it likely rather than exotic: `/gw/usage` is about 3 KB
    /// against 130–187 KB for one history (measured 2026-08-18), so a slow link
    /// delivers the quota and loses the histories.
    ///
    /// **And an age, because the failure is missing exactly where it is needed.**
    /// A `/gw/usage` outage skips the histories block whole (`UsageStore.poll`
    /// needs a freshly confirmed account list), so `allowanceFailure` stays
    /// `nil`, neither stamp moves, and a guard on the blame alone presents a
    /// two-hour-old allowance as current — with a red frame in the menu bar that
    /// nothing can clear, since up there the whole reading is this one answer.
    /// The quiet direction is the same failure mirrored: a frozen green figure
    /// over a fleet that has since gone past what it may spend.
    ///
    /// Dating it in the footer instead was the other answer and it is not enough
    /// on its own — it leaves the number itself stating the present, and it
    /// cannot reach the menu bar, which has no room for a caveat. The stamp is
    /// the arrival and never the attempt: the attempt moves on a failure and
    /// would call a frozen figure fresh (`UsageSnapshot.allowanceCheckedAt`).
    /// A figure with no arrival stamp at all is not shown either — every pass
    /// that produces one stamps it in the same breath, so an allowance without a
    /// stamp is a fixture, not a reading.
    static func historiesAreFresh(for snapshot: UsageSnapshot, now: Date = Date()) -> Bool {
        guard snapshot.allowanceFailure == nil,
              let fetchedAt = snapshot.allowanceFetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) < allowanceStaleSeconds
    }

    /// The two rates the lead states — or `nil` when the quota has to lead
    /// instead. The one rule the whole lead block reads: its figure, its caption,
    /// its bar, its colour and whether the supporting reading is drawn at all.
    struct HeadlineRates: Equatable {
        /// Input-equivalent tokens an hour, as the gateway measured them.
        let current: Double
        /// What may be spent an hour and still last the week. Always above zero
        /// — `FleetCapacity.sustainable` refuses rather than answering nothing
        /// an hour — which is what makes `fraction` a plain division.
        let allowance: Double
        /// The allowance was measured over a fleet that was partly blocked, so it
        /// reads high and everything drawn against it is a floor
        /// (`FleetCapacity.SustainableRate.isLowerBound`). Carried because the one
        /// surface that writes this ratio out as a number has to qualify it, and
        /// because a colour cannot carry a `≥`.
        let isLowerBound: Bool

        /// What the bar draws: the spend over its allowance, 1.0 being a fleet
        /// asking for exactly what it may have.
        ///
        /// Left unclamped on purpose, because clamping it here would be a second
        /// clamp: `QuotaBar` already refuses to draw past its own width, and a
        /// value this type had rounded down to 1 could no longer say by how much
        /// the allowance was passed. The clamp is a fact about the drawing, and
        /// it is measured where the drawing is
        /// (`testTheLeadBarFillsWithTheRatioAndStopsAtTheAllowance`).
        var ratio: Double { current / allowance }

        /// The same ratio in per cent, which is the unit the ramp's anchors are
        /// written in — and the unit this quantity has always been read in aloud:
        /// "155% of what we may spend".
        ///
        /// **This is what colours both surfaces**, and it is the figure the lead
        /// states rather than a second estimate of the same thing. The colour and
        /// the two numbers under it now come from one division, so the shade can
        /// no longer disagree with the reading it sits on.
        var percent: Double { ratio * 100 }

        /// The fleet is spending faster than it may. The ramp's green anchor and
        /// nothing else, because "spending at the allowance" is the state that
        /// anchor was put at (`greenRatioPercent`) — a boundary written twice is a
        /// boundary that can be moved once.
        var isOverAllowance: Bool { percent >= UsagePopoverView.greenRatioPercent }
    }

    /// The lead's two figures, or `nil` when either is missing.
    ///
    /// **Two sources, one gate.** The current rate comes with the quota half
    /// once a minute; the allowance comes with the histories once every ten
    /// minutes. The age ceiling and the blame that guard the second half are
    /// `historiesAreFresh`'s, and it is the one rule both surfaces share.
    ///
    /// The current rate is deliberately *not* given an age rule of its own. It is
    /// on the same one-minute stamp as the account rows below it, which this
    /// surface has always gone on drawing when a pass fails — stale beats blank
    /// here, and the footer says how stale (see `headlinePercent`).
    ///
    /// The menu bar draws this pair and nothing else — number, fill and colour —
    /// through `MenuBarIcon.rates`, which is this function under another name. So
    /// a gateway that reports quota but no token rate moves this headline back to
    /// the quota and leaves the menu bar with an empty dashed bar: the two
    /// surfaces answer the same question, and where this one can caption a
    /// fallback the other has no room to and so draws none (`MenuBarIcon.rates`).
    /// Neither states a number nobody measured, which is the agreement that was
    /// missing while the ramp read the week's estimated load — the menu bar went
    /// on warning in that state about a reading this surface had stopped showing.
    static func headlineRates(for snapshot: UsageSnapshot, now: Date = Date()) -> HeadlineRates? {
        guard historiesAreFresh(for: snapshot, now: now),
              let allowance = snapshot.sustainable,
              let current = snapshot.fleetTokenRate else { return nil }
        return HeadlineRates(current: current,
                             allowance: allowance.tokensPerHour,
                             isLowerBound: allowance.isLowerBound)
    }

    /// A token rate as this surface writes it: `23.8M/h`.
    ///
    /// One decimal and a magnitude letter, because the lead is read at a glance
    /// and nine digits of tokens an hour are not. The letter steps at each
    /// thousand rather than being fixed at millions, so an idle fleet reads
    /// `0/h` — zero is a real reading here, and dressing it up as `0.0M/h` would
    /// make a fleet that genuinely spends nothing look like one whose figure was
    /// rounded away.
    static func rateLabel(_ tokensPerHour: Double) -> String {
        for (scale, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "k")] where tokensPerHour >= scale {
            return String(format: "%.1f%@/h", tokensPerHour / scale, suffix)
        }
        return String(format: "%.0f/h", tokensPerHour)
    }

    /// The string in the headline's top row: the current spend when there are
    /// rates to state it against, the mean when there are not, and a dash when
    /// there is neither.
    ///
    /// A named function for the same reason `headlinePercent` is one — the
    /// fallback is a rule and a rule should be something a test can ask about.
    /// The rendering cannot: the picture is measured by its lines of ink, and
    /// `—` drawn where `100%` belongs is the same three lines of the same widths
    /// (checked by mutation, 2026-08-17 — the paint test stayed green).
    static func headlineFigureLabel(for snapshot: UsageSnapshot, now: Date = Date()) -> String {
        if let rates = headlineRates(for: snapshot, now: now) { return rateLabel(rates.current) }
        return quotaLabel(for: snapshot)
    }

    /// The weekly quota as the headline writes it — the string of the supporting
    /// reading under the lead, and the string the lead falls back to when there
    /// are no rates.
    ///
    /// One function for the two of them on purpose. They are the same reading,
    /// and written twice they could come to disagree — which on a surface that
    /// draws both at once would be the same number twice in two shapes.
    static func quotaLabel(for snapshot: UsageSnapshot) -> String {
        headlinePercent(for: snapshot).map { "\($0)%" } ?? "—"
    }

    /// The colour of that string: the ratio's own, or ink when the headline is
    /// back to being the mean.
    ///
    /// Named rather than written into the view, and the reason is that it was
    /// not: replacing the modifier with a flat `Color.primary` passed all 478
    /// tests (2026-08-17), which made this the one visible quantity on the
    /// surface with nothing holding it. The rule is here so a test can ask it,
    /// and `UsagePopoverPaintTests` asks the rendering as well — a function
    /// nobody calls would answer correctly for ever.
    ///
    /// The quota is deliberately not coloured, wherever it stands. Ink here when
    /// it is the lead, ink in the supporting reading below the lead, and in both
    /// places for the same reason: `QuotaBar.color(for:)` would give the figure a
    /// scale of its own — green, orange, red at 60% and 85% of a window — and a
    /// red `92%` over the ramp's own colour would be two scales for one number.
    /// The bar under it does take that scale, which is not the same claim: it is
    /// the shape of the reading rather than the reading written out, and it is
    /// drawn exactly as an account's window row is drawn.
    ///
    /// The plate travels with the question for the reason it travels with
    /// `ratioColor`: this figure is a colour drawn on the popover, and how dark
    /// it has to be to be read is a fact about the popover's own background.
    ///
    /// **The ramp is asked about the ratio this block states**, which is the
    /// figure over the caption's allowance and nothing else. It used to be asked
    /// about the week's estimated load instead — five minutes of measurement here
    /// against two days of estimate there — and on the live fleet 2026-08-24 the
    /// two answered 92.3% and 174.9%, which is a green figure over a red reading.
    /// A reader takes the shade for a reading of the number it is painted on, so
    /// the number and its colour now come from one division. The menu bar reads
    /// the same one (`MenuBarIcon`), so there is still one rule and not two.
    static func headlineFigureColor(for snapshot: UsageSnapshot,
                                    now: Date = Date(),
                                    on background: RampBackground) -> Color {
        headlineRates(for: snapshot, now: now)
            .map { ratioColor(atPercent: $0.percent, on: background) } ?? .primary
    }

    /// The spend ratio written out as a percentage **and qualified**, which since
    /// the lead became a pair of rates happens in exactly one place: the menu
    /// bar's accessibility description (`MenuBarIcon.describe`).
    ///
    /// The menu bar's picture prints the same ratio and neither qualification:
    /// no `≥`, because a mark costs a glyph out of a 27 pt column and §4 refuses
    /// one without measured need, and a figure capped at three digits, because
    /// the column has to hold it whole (`MenuBarIcon.ceilingPercent`). Both are
    /// facts about a width, so both are undone here, where a description has none
    /// — which is why this function is the icon's and not the drawing's.
    ///
    /// `≥` when the figure is only a floor, and the flag now belongs to the
    /// *allowance*: an account sat at its ceiling while it was measured, so the
    /// points it was blocked from burning never entered the measurement, the
    /// price of a point came out high, and the allowance with it. A high
    /// allowance makes a fleet look calmer than it is, so the ratio drawn against
    /// it is at least this one (`FleetCapacity.SustainableRate.isLowerBound`).
    /// The same symbol, for the same reason, that the panel's row and `--dump`
    /// put in front of a token sum they know only a lower bound of (§2.7). What
    /// it does *not* say is by how much — the requests an exhausted account
    /// refused leave nothing behind to count.
    ///
    /// **Printed through `%.0f` rather than through `Int`, and that is a guard
    /// rather than a style.** `Int(_: Double)` traps past `Int.max`, and this
    /// figure has no top of its own. `MenuBarIcon.label` meets the same hazard
    /// and clamps before converting, which it can afford because the column caps
    /// at three digits anyway; here the figure has to stay uncapped, so what goes
    /// is the conversion. `rounded()` first, so the digits are the ones `Int`
    /// would have produced, and `%.0f` after, which cannot trap on any finite
    /// `Double`.
    ///
    /// The route to such a figure is shorter than the one named over
    /// `MenuBarIcon.label`. An allowance approaching zero needs
    /// `capacity - sleepingWeek` within a few ULPs of nothing; the gateway's own
    /// body needs nothing unusual at all. `TokenCounts.perHour` admits every rate
    /// that comes out finite and non-negative — deliberately, and after being
    /// bitten by a `1e306` body once — so `"input_tokens": 1e300` is a valid body
    /// and a finite 3.6e303 tokens an hour, and against an ordinary allowance of
    /// 2e7 that is a ratio of 1.8e298. And it would trap *here* rather than in
    /// the drawing, because `MenuBarIcon.image` calls `describe` on every redraw
    /// whatever the picture then does with the number — so the clamp over there
    /// does not cover this path, which is the whole reason this one is not left
    /// to it. Verified by removal (2026-08-24): with `Int` back in this line and
    /// that pair of rates handed to `describe`, the process dies on `Fatal
    /// error: Double value cannot be converted to Int because the result would
    /// be greater than Int.max`, signal 5.
    static func ratioLabel(for rates: HeadlineRates) -> String {
        (rates.isLowerBound ? "≥" : "") + String(format: "%.0f%%", rates.percent.rounded())
    }

    /// The ratio the ramp is coldest at, and below which it stops moving.
    ///
    /// The three anchors are the owner's, in their words: "≤ 70 cold blue,
    /// 70 → 100 blue through cyan into green, 100 green, 100 → 130 green through
    /// yellow and orange, ≥ 130 red". They are readings, not colours — what
    /// happens between them is `ratioColor(atPercent:on:)` interpolating hue,
    /// which is what puts the cyan in the first stretch and the yellow and the
    /// orange in the second (§4).
    ///
    /// **What they are anchors on moved, and the numbers did not have to.** They
    /// used to be read against the week's estimated load, demand over supply; they
    /// are now read against the ratio the lead actually states, the current spend
    /// rate over its allowance. The two cross their middle anchor at the same
    /// instant — "demand has reached capacity" and "the rate has reached what it
    /// may be" are one statement rearranged — so 100 keeps its meaning exactly,
    /// and 70 and 130 keep the distance from it the owner chose them at.
    static let coldRatioPercent: Double = 70
    /// Where the ramp is green: a fleet spending exactly what it may. Named once
    /// because two rules have to agree about it — this ramp, and the step that
    /// decides whether the status item paints a warning at all
    /// (`HeadlineRates.isOverAllowance`, read by `MenuBarIcon.warningColor`).
    ///
    /// `nonisolated` because that second reader is: `HeadlineRates` is a plain
    /// value type and its members are not on the main actor, so a `static let` on
    /// this `@MainActor` view would be isolated away from it. Here the compiler
    /// says so — a warning under `-strict-concurrency=complete`, which the build
    /// has to be clean under — and that is the cheap end of this hazard; the
    /// expensive end is an `async` reader, where the same isolation drags the
    /// rest of the pass onto the main thread with no diagnostic at all
    /// (`UsageStore.windowSeconds` carries that story).
    nonisolated static let greenRatioPercent: Double = 100
    /// Where the ramp reaches red and stops moving. Not a ceiling on the figure —
    /// the headline goes on printing whatever it is handed — a ceiling on the
    /// colour, because past half again over the allowance there is nothing louder
    /// left to say.
    static let hotRatioPercent: Double = 130

    /// One end of the ramp, as a colour is written in this file.
    ///
    /// Hue, saturation and brightness rather than red, green and blue, because
    /// the ramp interpolates the first of the three and the other two come along
    /// with it.
    private struct RampAnchor {
        var hue: Double
        var saturation: Double
        var brightness: Double

        /// The same colour at another brightness, and at another saturation.
        /// Named because the legibility rule moves one coordinate at a time and
        /// the hue has to survive both moves untouched.
        func at(brightness value: Double) -> RampAnchor {
            RampAnchor(hue: hue, saturation: saturation, brightness: value)
        }

        func at(saturation value: Double) -> RampAnchor {
            RampAnchor(hue: hue, saturation: value, brightness: brightness)
        }
    }

    /// The three anchors, and they are this project's own colours rather than a
    /// palette invented for the ramp: measured in `aqua` 2026-08-18, these are
    /// `Color.blue`, `Color.green` and `Color.red` to four figures of hue —
    /// exactly the greens and reds `QuotaBar.color(for:)` fills an account's bar
    /// with. So the ramp *is* the family at its ends and only travels between
    /// them in the middle.
    ///
    /// That holds of what is written here and of nothing that is drawn: **both**
    /// plates move these numbers, and only the hue survives either of them
    /// (`legible(_:on:)`). On a light plate the drawn colour is this hue and this
    /// saturation at a lower brightness — the blue anchor is drawn at brightness
    /// 0.7955 there and the red at 0.7451. On a dark one brightness is already at
    /// the top of its scale for two of the three, so the lever is saturation
    /// instead: measured 2026-08-18, blue is drawn at saturation 0.6383 and red at
    /// 0.5228, while green — the one anchor that clears the floor as written —
    /// comes through untouched.
    ///
    /// Written out rather than read from the system colours at drawing time, and
    /// the reason is a measurement too. Resolved in all four appearances
    /// (2026-08-18), `Color.blue`, `Color.green` and `Color.red` answer the
    /// `aqua` figures in `vibrantLight` and `vibrantDark` alike — and the status
    /// item's button reports itself `vibrantDark` on this machine (§4) — so on
    /// the menu bar a constant is what the dynamic colour resolves to anyway.
    /// Only `darkAqua` differs, and by 0.04 of saturation on all three, plus 0.04
    /// of brightness on green and 0.003 of hue on blue: a hair, against the
    /// alternative, which is an
    /// `NSColor` with a dynamic provider — and two of those cannot be compared
    /// for equality, which is exactly what the menu bar and the popover are
    /// checked against each other with.
    private static let coldAnchor = RampAnchor(hue: 0.5869, saturation: 1.000, brightness: 1.000)
    private static let greenAnchor = RampAnchor(hue: 0.3586, saturation: 0.805, brightness: 0.804)
    private static let hotAnchor = RampAnchor(hue: 0.0089, saturation: 0.812, brightness: 1.000)

    /// The plate a ramp colour is drawn on, and everything the legibility rule
    /// below needs to know about it.
    ///
    /// Two cases because the app paints on two kinds of plate, and all four were
    /// measured rather than assumed (2026-08-18, this machine): the menu bar by
    /// screenshot of a 400 by 20 pixel strip, the popover by rendering
    /// `NSVisualEffectView` at `.popover` in each appearance.
    ///
    ///     light   menu bar rgb 0.883    popover rgb 0.9341
    ///     dark    menu bar rgb 0.17     popover rgb 0.2274
    ///
    /// All four came back a flat neutral grey, one value across every pixel,
    /// because this machine has "Reduce transparency" on — which is also the only
    /// reason a plate is a measurable thing at all. Without it the menu bar is
    /// the wallpaper seen through a wash, and the day that setting goes off these
    /// four numbers become a typical case rather than the surface itself.
    ///
    /// Each case carries the **least favourable** member of its family: the
    /// darkest light plate and the lightest dark one. A colour that clears the
    /// floor against these clears it against the other surface of the same kind
    /// by more, which is what lets one rule serve both.
    enum RampBackground {
        case light
        case dark

        /// The plate as an sRGB grey. One component says all of it: the four
        /// measurements are neutral to four decimals.
        var grey: Double {
            switch self {
            case .light: return 0.883
            case .dark: return 0.2274
            }
        }

        /// What the contrast arithmetic asks of it: 0.7541 light, 0.0423 dark.
        var relativeLuminance: Double {
            UsagePopoverView.relativeLuminance((grey, grey, grey))
        }

        /// The calm mark the warning replaces, as it lands on this plate: the
        /// bar's frame, which is `labelColor` at `calmFrameOpacity`
        /// (`MenuBarIcon.drawBar`) composited over `grey`.
        ///
        /// `labelColor` is black on a light plate and white on a dark one, and
        /// the opacity is absolute rather than a multiple of the colour's own —
        /// `withAlphaComponent` replaces the alpha, it does not scale it. So the
        /// composite is arithmetic rather than a measurement, and the rendering
        /// agrees with it: 0.397 measured against 0.397 here on the light plate,
        /// 0.650 against 0.652 on the dark one (2026-08-18, the drawn picture over
        /// its plate, `testTheWarningIsNeverQuieterThanTheCalmStateItReplaces`).
        var calmInkGrey: Double {
            switch self {
            case .light: return grey * (1 - UsagePopoverView.calmFrameOpacity)
            case .dark: return grey + UsagePopoverView.calmFrameOpacity * (1 - grey)
            }
        }
    }

    /// The contrast every ramp colour has to reach against the plate under it.
    ///
    /// **A warning may never be less legible than the calm state it replaces**,
    /// and this is the operational half of that rule. What it replaced was a
    /// luminance ceiling that clamped the ramp to the green anchor's own
    /// brightness — and the ceiling was built and quoted in *gamma* space, Rec.
    /// 709 weights laid straight on sRGB components that WCAG requires
    /// linearised first, so the contrast it claimed to buy was never the contrast
    /// on screen. Rendered and measured properly (2026-08-18, on the light menu
    /// bar plate rgb 0.883): crossing capacity took the number from ink at 11.61
    /// to 1 down to the ramp's green at 1.62, and the frame from 4.41 to 1.35. The
    /// picture faded exactly where it was supposed to light up — its worst point
    /// being 1.35 to 1, which is a shape nobody can see at all.
    ///
    /// 4.5 is WCAG's floor for text below 18 pt, and the smallest thing either
    /// surface paints in this colour is the menu bar's number at 9 pt. It is used
    /// for everything the ramp paints — the fill, the frame, the popover's figure
    /// and its bar — rather than giving the graphics their own looser 3 to 1,
    /// because a picture 27 points wide may not carry two brightnesses of one
    /// reading. The graphics floor is met with room to spare, which is the point
    /// of taking the stricter one.
    static let minimumContrastRatio: Double = 4.5

    /// The opacity the calm bar frame is drawn at (`MenuBarIcon.drawBar`).
    ///
    /// It lives here rather than beside the drawing because the floor below is
    /// derived from what this opacity produces: the rule is about a warning
    /// against the calm mark it replaces, and the calm mark is `labelColor` at
    /// this opacity. Two copies of the number would let the rule and the drawing
    /// disagree about what "the calm state" is, silently.
    ///
    /// `nonisolated` so `RampBackground` — a nested type, which does not inherit
    /// this view's isolation — can read it. The note on `relativeLuminance` has
    /// the whole of that argument.
    nonisolated static let calmFrameOpacity: Double = 0.55

    /// What every colour on the ramp has to reach against the plate it is drawn
    /// on: the WCAG floor, or the calm state's own contrast when that is higher.
    ///
    /// **The floor is derived from the calm state and not fixed, because the rule
    /// is a comparison and not a number.** "A warning may never be less legible
    /// than the calm state it replaces" says nothing about 4.5 to 1; it says the
    /// warning wins against whatever the calm frame measures on this plate. A
    /// fixed 4.5 happened to satisfy it on the light plate — the calm frame is
    /// 4.44 there, so the margin was 0.06 of arithmetic coincidence — and failed
    /// it on the dark one, where the calm frame is 4.69 and the ramp was left at
    /// 2.83 (cold) and 3.20 (red). Derived, the ordering holds on both by
    /// construction.
    ///
    /// **By construction as `≥`, and at the hot end that is equality**, which is
    /// worth saying plainly: on the dark plate this floor *is* the analytic calm
    /// frame, and `legible` moves a colour until it reaches the floor and no
    /// further, so from 124.9% up the warning frame aims at exactly the number it
    /// has to beat. The margin that shows on screen comes from antialiasing
    /// rather than from the rule — rendered, the warning frame measures 4.69 at
    /// 130% and 150% against the calm frame's 4.67 (2026-08-18) — and it points
    /// this way because the calm stroke is drawn at `calmFrameOpacity` while the
    /// warning stroke is opaque, so partial coverage costs the calm one more.
    ///
    /// Measured 2026-08-18 on this machine's plates: **4.50 on the light plate**
    /// (the calm frame is 4.44 there, so `minimumContrastRatio` is what binds) and
    /// **4.69 on the dark one** (the calm frame binds, and WCAG's floor is what
    /// does not).
    ///
    /// What it deliberately does *not* take for the calm state is the calm
    /// **number**, which is `labelColor` at full strength — 11.61 to 1 on the
    /// light plate and 8.57 on the dark one. No colour that keeps a hue reaches
    /// either: on the dark plate the red would need its saturation down at 0.17 to
    /// measure 8.57, which is a pink, and the light plate has no room at all. That
    /// shortfall is real and named rather than hidden — the number over capacity
    /// is a coloured number, and the price of colour is that it is quieter than
    /// ink. The frame is what the rule is held to because the frame is what the
    /// warning replaces mark for mark.
    static func contrastFloor(on background: RampBackground) -> Double {
        max(minimumContrastRatio,
            contrastRatio(relativeLuminance((background.calmInkGrey,
                                             background.calmInkGrey,
                                             background.calmInkGrey)),
                          background.relativeLuminance))
    }

    /// WCAG contrast between two relative luminances, in either order.
    nonisolated static func contrastRatio(_ one: Double, _ other: Double) -> Double {
        (max(one, other) + contrastOffset) / (min(one, other) + contrastOffset)
    }

    /// What WCAG adds to both luminances before dividing them. Named because the
    /// floor is solved for a luminance rather than searched for by ratio, and the
    /// constant appears on both sides of that arithmetic.
    nonisolated private static let contrastOffset: Double = 0.05

    /// The colour of a spend ratio on the plate it will be drawn on: a ramp from
    /// cold blue through green to red, pinned at the three anchors above and flat
    /// outside them, darkened where the plate underneath would otherwise swallow
    /// it.
    ///
    /// **A ramp and not a step, by the owner's decision.** Both surfaces switched
    /// on one boundary before — green below 100, red at or above — and a single
    /// step says nothing at all about a fleet at 40% against one at 95%, which is
    /// the difference between a week with room in it and a week about to run out.
    /// The hue is what carries the reading; the intermediate colours are not
    /// picked, they are where linear interpolation lands, which is cyan on the
    /// way from blue to green and yellow then orange on the way from green to
    /// red.
    ///
    /// **A per cent rather than a figure to look inside, and that is the point.**
    /// What is handed in is the ratio the lead states — `HeadlineRates.percent`,
    /// the measured spend rate over the allowance — and both surfaces hand in the
    /// same one. It used to be the week's estimated *load*, a second estimate of
    /// the same quantity over a different timescale, and the shade is what a
    /// person reads.
    ///
    /// **The two did not merely disagree about the shade — in the shipped
    /// configuration they could disagree about the verdict, and the agreement
    /// argument does not cover it.** That argument is real but narrow: demand
    /// reaching capacity and the rate reaching its allowance are one statement
    /// rearranged *when the load's numerator is the recent work rate*, which is
    /// the projection's numerator and not the window average's. The default
    /// window was two days, so the default path was the window average — a flat
    /// mean over sleep and work alike, which is a different quantity and crosses
    /// nothing in step. Measured on the live fleet 2026-08-24: the retired
    /// estimator answered **92.3%** where the lead's own figures answered
    /// **174.9%** — hue 150.2 degrees against 3.2, a green against a red, on
    /// opposite sides of the anchor. Both numbers are true and they answer
    /// different questions; only one of them is the question the block asks.
    ///
    /// **The plate is an argument because the answer depends on it.** The hue
    /// does not: at every reading it is the same on both plates, to the last
    /// decimal, and it is the hue that carries the meaning. What the plate moves
    /// is how light the colour has to be drawn — down on a light plate, up on a
    /// dark one — measured at nine readings in
    /// `testTheRampMeetsItsContrastFloorOnEveryPlate`.
    static func ratioColor(atPercent percent: Double, on background: RampBackground) -> Color {
        let anchor = legible(rampAnchor(at: percent), on: background)
        return Color(hue: anchor.hue,
                     saturation: anchor.saturation,
                     brightness: anchor.brightness)
    }

    /// Where the ramp stands at a reading, before the plate has had its say.
    private static func rampAnchor(at percent: Double) -> RampAnchor {
        if percent <= coldRatioPercent { return coldAnchor }
        if percent < greenRatioPercent {
            return mix(coldAnchor, greenAnchor,
                       (percent - coldRatioPercent) / (greenRatioPercent - coldRatioPercent))
        }
        if percent < hotRatioPercent {
            return mix(greenAnchor, hotAnchor,
                       (percent - greenRatioPercent) / (hotRatioPercent - greenRatioPercent))
        }
        return hotAnchor
    }

    /// The anchor as it may be drawn on this plate: the same hue, moved until it
    /// clears `contrastFloor(on:)`.
    ///
    /// **The hue never moves, and the direction of everything else follows the
    /// plate.** A colour is pulled away from a light plate by darkening and away
    /// from a dark one by lightening, and the plate is what says which. The
    /// previous rule had only the first half — it lowered brightness and nothing
    /// else — so on a dark plate it could not reach the floor at all and left the
    /// ramp raw, which is how crossing capacity came to draw a *dimmer* picture
    /// than the calm state it replaced: red at 3.20 against the calm frame's 4.67
    /// (2026-08-18, both rendered off the status item's bitmap). 4.69 is the
    /// *analytic* calm frame on this plate, and it is also `contrastFloor(.dark)`
    /// — quoting it beside a rendered 3.20 was comparing two different
    /// measurements.
    ///
    /// Lightening is two levers, in this order, and both keep the hue:
    ///
    /// 1. **Brightness up to the top of its scale.** Free, and enough on its own
    ///    for anything on the green half of the ramp.
    /// 2. **Saturation down.** At brightness 1 a hue's luminance is fixed by its
    ///    saturation alone, and lowering it is travel along the tint line towards
    ///    white — the hue is preserved exactly, which is what "keep the hue"
    ///    asks for. It is the only lever left once brightness is spent, and two
    ///    of the three anchors are written at brightness 1 already.
    ///
    /// The cost is named rather than hidden: on the dark plate the cold blue is
    /// drawn at saturation 0.6383 and the red at 0.5228, which is a paler blue and
    /// a red with white in it. That is what a floor of 4.69 to 1 costs a hue whose
    /// fully saturated luminance is 0.2126. Desaturating on a *light* plate would
    /// be the opposite mistake — there the colour has to get further from a light
    /// background, and washing it out moves it closer — which is why the two
    /// directions are a `switch` on the plate rather than one rule that guesses.
    private static func legible(_ anchor: RampAnchor,
                                on background: RampBackground) -> RampAnchor {
        let floor = contrastFloor(on: background)
        switch background {
        case .light:
            let ceiling = (background.relativeLuminance + contrastOffset) / floor - contrastOffset
            guard luminance(of: anchor) > ceiling else { return anchor }
            // A ceiling at or under zero would mean no colour can clear the
            // floor, and the bisection answers that honestly — it converges on
            // black, the darkest thing there is, and the assertion that every
            // mark stays chromatic then fails loudly. There is no guard for the
            // case because a guard here could only return the colour *unchanged*,
            // which is the silent failure this whole rule exists to end.
            //
            // Luminance rises with brightness and never falls, so the largest
            // brightness under the ceiling is a bisection rather than a search
            // with an answer to check. Twenty-four halvings of the unit interval
            // leave 6e-8, three orders under the byte the colour is finally drawn
            // as.
            var low = 0.0
            var high = anchor.brightness
            for _ in 0..<24 {
                let middle = (low + high) / 2
                if luminance(of: anchor.at(brightness: middle)) > ceiling {
                    high = middle
                } else {
                    low = middle
                }
            }
            return anchor.at(brightness: low)
        case .dark:
            let target = floor * (background.relativeLuminance + contrastOffset) - contrastOffset
            guard luminance(of: anchor) < target else { return anchor }
            let lit = anchor.at(brightness: 1)
            if luminance(of: lit) >= target {
                // The dimmest brightness that still clears the floor: the anchor
                // keeps as much of its own darkness as the plate allows.
                var low = anchor.brightness
                var high = 1.0
                for _ in 0..<24 {
                    let middle = (low + high) / 2
                    if luminance(of: anchor.at(brightness: middle)) < target {
                        low = middle
                    } else {
                        high = middle
                    }
                }
                return anchor.at(brightness: high)
            }
            // Brightness is spent. Luminance falls as saturation rises, so the
            // most saturated colour that still clears the floor is the same
            // bisection the other way round — and if even white cannot reach the
            // target the answer is white, which is what `low` stays at.
            var low = 0.0
            var high = lit.saturation
            for _ in 0..<24 {
                let middle = (low + high) / 2
                if luminance(of: lit.at(saturation: middle)) >= target { low = middle } else { high = middle }
            }
            return lit.at(saturation: low)
        }
    }

    private static func mix(_ from: RampAnchor, _ to: RampAnchor, _ position: Double) -> RampAnchor {
        RampAnchor(hue: from.hue + (to.hue - from.hue) * position,
                   saturation: from.saturation + (to.saturation - from.saturation) * position,
                   brightness: from.brightness + (to.brightness - from.brightness) * position)
    }

    private static func luminance(of anchor: RampAnchor) -> Double {
        relativeLuminance(components(of: anchor))
    }

    /// The sRGB components of an anchor at a brightness — the standard HSB
    /// conversion, and the one `Color(hue:saturation:brightness:)` performs.
    ///
    /// Checked against it rather than assumed: at the three anchors the round
    /// trip through `NSColor` gives back the hue, saturation and brightness
    /// handed in, to the four decimals they are written with.
    private static func components(of anchor: RampAnchor) -> (red: Double, green: Double, blue: Double) {
        let brightness = anchor.brightness
        let sector = (anchor.hue * 6).truncatingRemainder(dividingBy: 6)
        let falling = 1 - anchor.saturation * abs(sector.truncatingRemainder(dividingBy: 2) - 1)
        let low = 1 - anchor.saturation
        let channels: (red: Double, green: Double, blue: Double)
        switch Int(sector) {
        case 0: channels = (1, falling, low)
        case 1: channels = (falling, 1, low)
        case 2: channels = (low, 1, falling)
        case 3: channels = (low, falling, 1)
        case 4: channels = (falling, low, 1)
        default: channels = (1, low, falling)
        }
        return (channels.red * brightness, channels.green * brightness, channels.blue * brightness)
    }

    /// WCAG relative luminance of an sRGB triple: **linearise each component,
    /// then weigh**.
    ///
    /// The linearisation is the whole of it and it was missing here. Rec. 709
    /// weights laid on gamma-encoded components produce a number that looks like
    /// a luminance and is not one, and every contrast quoted from it was wrong in
    /// a direction that flattered the ramp: the raw colour at 115% reads 1.19 to 1
    /// that way against 1.39 in truth, and the ceilinged one 1.55 against 2.48.
    /// The claim built on those figures — that the ceilinged colour has "exactly
    /// the contrast `Color.green` itself has" — was an artefact of the mistake,
    /// true only in gamma space because the ceiling was defined in gamma space.
    /// Linearised the two are 2.48 and 2.12, and neither reaches the 3 to 1 that
    /// graphics need, let alone the 4.5 of text (all measured 2026-08-18 against
    /// white, which is the background those figures were quoted against).
    ///
    /// `nonisolated` because `RampBackground` is a nested type and nested types
    /// do not inherit the enclosing view's main-actor isolation: without it the
    /// plate's own luminance is a main-actor call from a place that is not on the
    /// main actor, which under `-strict-concurrency=complete` is a warning and in
    /// an `async` caller would be the hop §6 records. It reads no state, so there
    /// is nothing for the isolation to protect.
    nonisolated static func relativeLuminance(_ colour: (red: Double, green: Double, blue: Double)) -> Double {
        0.2126 * linearised(colour.red)
            + 0.7152 * linearised(colour.green)
            + 0.0722 * linearised(colour.blue)
    }

    nonisolated private static func linearised(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    /// A utilisation as the popover writes it. A dash when the gateway had no
    /// reading — never a zero (§2.4: a confidently wrong figure is worse than a
    /// missing one).
    static func percentLabel(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// When a window starts over. Empty when the gateway named no reset — the row
    /// has a dash in the percentage already, and a second one adds nothing.
    ///
    /// The rule is one: **the smallest unit written is always explicit**. A bare
    /// unit is a floor and therefore a range — `in 1d` is anything from 24 hours
    /// to 48, `in 1h` anything from 60 minutes to 119 — and the range covers the
    /// very difference the row is looked at for. The user asked both questions in
    /// turn, "19 hours? 26?" of the days and "an hour and a half? five minutes?" of
    /// the hours; neither label could answer.
    ///
    /// So the lower unit is printed even when it is zero: `in 5d 0h` and `in 4h 0m`
    /// are countdowns measured to that unit, while a bare `in 5d` or `in 4h` is
    /// exactly the ambiguity being removed. Days stop at the hour — an hour is the
    /// precision that was asked for, and `in 5d 3h 20m` says nothing the row needs.
    static func resetLabel(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "resets now" }
        if seconds < 3600 {
            // Minutes round up, so a window with 30 seconds left says `in 1m`
            // rather than `in 0m`. The last minute below an hour rounds up to 60
            // of them, and `in 60m` is an hour written the long way — carried by
            // hand, because the branch below floors and would write `in 0h 59m`
            // for the same instant.
            let minutes = Int((seconds / 60).rounded(.up))
            return minutes < 60 ? "in \(minutes)m" : "in 1h 0m"
        }
        // Hours and days go down, and so does the remainder beside them: this is a
        // countdown, and rounding any of it up would promise time that is not
        // there. Which is also why the carry above is only at that one seam —
        // rounding the whole countdown up to the minute would turn 1d 23h 59m into
        // `in 2d 0h`.
        if seconds < 86_400 {
            let hours = Int(seconds / 3600)
            return "in \(hours)h \(Int((seconds - Double(hours) * 3600) / 60))m"
        }
        let days = Int(seconds / 86_400)
        return "in \(days)d \(Int((seconds - Double(days) * 86_400) / 3600))h"
    }

    /// What a section with nothing in it says, and the middle state is the whole
    /// point of it: "we have not asked yet" is not "we asked and there is
    /// nothing". Before the first answer the popover used to state things about
    /// the gateway the gateway had never said, with the footer next to it
    /// truthfully reporting that nothing had been fetched at all.
    ///
    /// Three states, not two, because "loading" that can never end is its own
    /// lie: a gateway that was down at launch never lands a first answer, and
    /// the reason is spelled out in the failure line right underneath.
    static func emptyLabel(landed: Bool, failed: Bool, nothing: String) -> String {
        guard landed else { return failed ? "Gateway did not answer" : "Loading…" }
        return nothing
    }

    /// What the accounts section says when it has nobody to list.
    ///
    /// One of the two callers of `emptyLabel`, and a named function rather than
    /// an expression at the call site because the whole meaning of that label
    /// lives in these arguments: the pure function was under test while what was
    /// handed to it was not, and that is where the chart's defect below sat
    /// unnoticed.
    static func accountsEmptyLabel(_ snapshot: UsageSnapshot) -> String {
        emptyLabel(landed: snapshot.quotaFetchedAt != nil,
                   failed: snapshot.quotaFailure != nil,
                   nothing: "The gateway named no accounts")
    }

    /// What the chart says when it has no line to draw.
    ///
    /// `landed` is about the *series* and about nothing else. Told from the
    /// stamp of the last finished pass, it called a pass in which every account
    /// failed an answer, and the chart then stated that the period held no data
    /// — which the gateway had not said and could not have, having said nothing
    /// at all.
    ///
    /// The second half of it is the case with no request in it: an empty account
    /// list means there is nobody to ask, so no pass can ever make the series
    /// land. That is only an answer once the quota poll itself has landed —
    /// before that the empty list means "not asked yet" and the chart must say
    /// so.
    ///
    /// `failed` names both halves the chart depends on: the quota poll, which is
    /// where the account list comes from, and the history requests themselves.
    ///
    /// And "landed" is also about the period being asked about right now. The
    /// lines from the tab before are an answer to a different question, so
    /// between a change of period and the pass that answers it this section has
    /// nothing landed at all — which is "Loading…", not "the period held no
    /// data" about a period nobody has asked the gateway for yet. The other half
    /// of `landed` needs no such clause: an empty account list means there is
    /// nobody to ask for any period.
    static func plotEmptyLabel(snapshot: UsageSnapshot,
                               seriesFetchedAt: Date?,
                               seriesPeriod: HistoryPeriod?,
                               period: HistoryPeriod,
                               historyFailure: String?) -> String {
        let landed = (seriesFetchedAt != nil && seriesPeriod == period)
            || (snapshot.quotaFetchedAt != nil && snapshot.accounts.isEmpty)
        return emptyLabel(landed: landed,
                          failed: snapshot.quotaFailure != nil || historyFailure != nil,
                          nothing: "No data for this period")
    }

    /// The reasons behind what this view draws, all of them at once.
    ///
    /// The three halves are the three this popover shows: the quota poll, the
    /// chart's own requests, and the histories behind the allowance.
    /// `UsageSnapshot.failureText` is still the wrong source — it also carries
    /// `/gw/sessions`, whose figures live in the panel's rows and not one of
    /// which is on this surface. Shown instead of the chart's own reason (and it
    /// was, being first), it left an empty chart with its cause named nowhere
    /// while explaining a number the user cannot see.
    ///
    /// Which is the argument for the allowance half rather than against it: the
    /// test is whether the reader can see the figure the reason is about, and
    /// this one's figure is the largest thing on the screen. Without it the
    /// headline stated a reading nobody had confirmed since the outage began,
    /// with the whole footer silent about why.
    ///
    /// All of them when all of them failed, for the same reason: they are
    /// separate questions, and the first non-empty of them is not an answer to
    /// the others.
    static func failureText(quota: String?, history: String?,
                            allowance: String?) -> String? {
        let all = [quota, history, allowance].compactMap { $0 }
        return all.isEmpty ? nil : all.joined(separator: "; ")
    }

    /// Below this age the footer says nothing about it at all.
    ///
    /// Two polling intervals: both halves of this view are asked for again once a
    /// minute (`UsageHistoryModel.refreshSeconds`, and `UsageStore` on the same
    /// interval), so anything younger than two of them is the poll running
    /// normally rather than data going stale. A footer that reported it would be
    /// a line of text saying "everything is fine", redrawn four times a minute,
    /// under numbers that are already as fresh as they can be.
    static let footerStaleSeconds: TimeInterval = 120

    /// How old the oldest thing on this surface is — or `nil` when the footer has
    /// no business saying.
    ///
    /// One line, not two. The quota and the chart used to be dated separately, and
    /// with both halves polled once a minute under an open popover the two
    /// sentences moved together and said the same thing twice. What is left is the
    /// **older** of the two, because the age of a screen is the age of the oldest
    /// thing on it.
    ///
    /// The chart only counts while its lines answer the period being asked about:
    /// after a tap on `30d` the stamp in hand belongs to the previous window's
    /// lines, which the plot is no longer drawing, and it says "Loading…" itself.
    ///
    /// **The allowance is not dated here at all, and that is an exclusion made
    /// deliberately rather than a consequence of the rule above.**
    /// `footerStaleSeconds` is 120 s because the two halves it was built for are
    /// refetched every minute; the allowance half is refetched every ten. Fold its
    /// stamp into the maximum and any age from 120 s to `allowanceStaleSeconds` puts
    /// an age line under a perfectly healthy popover — a permanent `as of 7m ago`
    /// that reports nothing except that two schedules exist, and dates the whole
    /// surface by the one half designed to be minutes old.
    ///
    /// The price is real and worth naming rather than arguing away: this line can
    /// understate the oldest thing on screen by up to `allowanceStaleSeconds`
    /// (1200 s), and up to 600 s of that can be the allowance's schedule
    /// **standing still** rather than running slowly. `UsageStore.poll` skips the
    /// entire allowance block when the quota half fails (`result.quotaFailure ==
    /// nil` guards it), so no attempt is made, neither stamp moves and
    /// `allowanceFailure` stays `nil`. A pass at t=0 stamps everything; the quota
    /// lands again at t=590; `/gw/usage` starts failing at t=600. At t=1000 the
    /// headline still draws the figure (1000 < 1200) while this line, broken out
    /// of silence by the quota failure, reports the quota's age: `as of 6m ago`
    /// over a headline figure older than sixteen minutes. What closes that gap is
    /// `allowanceStaleSeconds` removing the figure, not the footer ageing it — the
    /// alternative costs a standing age line on every healthy popover, which is
    /// the trade refused above.
    ///
    /// Folding the stamp in on a failure is what stood here, and it
    /// dated a screen by a figure the same failure had already removed: with
    /// `/history` down for two hours and everything else seconds old, the footer
    /// said `as of 2h ago` under a popover where every drawn value was fresh, by
    /// as much as the process had been running.
    ///
    /// Silence has two reasons and they are different. Nothing fetched at all is
    /// not a matter of age — the sections above say "Loading…" or name the
    /// gateway's failure — so there is nothing to date. Fresh data is silence
    /// because there is nothing to warn about. A failed last check breaks the
    /// second one at any age: with the numbers standing still and the checks
    /// failing, how old they are is the only thing telling live figures from
    /// frozen ones, and `footerStaleSeconds` would hide it for the first two
    /// minutes of every outage. `allowanceFailed` is in that list although the
    /// allowance carries no stamp here — what it dates is then the halves that
    /// *are* on screen, and one of the three having gone quiet is the moment to
    /// say how old the rest is.
    static func footerAgeLabel(quotaFetchedAt: Date?,
                               quotaFailed: Bool,
                               chartFetchedAt: Date?,
                               seriesPeriod: HistoryPeriod?,
                               period: HistoryPeriod,
                               chartFailed: Bool,
                               allowanceFailed: Bool,
                               now: Date) -> String? {
        let chart = seriesPeriod == period ? chartFetchedAt : nil
        guard let oldest = [quotaFetchedAt, chart].compactMap({ $0 }).min() else { return nil }
        guard quotaFailed || chartFailed || allowanceFailed
                || now.timeIntervalSince(oldest) >= footerStaleSeconds else { return nil }
        return "as of \(ago(oldest, now: now))"
    }

    /// Whether the footer has nothing at all to draw — in which case the divider
    /// above it is not drawn either. A rule hanging across the bottom of the
    /// popover with nothing under it is worse than no rule.
    static func footerIsSilent(age: String?, failure: String?) -> Bool {
        age == nil && failure == nil
    }

    /// How long ago a moment was, in the coarsest unit that still says anything.
    ///
    /// Not finer than a minute, because that is how often the figures are asked
    /// for: a footer counting seconds would spend most of its life saying
    /// something that stopped being true a moment after it was drawn.
    static func ago(_ moment: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(moment))
        if seconds < 60 { return "less than a minute ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}

// MARK: - Bar

/// A quota window as a bar. Both bars own their colour now — the menu bar's
/// picture stopped being a template (`MenuBarIcon`, `isTemplate = false`), so
/// the system tints nothing up there either, and "we may use colour and they
/// may not" is no longer the difference between the two surfaces.
///
/// Nor is the amount of colour each can carry. That stood here — this bar being
/// a full-width capsule on a surface the user has deliberately opened while the
/// menu bar's is a few points wide beside the clock, so one could hold a scale
/// and the other one bit — and the owner overruled it: the ratio is drawn with a
/// continuous ramp on both surfaces (`UsagePopoverView.ratioColor`), because a
/// glance that can tell green from red can tell blue from green just as well,
/// and a step made a fleet at 40% look like a fleet at 95%.
///
/// What differs is the *quantity*, which is what `color(for:)` below is about:
/// it answers "how full is this window", the reading an account's row and the
/// headline's supporting block draw, and its 60 and 85 per cent are thresholds
/// on that. A caller filling a bar with anything else hands in its own `tint`.
struct QuotaBar: View {
    /// 0…1, or `nil` when there is no reading — then the bar is only its track.
    let fraction: Double?
    var height: CGFloat = 6
    /// The fill colour when the caller has a rule of its own. `nil` leaves it to
    /// `color(for:)`, which answers "how full is this account's window" — the
    /// headline's lead bar is filled by a different quantity and coloured by the
    /// ratio's ramp (`UsagePopoverView.ratioColor`).
    var tint: Color?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if let fraction {
                    Capsule()
                        .fill(tint ?? Self.color(for: fraction))
                        .frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
            }
        }
        .frame(height: height)
    }

    /// Semantic system colours, so they follow light and dark appearance — the
    /// same rule the row's indicator follows (§4).
    static func color(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: return .green
        case ..<0.85: return .orange
        default: return .red
        }
    }
}
