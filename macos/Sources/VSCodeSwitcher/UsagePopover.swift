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

    /// What the headline says when there is a load figure to say it about, and
    /// it names a different quantity from the caption above: not how much of the
    /// week is spent, but how much of the week is being asked for. `126%` reads
    /// "a quarter more than the week holds".
    ///
    /// No jargon and no internal vocabulary — the word this metric is called by
    /// inside the app appears in no string on this surface (§4).
    static let loadCaption = "of weekly capacity across accounts"

    /// The headline's bar, taller than the ones on the account rows because it
    /// belongs to the figure this popover is opened for.
    ///
    /// A constant for the reason the dot's size is one: the test that holds its
    /// colour finds it by its size — nothing else in the picture is a patch
    /// exactly this tall — and a copy of the number in the test would be a test
    /// about a bar that no longer exists.
    static let headlineBarHeight: CGFloat = 8

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
                                      loadFailed: usage.snapshot.fleetLoadFailure != nil,
                                      now: history.now)
        let failure = Self.failureText(quota: usage.snapshot.quotaFailure,
                                       history: history.failure,
                                       load: usage.snapshot.fleetLoadFailure)
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

    /// The same reading the menu bar draws, rounded in the same one place
    /// (`UsageSnapshot.fleetSevenDayPercent`) — the icon is a summary of this
    /// line, and two ways of working out what it says would drift apart the day
    /// one of them changes.
    ///
    /// What the two do *not* share is the freshness rule, and only this side may
    /// keep the figure. The menu bar blanks it when the last pass failed,
    /// because up there is no room to say "as of an hour ago" and a bare
    /// percentage with no such caveat reads as the truth right now (§2.4). Here
    /// there is room, and the footer uses it. Gating this line the same way put
    /// a dash over the account rows right below it, which go on showing their
    /// stored percentages — two contradicting statements on one screen, and the
    /// dash was the false one: the number is known, it is merely old.
    /// Three rows rather than "figure, caption beside it, bar", and the reason is
    /// measured (§4): the caption is 206 pt of a 292 pt line, so beside a figure it
    /// only fits while the figure is short. `52%` leaves it 219 pt and `100%` leaves
    /// 199.5 — the caption then wraps, and a wrapped caption is the complaint this
    /// headline was rebuilt for. On its own row it has the whole width and one line
    /// is one line whatever the figure says.
    ///
    /// What stands in those three rows is the load when there is one, and the
    /// mean utilisation when there is not. All three rows switch together, and
    /// that is the point of doing it here rather than adding a fourth row: the
    /// caption names the figure and the bar is the figure drawn, so a bar left
    /// showing the mean under a caption that says "capacity" would be the two
    /// contradicting statements on one screen that this very headline already
    /// refused once (see `headlinePercent`).
    ///
    /// **A `nil` load falls back to exactly the old drawing, and nothing is
    /// invented in its place.** `FleetCapacity.load` answers `nil` when the
    /// gateway said nothing, when no account has six hours of history to
    /// extrapolate from, and when every account spent the whole window pinned at
    /// its ceiling — and from here those three are one state, because the metric
    /// hands back no way to tell them apart. Two of them are cases where the
    /// truthful answer is "unknown" and the third is a fleet in the worst
    /// trouble it can be in; a number that split the difference would be wrong
    /// for all three (§2.7).
    private var headline: some View {
        // The clock the whole popover reads, which ticks while it is open: one
        // of the load's two rules is an age, so a figure that goes stale under an
        // open popover has to leave the headline without waiting for a click.
        let load = Self.headlineLoad(for: usage.snapshot, now: history.now)
        let percent = Self.headlinePercent(for: usage.snapshot)
        return VStack(alignment: .leading, spacing: 6) {
            // Tighter than the gap above the bar, because the words belong to the
            // figure: they say which quota it is.
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.headlineFigureLabel(for: usage.snapshot, now: history.now))
                    .font(.system(size: 30, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Self.headlineFigureColor(for: usage.snapshot, now: history.now))
                Text(load == nil ? Self.headlineCaption : Self.loadCaption)
                    .font(.system(size: Self.headlineCaptionSize))
                    .foregroundStyle(.secondary)
            }
            // Past 100 the bar is full and the figure carries the rest: a scale
            // that stretched to fit 300% would make 100% — the boundary that
            // matters — a mark a third of the way along.
            //
            // The clamp is the only thing this bar shares with the menu bar's,
            // and calling them one rule was wrong: what fills this one is the
            // *load*, what fills that one is the mean, and the mean cannot reach
            // the clamp at all — it tops out at exactly 100. Both are right for
            // their own surface, because each bar sits under its own number: up
            // there the number is the mean, here it is whatever this headline is
            // stating.
            QuotaBar(fraction: load.map { $0.percent / 100 } ?? percent.map { Double($0) / 100 },
                     height: Self.headlineBarHeight,
                     tint: load.map(Self.loadColor(for:)))
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
    /// The counterpart of `MenuBarIcon.percent`, and the pair of them is the
    /// whole difference between the two surfaces: the same reading, rounded in
    /// the same one place, with one rule added up there and not down here. A
    /// named function rather than the property inline, so that difference is a
    /// thing a test can hold rather than a claim in a comment.
    static func headlinePercent(for snapshot: UsageSnapshot) -> Int? {
        snapshot.fleetSevenDayPercent
    }

    /// Past this age the load figure is not shown at all — on this surface or on
    /// the menu bar.
    ///
    /// Two of its own polling intervals (`UsageStore.fleetLoadIntervalSeconds`),
    /// built the same way `footerStaleSeconds` is built out of the fast halves':
    /// a figure that is *meant* to be up to ten minutes old is not stale at ten
    /// minutes, and past two intervals nothing is refreshing it at all.
    ///
    /// One constant because one rule: `headlineLoad` below is the whole of it and
    /// `MenuBarIcon.load(for:now:)` is that function under another name.
    static let loadStaleSeconds: TimeInterval = 2 * UsageStore.fleetLoadIntervalSeconds

    /// The load this headline speaks for, or `nil` when it has to fall back to
    /// the mean. The one rule both surfaces read.
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
    /// A `/gw/usage` outage skips the load block whole (`UsageStore.poll` needs a
    /// freshly confirmed account list), so `fleetLoadFailure` stays `nil`, neither
    /// stamp moves, and a guard on the blame alone presents a two-hour-old figure
    /// as current under a caption that says "capacity" — with a red frame in the
    /// menu bar that nothing can clear, since up there the whole load half is
    /// this one answer. The quiet direction is the same failure mirrored: a
    /// frozen green figure over a fleet that has since gone over capacity.
    ///
    /// Dating it in the footer instead was the other answer and it is not enough
    /// on its own — it leaves the number itself stating the present, and it
    /// cannot reach the menu bar, which has no room for a caveat. The stamp is
    /// the arrival and never the attempt: the attempt moves on a failure and
    /// would call a frozen figure fresh (`UsageSnapshot.fleetLoadCheckedAt`).
    /// A figure with no arrival stamp at all is not shown either — every pass
    /// that produces one stamps it in the same breath, so a load without a stamp
    /// is a fixture, not a reading.
    static func headlineLoad(for snapshot: UsageSnapshot, now: Date = Date()) -> FleetLoad? {
        guard snapshot.fleetLoadFailure == nil,
              let fetchedAt = snapshot.fleetLoadFetchedAt,
              now.timeIntervalSince(fetchedAt) < loadStaleSeconds else { return nil }
        return snapshot.fleetLoad
    }

    /// The string in the headline's top row: the load when there is one, the
    /// mean when there is not, and a dash when there is neither.
    ///
    /// A named function for the same reason `headlinePercent` is one — the
    /// fallback is a rule and a rule should be something a test can ask about.
    /// The rendering cannot: the picture is measured by its lines of ink, and
    /// `—` drawn where `100%` belongs is the same three lines of the same widths
    /// (checked by mutation, 2026-08-17 — the paint test stayed green).
    static func headlineFigureLabel(for snapshot: UsageSnapshot, now: Date = Date()) -> String {
        if let load = headlineLoad(for: snapshot, now: now) { return loadLabel(for: load) }
        return headlinePercent(for: snapshot).map { "\($0)%" } ?? "—"
    }

    /// The colour of that string: the load's own, or ink when the headline is
    /// back to being the mean.
    ///
    /// Named rather than written into the view, and the reason is that it was
    /// not: replacing the modifier with a flat `Color.primary` passed all 478
    /// tests (2026-08-17), which made this the one visible quantity on the
    /// surface with nothing holding it. The rule is here so a test can ask it,
    /// and `UsagePopoverPaintTests` asks the rendering as well — a function
    /// nobody calls would answer correctly for ever.
    ///
    /// The mean is deliberately not coloured. `QuotaBar.color(for:)` would give
    /// it a scale of its own — green, orange, red at 60% and 85% of a window —
    /// and that is a different quantity's thresholds on a number this line is
    /// only standing in with; a red `92%` beside a green account row would be
    /// two scales for one reading.
    static func headlineFigureColor(for snapshot: UsageSnapshot, now: Date = Date()) -> Color {
        headlineLoad(for: snapshot, now: now).map(loadColor(for:)) ?? .primary
    }

    /// The load as the headline writes it.
    ///
    /// `≥` when the figure is only a floor: an account sat at its ceiling while
    /// it was measured, and the demand it turned away never entered its series
    /// at all, so the truth is at least this (`FleetLoad.isLowerBound`). The
    /// same symbol, for the same reason, that the panel's row and `--dump` put
    /// in front of a token sum they know only a lower bound of (§2.7). What it
    /// does *not* say is by how much — the requests an exhausted account refused
    /// leave nothing behind to count.
    static func loadLabel(for load: FleetLoad) -> String {
        (load.isLowerBound ? "≥" : "") + "\(Int(load.percent.rounded()))%"
    }

    /// Green below capacity, red at or above it.
    ///
    /// The same two system colours `QuotaBar.color(for:)` fills an account's bar
    /// with, on a boundary of its own — and not that function, because its 60
    /// and 85 per cent are thresholds on a different quantity: how much of one
    /// account's window is gone. There is no orange here because there is no
    /// middle to paint. The week either holds what is being asked of it or it
    /// does not, and `FleetLoad.isOverCapacity` is where that boundary is
    /// written, once, for this surface and the menu bar both.
    static func loadColor(for load: FleetLoad) -> Color {
        loadColor(overCapacity: load.isOverCapacity)
    }

    /// The same two colours, asked for by the side of the boundary rather than
    /// by a figure standing on it.
    ///
    /// Its own caller is the menu bar, which needs the over-capacity colour with
    /// no load in hand at all: the number's attributed strings are laid out once
    /// at type initialisation, long before any figure has arrived
    /// (`MenuBarIcon.alertLabels`). Building a `FleetLoad` there purely to ask
    /// this question would be a fixture in the middle of the drawing code, and
    /// the boundary would still be read out of it by `isOverCapacity`.
    static func loadColor(overCapacity: Bool) -> Color {
        overCapacity ? .red : .green
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
    /// chart's own requests, and the histories behind the load figure.
    /// `UsageSnapshot.failureText` is still the wrong source — it also carries
    /// `/gw/sessions`, whose figures live in the panel's rows and not one of
    /// which is on this surface. Shown instead of the chart's own reason (and it
    /// was, being first), it left an empty chart with its cause named nowhere
    /// while explaining a number the user cannot see.
    ///
    /// Which is the argument for the load half rather than against it: the test
    /// is whether the reader can see the figure the reason is about, and this
    /// one's figure is the largest thing on the screen. Without it the headline
    /// stated a load nobody had confirmed since the outage began, with the whole
    /// footer silent about why.
    ///
    /// All of them when all of them failed, for the same reason: they are
    /// separate questions, and the first non-empty of them is not an answer to
    /// the others.
    static func failureText(quota: String?, history: String?, load: String?) -> String? {
        let all = [quota, history, load].compactMap { $0 }
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
    /// **The load figure is not dated here at all, and that is the same rule.** A
    /// stamp counts only for something on screen, and the load is never on screen
    /// while it is worth dating: `headlineLoad` takes it away the moment it is
    /// older than `loadStaleSeconds` or its half is failing, and below that
    /// ceiling it is the slow schedule running normally — a footer reporting
    /// *that* would date the whole popover by the one half that is designed to be
    /// minutes old. Folding the stamp in on a failure is what stood here, and it
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
    /// minutes of every outage. `loadFailed` is in that list although the load
    /// carries no stamp here — what it dates is then the halves that *are* on
    /// screen, and one of the three having gone quiet is the moment to say how
    /// old the rest is.
    static func footerAgeLabel(quotaFetchedAt: Date?,
                               quotaFailed: Bool,
                               chartFetchedAt: Date?,
                               seriesPeriod: HistoryPeriod?,
                               period: HistoryPeriod,
                               chartFailed: Bool,
                               loadFailed: Bool,
                               now: Date) -> String? {
        let chart = seriesPeriod == period ? chartFetchedAt : nil
        guard let oldest = [quotaFetchedAt, chart].compactMap({ $0 }).min() else { return nil }
        guard quotaFailed || chartFailed || loadFailed
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

/// A quota window as a bar. Unlike the menu bar's, this one is allowed a colour:
/// the picture up there is a template the system tints, this one is on our own
/// surface where 90% may look like 90%.
struct QuotaBar: View {
    /// 0…1, or `nil` when there is no reading — then the bar is only its track.
    let fraction: Double?
    var height: CGFloat = 6
    /// The fill colour when the caller has a rule of its own. `nil` leaves it to
    /// `color(for:)`, which answers "how full is this account's window" — the
    /// headline's bar is filled by a different quantity and coloured on a
    /// different boundary (`UsagePopoverView.loadColor`).
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
