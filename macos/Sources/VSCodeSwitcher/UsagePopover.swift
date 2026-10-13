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
    /// which is a hole in the line, not a zero. Swift Charts has no optional
    /// `Plottable`, so each run is its own series, all in the account's colour.
    struct Segment: Identifiable, Sendable, Equatable {
        /// Unique within the account, which is what makes it a series key.
        var id: Int
        var readings: [UsageReading]
    }

    /// Splits the gateway's samples into runs at every `null`, and collapses the
    /// readings that share a second so that no run holds one stamp twice.
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
            // Readings stamped the same second collapse into one: `ForEach(segment.readings,
            // id: \.timestamp)` needs unique ids. The gateway sends such repeats (its
            // poll and a response-header reading in the same second), and they are
            // adjacent in the ascending series. The last value wins, matching
            // `FleetSeries.make`. Only the drawn series is collapsed; the raw samples
            // keep their repeats for `FleetCapacity` and `UsageStore` (§2.7).
            if current.last?.timestamp == point.timestamp {
                current[current.count - 1] = UsageReading(timestamp: point.timestamp, value: value)
                continue
            }
            current.append(UsageReading(timestamp: point.timestamp, value: value))
        }
        if !current.isEmpty { segments.append(Segment(id: segments.count, readings: current)) }
        return AccountSeries(label: label, segments: segments)
    }

    var isEmpty: Bool { segments.isEmpty }
}

/// The fleet's utilisation over time: the chart's main line, the mean over the
/// accounts that have a reading (the same quantity the headline states).
///
/// Carried forward, never interpolated: between two samples an account is worth
/// its last reading.
struct FleetSeries: Sendable, Equatable {

    /// One moment of the line.
    struct Point: Sendable, Equatable {
        var timestamp: Date
        var value: Double
        /// How many accounts had a reading by this moment. Not shown on screen;
        /// the tests use it to check which accounts a point is a mean of.
        var accounts: Int
    }

    /// In time order, and one run rather than several: see `make`.
    var points: [Point]

    static let empty = FleetSeries(points: [])

    var isEmpty: Bool { points.isEmpty }

    /// The key this line's colour and its place in the scale hang on. It must
    /// not equal any account label from the gateway's config: a collision makes
    /// Charts draw the mean in that account's hue. The NUL prefix makes that
    /// unreachable in practice, though a JSON label spelled `\u0000average`
    /// would still collide.
    static let label = "\u{0}average"

    /// The mean of the readings there are, and `nil` when there are none: the
    /// average of no accounts is not zero.
    ///
    /// This is the arithmetic behind the headline figure upstream;
    /// `testTheLastPointOfTheMeanIsTheHeadlineFigure` requires the two to agree.
    static func mean(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Averages the accounts over the union of their sample times.
    ///
    /// Takes the raw samples, so moments where a sample was `null` belong in the
    /// union. Before anybody's first reading no point is emitted; after it, a
    /// `null` keeps the account at its last reading. So the line has no holes
    /// past its head and is one run of points.
    ///
    /// Each account's samples are assumed ascending, as the gateway sends them.
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
/// `open` starts the schedule, `close` stops it, and `fetch` refuses to run
/// outside that. The exception is a switch already sent: `close` cancels
/// `fetchTask` but leaves `switchTasks` alone, because a popover closes on any
/// click and that is not a change of mind. Such a POST can outlive the popover
/// by up to `UsageClient.timeoutSeconds`; nothing new starts while it is shut.
@MainActor
final class UsageHistoryModel: ObservableObject {

    /// Utilisation over time, one entry per account, ordered by label so the
    /// chart's colours do not swap between two passes.
    @Published private(set) var series: [AccountSeries] = []
    /// The mean of those, the chart's main line. Assigned in the same places as
    /// `series`, so the two always describe the same fetch.
    @Published private(set) var fleet: FleetSeries = .empty
    /// Why the last pass was incomplete, if it was. Kept beside the previous
    /// series rather than replacing them, exactly as `UsageStore` does.
    @Published private(set) var failure: String?
    /// Which accounts the gateway has in its rotation, by label, or `nil` when
    /// nobody has been able to ask.
    ///
    /// `nil` is not "everybody is in": an empty dictionary is an answer, `nil` is
    /// the absence of one. The row draws a switch inert when this is `nil`
    /// (§2.4: a confidently wrong reading is worse than a missing one).
    @Published private(set) var switches: [String: AccountSwitch]?
    /// Why the rotation on screen may be stale: the last pass could not ask.
    /// Rewritten by every pass; kept apart from `switchFailures`, which must
    /// survive later passes.
    @Published private(set) var rotationFailure: String?
    /// Each account's token health by label, from the last pass that got an
    /// answer. Replaced whole: no click changes it, so there is nothing to hold.
    @Published private(set) var auth: [String: AccountAuth] = [:]
    /// Why a click would not go through, by the label it was on.
    ///
    /// Per label, since a failed click leaves no other mark (the tick follows
    /// the gateway's answer). Cleared by the next click on that label
    /// (`setAccount`) and by `open`.
    @Published private(set) var switchFailures: [String: String] = [:]
    /// What is said when the gateway has nowhere left to route a request, or
    /// `nil` when it has somewhere.
    ///
    /// Driven by a count: `GatewayStatus.routableAccounts` on a pass and
    /// `SwitchResult.eligibleAccounts` on a switch answer are both the gateway's
    /// `is_eligible` over the fleet. Zero raises the line, more than zero clears
    /// it; `applyRoutable` is the only writer on an answer. `open` also clears it
    /// for the sitting (§2.4) but keeps `routableAskedAt`.
    @Published private(set) var fleetWarning: String?
    /// The labels with a switch request in the air. The row goes inert while one
    /// is, so a second click cannot race the first.
    @Published private(set) var inFlight: Set<String> = []
    /// When the lines on screen arrived, or `nil` while there are none.
    ///
    /// The age of the series, not of the attempt (`checkedAt`): a pass where no
    /// account answered must not make the chart claim the period holds no data.
    @Published private(set) var fetchedAt: Date?
    /// When the last pass finished, whatever came of it. Not published: it is
    /// the refresh schedule's clock, and the schedule has to go on ticking
    /// while the gateway is down — which is precisely when `fetchedAt` stands
    /// still.
    private(set) var checkedAt: Date?
    /// The window the lines on screen were fetched for, or `nil` when there are
    /// none. Differs from `period` between a picker change and the answer; the
    /// view checks it so it never draws lines under the wrong tab.
    ///
    /// Not `@Published`: its only writer, `apply`, always ends by assigning the
    /// published `now`, which announces the change.
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

    /// What the line under the accounts says when the gateway has nowhere left to
    /// route, whichever of the two counts raised it.
    ///
    /// The gateway's own sentence minus "in the fleet" (§4 keeps that word out of
    /// user-facing text). The gateway's sentence is a constant, so nothing is lost:
    /// the one off the wire is decoded but never printed (see `SwitchResult.warning`).
    nonisolated static let noRouteWarning =
        "claude-gw: no usable account is left - every client request will be "
        + "answered with 429 until one of them comes back"

    /// The clock for the moments on this path: `Rotation.askedAt` (when a pass
    /// asked), `switchConfirmedAt` (when a switch answer was applied) and
    /// `routableAskedAt` (when the answer whose count is on screen was asked for).
    ///
    /// `routableAskedAt` has two writers, a click (stamped in `setAccount` before
    /// the request) and a pass (`applyRotation`); `applyRoutable` keeps whichever
    /// asked later.
    ///
    /// Monotonic rather than `Date()`: these stamps are only compared, and the wall
    /// clock can step backwards (NTP, wake from sleep), which would make every pass
    /// look older than a switch answer. The compiler keeps all three on this type;
    /// `testTheStampsThatDecideAStalePassCannotStepBackwards` holds `Rotation.askedAt`.
    nonisolated static func stamp() -> ContinuousClock.Instant { ContinuousClock.now }

    private(set) var isOpen = false
    private let client: UsageClient
    /// The gateway this model asks, for the login page a row opens (`loginURL`).
    var baseURL: URL { client.baseURL }
    private let defaults: UserDefaults
    private var labels: [String] = []
    private var timer: Timer?
    /// The pass in flight, if there is one. Not private, so a test can wait for
    /// the requests to land rather than race them: the promise this class makes
    /// is about requests that do and do not happen, and that is only observable
    /// at the transport.
    private(set) var fetchTask: Task<Void, Never>?
    /// The switch requests in the air, one per label. Separate from `fetchTask`
    /// on purpose, and not merely for bookkeeping: `close` cancels that one, and
    /// a switch the operator has already asked for may not be cancelled by the
    /// popover going away. Not private for `fetchTask`'s reason — a test waits
    /// for the request to land rather than racing it.
    private(set) var switchTasks: [String: Task<Void, Never>] = [:]
    /// When the gateway last spoke for a label *with authority* — that is, when a
    /// switch answer for it was applied here. Read by `applyRotation` and by
    /// nothing else, which is why it is not published: it decides which of two
    /// writers wins, and draws nothing itself. No pruning, and none wanted: one
    /// entry per account of a fleet that has three.
    private var switchConfirmedAt: [String: ContinuousClock.Instant] = [:]
    /// When the answer whose count is on screen was asked for, or `nil` while no
    /// count has been applied.
    ///
    /// Orders answers that return out of order: `setAccount` guards one label at
    /// a time, so switch answers for different accounts can overtake each other.
    /// Complements `isStale`, which answers a different question ("is an
    /// unanswered mutation outstanding, so this pass's count predates it?").
    private var routableAskedAt: ContinuousClock.Instant?
    /// Whether two switch requests were in the air at once during the burst that
    /// is still landing.
    ///
    /// The ask-instant cannot order that case, so `setAccount` settles it by
    /// asking again. Recorded when the second click goes out (by the time answers
    /// land `inFlight` has emptied) and cleared when the air clears.
    private var clicksOverlapped = false

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

    /// The popover appeared. Driven from the controller rather than the view's
    /// `onAppear`: `NSPopover` keeps its content view controller alive between
    /// showings, so `onDisappear` is not a reliable close signal.
    func open(labels: [String]) {
        self.labels = labels
        isOpen = true
        now = Date()
        // A new sitting: last sitting's messages may be an hour old (nothing runs
        // while shut), so they are cleared here (§2.4). On `open` rather than
        // `close`, since a popover closes on any click anywhere. The pass fired
        // below refills them.
        switchFailures = [:]
        fleetWarning = nil
        rotationFailure = nil
        auth = [:]
        // `routableAskedAt` is kept: it orders answers rather than describing a
        // moment, and a click sent before the close may still be in the air.
        // Clearing it would let that click's pre-close count overwrite this
        // sitting's pass.
        //
        // The rotation is cleared too: it backs a control, and a click on a stale
        // tick changes the fleet (`disableAccount` sends no body, which the
        // gateway reads as `DISABLED_NO_DEADLINE`, turning a timed parking into an
        // indefinite switch-off). `nil` draws the boxes inert until the pass fills
        // them in.
        //
        // Labels with a click still in the air are carried over: `applyRotation`
        // holds them by laying the existing value over the pass's, and this
        // sitting's pass lands before a POST sent before the close.
        //
        // `nil` ("the gateway did not say") and `[:]` ("the gateway said nobody")
        // differ, so an empty carry-over becomes `nil`.
        let heldOver = (switches ?? [:]).filter { inFlight.contains($0.key) }
        switches = heldOver.isEmpty ? nil : heldOver
        fetch()
        schedule()
    }

    /// The accounts changed under an open popover. Called from the view's
    /// `onChange` on the label list.
    ///
    /// The hosted view outlives the sitting, so `onChange` also arrives while
    /// shut, including inside `popover.show(…)` before `open` runs; `isOpen`
    /// refuses those. The label comparison guards against a duplicate pass if
    /// `AppDelegate` ever calls `history.open(labels:)` before `popover.show(…)`.
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
        // `switchTasks` is left alone: the operator asked for the switch, and the
        // popover closing is not a change of mind. The answer writes into `self`
        // only if it is still there.
    }

    // MARK: Fetching

    /// One pass over every account, if the popover is open.
    ///
    /// The two halves start together and land separately, rotation first:
    /// `/gw/status` is ~6 KB against ~170 KB of history, so the checkboxes appear
    /// without waiting on the slowest history. Ordering is unaffected, because
    /// `applyRotation` weighs a pass by `Rotation.askedAt`, taken when the request
    /// goes out.
    ///
    /// A pass cancelled before a half landed does not apply that half: `fetch`
    /// cancels the previous task, and both run on the main actor, so they cannot
    /// interleave. A rotation that landed before the cancel stays applied.
    /// `testAPassCancelledBeforeItsRotationLandedAppliesNeitherHalf` holds both
    /// guards.
    func fetch() {
        guard isOpen else { return }
        let client = client
        let labels = labels
        // Captured now: by the time the answer lands, the picker may name another
        // period.
        let period = period
        let since = Date().addingTimeInterval(-period.seconds)
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            // Both are `nonisolated`, so the requests do not inherit the main
            // actor and only the finished values hop back — the same rule, and
            // for the same reason, as `UsageStore.poll` (SPEC §6).
            async let rotation = UsageHistoryModel.fetchRotation(client: client)
            async let histories = UsageHistoryModel.load(client: client,
                                                         labels: labels,
                                                         since: since)
            let answered = await rotation
            if let self, !Task.isCancelled { self.applyRotation(answered) }
            let loaded = await histories
            guard let self, !Task.isCancelled else { return }
            self.apply(loaded, period: period)
        }
    }

    /// What the history half of one pass produced, `Sendable` so it can cross back
    /// to the main actor whole. The rotation arrives separately (`Rotation`), and
    /// `failure` lists only accounts whose history is missing.
    struct Loaded: Sendable {
        var series: [AccountSeries]
        var fleet: FleetSeries
        var failure: String?
    }

    /// The rotation half of one pass: what `/gw/status` said, what it cost the
    /// fleet, why it said nothing, and when it was asked.
    struct Rotation: Sendable {
        /// The rotation by label, or `nil` when the gateway would not answer.
        /// Never an empty dictionary standing in for the failure — see `switches`.
        var state: [String: AccountSwitch]?
        /// Each account's token health by label, `nil` for the same reason.
        var auth: [String: AccountAuth]?
        /// How many accounts the gateway may still route to, `nil` for the same
        /// reason. Fleet-level and kept that way: it is the warning's question,
        /// never a switch's.
        var routable: Int?
        /// Why it would not answer, named by its endpoint rather than folded into
        /// `Loaded.failure`: that one is a list of accounts whose *history* is
        /// missing, and a reader who cannot tell the chart's silence from the
        /// rotation's has been told nothing.
        var failure: String?
        /// When the request went out, not when it came back: `applyRotation` asks
        /// whether the operator's answer had landed by the time this pass asked.
        /// Taken from `UsageHistoryModel.stamp()`.
        var askedAt: ContinuousClock.Instant
    }

    /// One request per account, in parallel, with each account's failure kept as
    /// text instead of an error: an account the gateway will not answer for is
    /// an ordinary state, and the others still have a chart to draw.
    ///
    /// The mean is folded here, off the main actor and from the same answers as
    /// the account lines, so a missing account is absent from both and the view
    /// does not refold on every tick. The rotation is fetched beside this, from
    /// `fetch`, so it can land earlier.
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
                        // Filtered once, here, so the lines and the mean describe
                        // the same data.
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

    /// One `/gw/status`, as a state or as a reason there is none. The error is
    /// turned into text here because `Error` is not `Sendable`.
    ///
    /// Not private: `nonisolated` keeps the request off the main actor (`fetch`
    /// starts it from a main-actor task), and `testLoadDoesNotNeedTheMainThread`
    /// checks that from a detached task.
    nonisolated static func fetchRotation(client: UsageClient) async -> Rotation {
        // Taken before the request goes out: `applyRotation` weighs this pass
        // against answers that landed while it was in the air.
        let askedAt = UsageHistoryModel.stamp()
        do {
            let status = try await client.status()
            return Rotation(state: status.byLabel,
                            auth: status.authByLabel,
                            routable: status.routableAccounts,
                            failure: nil,
                            askedAt: askedAt)
        } catch {
            return Rotation(state: nil, auth: nil, routable: nil, failure: "status: \(error)",
                            askedAt: askedAt)
        }
    }

    /// The gateway's samples with the lag between its two measuring sources taken
    /// out of `util_7d`: inside a quota window utilisation only accumulates, so a
    /// fall of exactly one point per cent is the slower source talking and the
    /// reading before it is carried through.
    ///
    /// A sample carries its `source`: `poll` (the gateway asked the API) or
    /// `headers` (read off an ordinary response). `headers` trails `poll` by about
    /// one five-minute poll cycle, so the two differ by one point and, interleaved,
    /// draw a comb. The quota window is hard (resets drop to 0 and announce a
    /// `resets_at` 7×24 h later), so utilisation never falls inside one. Measured
    /// figures, and why a median filter and filtering by `source` do not work, are
    /// in SPEC §4.
    ///
    /// What it does not do: a fall into zero is always kept (a reset); a level is
    /// never carried across a `null` (a reset may hide in a hole); and the last
    /// reading is never moved, hence `lastIndex(where:)` rather than `dropLast()`
    /// (`testTheLastReadingIsNeverMoved`). The end of the line still need not equal
    /// the headline: they are two endpoints with the same lag.
    ///
    /// Known blind spots: a real reset exactly 1 pp deep and not into zero is taken
    /// for a lag and overstated by one point until the next hole; a lag 2 pp deep
    /// is taken for a reset and the comb stays. `util_5h` is left as it came.
    ///
    /// For drawing only: never difference this series for spend (spend is the two
    /// ends plus 100 pp per reset crossed), and a level read off it can be 1 pp
    /// high. `load` is the only caller.
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
            // for a percentage that arrives as a fraction; the gateway sends whole
            // numbers, but the field is a `Double`.
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
            // Somebody answered. An account that answered with nothing but holes
            // is still an answer, and the chart may then say the period held no
            // data.
            series = loaded.series
            fleet = loaded.fleet
            seriesPeriod = period
            fetchedAt = moment
        } else if loaded.failure == nil || seriesPeriod != period {
            // Nothing came back. A failed pass keeps the previous lines (stale
            // beats blank, with the reason in the footer), but only while they
            // answer the current period; otherwise they and their stamp go.
            series = []
            fleet = .empty
            seriesPeriod = nil
            fetchedAt = nil
        }
        failure = loaded.failure
        // The attempt's clock, set when the whole pass is over (the rotation half
        // landed earlier). Its only reader is `tick`. `fetchedAt` must not come
        // from the rotation half (`testTheRotationIsDrawnBeforeTheHistoriesHaveLanded`).
        checkedAt = moment
        now = moment
    }

    /// The rotation of one pass, merged label by label, never assigned whole.
    ///
    /// An answer replaces what is held; a pass that got none leaves it alone, so a
    /// failure does not make every switch inert (the blame beside them explains).
    ///
    /// Labels the operator has just moved are not replaced. `open` fires a pass
    /// (status plus one history per account, ~200 KB for the default day window),
    /// while a switch is one short POST, so a click right after opening is
    /// answered first and the pass would land on top with the pre-click state,
    /// making the click look like it did nothing. Held against a pass: a label
    /// whose answer is younger than the moment the pass asked, and a label with a
    /// request still in the air.
    private func applyRotation(_ rotation: Rotation) {
        if let fresh = rotation.state {
            var merged = fresh
            // Only labels already held can be held back; for an unknown label the
            // pass's reading beats none.
            for (label, held) in switches ?? [:] where holds(label, against: rotation) {
                merged[label] = held
            }
            switches = merged
        }
        if let fresh = rotation.auth {
            auth = fresh
        }
        rotationFailure = rotation.failure
        // The count is held against a stale pass by the same measure as the
        // labels. A warning taken down wrongly is not restored until another
        // click, while the fleet answers 429 to everything.
        if let routable = rotation.routable, !isStale(rotation) {
            applyRoutable(routable, askedAt: rotation.askedAt)
        }
    }

    private func holds(_ label: String, against rotation: Rotation) -> Bool {
        if inFlight.contains(label) { return true }
        guard let confirmed = switchConfirmedAt[label] else { return false }
        return confirmed > rotation.askedAt
    }

    /// Whether this pass is older news than the operator's own, asked of the whole
    /// fleet where `holds` asks about one account: any confirmed switch younger than
    /// the pass's ask, or any click still in the air, makes its count stale.
    ///
    /// The second half is reachable only because a lone click asks for no settling
    /// pass (`fetch` would cancel the older pass). See `setAccount`.
    private func isStale(_ rotation: Rotation) -> Bool {
        !inFlight.isEmpty || switchConfirmedAt.values.contains { $0 > rotation.askedAt }
    }

    /// The newest authoritative count of accounts the gateway may still route to.
    ///
    /// The count is the verdict and the sentence only its wording: the gateway
    /// counts both `GatewayStatus.routableAccounts` and
    /// `SwitchResult.eligibleAccounts` with `is_eligible`, and `_switch_payload`
    /// writes its warning exactly when that count is zero. So this takes a count
    /// only, and the line also lights up on a pass, e.g. after a `claude-gw
    /// disable` from the command line.
    ///
    /// `eligible` folds in the quota cool-down, so the line can appear with every
    /// checkbox ticked when all accounts have filled their five-hour windows. That
    /// is correct: clients get 429 either way.
    ///
    /// A count is applied only if it was asked for later than the one on screen:
    /// `setAccount` guards one label at a time, so two answers can land out of
    /// order (switch off A, then B; B's count 0 lands first, A's count 1 second
    /// would take the warning down).
    ///
    /// The ask-instant stands in for which answer measured the fleet last, which
    /// no body carries; it is right when the gateway processed the POSTs in the
    /// order sent. When it did not, this guard only picks which half is wrong, so
    /// `setAccount` asks for a settling pass after a burst of overlapping clicks.
    /// A lone click needs none. See `routableAskedAt` for how this composes with
    /// `isStale`.
    private func applyRoutable(_ count: Int, askedAt: ContinuousClock.Instant) {
        if let applied = routableAskedAt, askedAt <= applied { return }
        routableAskedAt = askedAt
        guard count == 0 else {
            fleetWarning = nil
            return
        }
        fleetWarning = Self.noRouteWarning
    }

    // MARK: Switching an account

    /// Take one account out of the gateway's rotation, or put it back.
    ///
    /// Nothing moves on the click: the checkbox is drawn from `switches`, written
    /// only from the gateway's answer, so "the gateway did not take it" never looks
    /// like a short delay, and an answer that disagrees with the request shows.
    ///
    /// A label already in flight is refused silently rather than queued: the
    /// second click of a double click is the opposite request.
    func setAccount(label: String, enabled: Bool) {
        guard !inFlight.contains(label) else { return }
        // Two labels in the air at once can be counted in either order; the
        // settling pass at the end of this task exists for that.
        if !inFlight.isEmpty { clicksOverlapped = true }
        inFlight.insert(label)
        // Stamped when the request goes out: the fleet count is ordered by that
        // (see `applyRoutable`), not by when the answer arrives.
        let askedAt = UsageHistoryModel.stamp()
        // A new click on this switch means the last message about it was read.
        switchFailures[label] = nil
        let client = client
        switchTasks[label] = Task { [weak self] in
            let answer = await UsageHistoryModel.switchAccount(client: client,
                                                               label: label,
                                                               enabled: enabled)
            guard let self else { return }
            inFlight.remove(label)
            // Whether the air has just cleared on a burst that needs settling;
            // cleared with the burst so a later lone click does not inherit it.
            let settle = inFlight.isEmpty && clicksOverlapped
            if inFlight.isEmpty { clicksOverlapped = false }
            guard let result = answer.result else {
                switchFailures[label] = answer.failure
                // A refused connection changed nothing, but a timeout
                // (`UsageClient.timeoutSeconds`) may hide a switch the gateway did
                // apply, so ask again. Not gated on `settle`: this repairs the
                // tick of the label that failed, which has already left
                // `inFlight`. `fetch` does nothing once the popover is shut.
                fetch()
                return
            }
            // The answer is authoritative about this account even if
            // `/gw/status` never came through.
            var known = switches ?? [:]
            known[label] = result.account
            switches = known
            // When this app was told, which is what `holds` compares against;
            // distinct from `askedAt` above.
            switchConfirmedAt[label] = UsageHistoryModel.stamp()
            // The count decides, through the same writer as a pass, ordered by
            // the moment this click was asked. The answer's own `warning` is
            // ignored (see `SwitchResult.warning`).
            applyRoutable(result.eligibleAccounts, askedAt: askedAt)
            // After the last click of an overlapping burst lands, settle the count
            // with a fresh pass instead of trusting the ask-instant order (see
            // `applyRoutable`). Nothing refuses that pass unless a newer click
            // happens, and then that click's count is the newer news anyway.
            //
            // Only on `settle`: while another click is in the air `isStale` would
            // ignore the pass, and after a lone click `fetch` would cancel the
            // in-flight pass that `isStale`'s second half exists to refuse.
            if settle { fetch() }
        }
    }

    /// One switch request, as a result or as a reason. Text rather than an `Error`
    /// for `fetchRotation`'s reason; the label is in it because the popover keeps
    /// one message per label.
    ///
    /// Not private, for `fetchRotation`'s reason: `nonisolated` keeps a request
    /// that may take `UsageClient.timeoutSeconds` off the main actor (§6), and a
    /// test checks that from a detached task.
    nonisolated static func switchAccount(client: UsageClient,
                                          label: String,
                                          enabled: Bool) async
        -> (result: SwitchResult?, failure: String?) {
        do {
            let answer = enabled
                ? try await client.enableAccount(label: label)
                : try await client.disableAccount(label: label)
            return (answer, nil)
        } catch {
            return (nil, "\(label): \(error)")
        }
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

    /// Keyed on `checkedAt`, not `fetchedAt`: the schedule is about attempts, so a
    /// gateway that is not answering keeps being retried. The clock is an argument
    /// so tests need not wait a real minute.
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

    /// Which plate this popover is drawn on, which the ramp's colour must be
    /// legible against (`ratioColor(atPercent:on:)`). From the environment, since
    /// the popover follows the appearance it is presented in; the menu bar answers
    /// the same question itself (`MenuBarIcon.background(for:)`).
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

    /// What the lead figure is a figure of: the words under the ratio here, and
    /// the words after it in the menu bar's accessibility description
    /// (`MenuBarIcon.describe`). One string so the two surfaces cannot name
    /// different quantities. No internal vocabulary such as "burn against refill"
    /// (§4). `testTheHeadlineCaptionIsDrawnOnOneLine` holds it on one line.
    static let ratioCaption = "of the weekly refill rate"

    /// What the token rate is a figure of. It is the one measurement here about
    /// now (five minutes), not the trailing `FleetCapacity.burnWindowHours` the
    /// lead is measured over, and the caption is what says so.
    static let spendRateCaption = "spent right now"

    /// The headline's bar, taller than the account rows' because it belongs to
    /// the figure this popover is opened for. A constant because the colour test
    /// finds the bar by this height.
    static let headlineBarHeight: CGFloat = 8

    /// The lead figure and the supporting one under it, and the gap between the
    /// two readings.
    ///
    /// The sizes make the pair read as a lead and a second reading; they are named
    /// because the tests render the figures free-standing to compare with the
    /// popover.
    ///
    /// The lead slot prints `ratioLabel`: `≥300%` is 104 pt of layout at 30 pt.
    /// Measured ink widths at these sizes against the 292 pt content line
    /// (layout is 0.5–5 pt wider, more for narrow digits under
    /// `monospacedDigit`):
    ///
    ///     lead, 30 pt      113%          79.50 pt     ≥126%       100.50
    ///                      999%          82.00        ≥9999%      120.00
    ///     rate, 17 pt      23.8M/h       65.50        999.9M/h     76.50
    ///                      999.9B/h      73.00        0/h          24.50
    ///     quota, 17 pt     52%           36.00        100%         46.00
    ///     captions, 11 pt  weekly quota, average across accounts  205.50
    ///                      of the weekly refill rate              119.00
    ///                      spent right now                         81.00
    ///
    /// The widest caption is what the line is sized against. `ratioLabel` is not
    /// clamped (unlike `MenuBarIcon.ceilingPercent`), so twelve digits is this
    /// slot's limit. `testTheHeadlineCaptionIsDrawnOnOneLine` and
    /// `testTheHeadlineDrawsAllThreeReadingsAtOnce` hold the captions on one line.
    ///
    /// The gap is wider than the 6 pt inside a reading and narrower than the
    /// 12 pt between the popover's sections.
    static let headlineFigureSize: CGFloat = 30
    static let supportingFigureSize: CGFloat = 17
    static let headlineReadingSpacing: CGFloat = 10

    /// The supporting reading's bar — the height an account's window row gets,
    /// which is the point: the lead's 8 pt says which figure the popover is for,
    /// and the quota is drawn at the weight of the readings it summarises.
    static let supportingBarHeight: CGFloat = 6

    /// The slot the reset time gets at the right end of a window row, wide enough
    /// for everything `resetLabel` writes about a quota window
    /// (`testTheResetTimeFitsItsSlotWhole`): a truncated `in 5d 0h` would read as
    /// a day count. `resetLabel` prints as many days as the gateway names; §4
    /// records the measured figures.
    static let resetColumnWidth: CGFloat = 74

    /// The dot in front of an account's name: the sample of that account's line
    /// on the chart, which is why the chart has no legend. A constant because the
    /// palette test finds the dots by this size.
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
                                      historiesFailed: usage.snapshot.historiesFailure != nil,
                                      now: history.now)
        let failure = Self.failureText(quota: usage.snapshot.quotaFailure,
                                       chart: history.failure,
                                       histories: usage.snapshot.historiesFailure)
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

    /// The weekly quota, rounded in one place (`UsageSnapshot.fleetSevenDayPercent`).
    ///
    /// Only this surface draws it; the menu bar carries the spend ratio (§4). A
    /// figure the last pass failed to refresh is kept, because the footer says how
    /// old it is and the account rows below keep showing their stored percentages.
    ///
    /// Each reading takes three rows (figure, caption, bar): the 206 pt caption
    /// does not fit beside a long figure on the 292 pt line (§4).
    ///
    /// The lead is one division in one unit: percentage points of quota burned
    /// over the trailing `FleetCapacity.burnWindowHours` against the points the
    /// week refills over the same hours, e.g. `112%` over "of the weekly refill
    /// rate", with the bar that ratio clamped at one
    /// (`FleetCapacity.burnAgainstRefill`). The block's colour is the same ratio.
    ///
    /// Three readings: burn against refill ("will the week last") takes the big
    /// figure; the weekly quota ("how much is gone") and the token rate ("what is
    /// going right now") get `supportingFigureSize`. Only the quota has a bar; a
    /// token rate has no full.
    ///
    /// With no ratio (`headlineRatio` is `nil` for everything
    /// `FleetCapacity.burnAgainstRefill` refuses on, and for histories not
    /// confirmed recently enough), the mean utilisation leads, its caption and bar
    /// switch with it, and the supporting quota is not drawn twice (§2.7). The
    /// spend rate is drawn whenever the gateway named one.
    private var headline: some View {
        // The popover's ticking clock: one of the lead's rules is an age, so a
        // figure that goes stale under an open popover must leave the headline.
        let ratio = Self.headlineRatio(for: usage.snapshot, now: history.now)
        let percent = Self.headlinePercent(for: usage.snapshot)
        return VStack(alignment: .leading, spacing: Self.headlineReadingSpacing) {
            // Past the refill rate the bar is full and the figure carries the
            // rest, so the refill stays at the end of the bar. The menu bar clamps
            // the same way (`MenuBarIcon.fillWidth`).
            reading(figure: Self.headlineFigureLabel(for: usage.snapshot, now: history.now),
                    color: Self.headlineFigureColor(for: usage.snapshot, now: history.now,
                                                    on: background),
                    size: Self.headlineFigureSize,
                    caption: ratio == nil ? Self.headlineCaption : Self.ratioCaption,
                    fraction: ratio.map(\.ratio) ?? percent.map { Double($0) / 100 },
                    barHeight: Self.headlineBarHeight,
                    tint: ratio.map { Self.ratioColor(atPercent: $0.percent, on: background) })
            if ratio != nil {
                // The quota as drawn when it is the lead, only smaller; the bar
                // uses `QuotaBar.color(for:)`, whose 60/85% thresholds belong to
                // this quantity.
                reading(figure: Self.quotaLabel(for: usage.snapshot),
                        color: .primary,
                        size: Self.supportingFigureSize,
                        caption: Self.headlineCaption,
                        fraction: percent.map { Double($0) / 100 },
                        barHeight: Self.supportingBarHeight,
                        tint: nil)
            }
            if let rate = usage.snapshot.fleetTokenRate {
                // No bar and no colour: a rate has no ceiling, and colouring it
                // would put the burn ratio's verdict on a different number.
                reading(figure: Self.rateLabel(rate),
                        color: .primary,
                        size: Self.supportingFigureSize,
                        caption: Self.spendRateCaption,
                        fraction: nil,
                        barHeight: nil,
                        tint: nil)
            }
        }
    }

    /// One reading of the headline: a figure, its caption and, when the figure is
    /// a fraction of something, its bar.
    ///
    /// A `nil` `barHeight` is no bar at all, unlike `QuotaBar(fraction: nil)`,
    /// whose empty track under a token rate would read as zero.
    private func reading(figure: String,
                         color: Color,
                         size: CGFloat,
                         caption: String,
                         fraction: Double?,
                         barHeight: CGFloat?,
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
            if let barHeight {
                QuotaBar(fraction: fraction, height: barHeight, tint: tint)
            }
        }
    }

    // MARK: Accounts

    /// The account list, and the three fleet-wide lines under it.
    ///
    /// The lines sit outside the list's branch: rows come from `/gw/usage` and
    /// the rotation from `/gw/status`, which fail apart, so the 429 warning must
    /// show even when `/gw/usage` is down.
    @ViewBuilder private var accounts: some View {
        VStack(alignment: .leading, spacing: 10) {
            if usage.snapshot.accounts.isEmpty {
                Text(Self.accountsEmptyLabel(usage.snapshot))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                let labels = usage.snapshot.accounts.map(\.label)
                ForEach(usage.snapshot.accounts, id: \.label) { account in
                    accountRow(account, in: labels)
                }
            }
            // Once for the list rather than once per row: all three lines are
            // about the fleet, and a warning repeated beside every account would
            // read as one warning per account.
            if let warning = history.fleetWarning {
                // One wording only: `UsageHistoryModel.noRouteWarning`. The
                // gateway's own sentence is never shown.
                Text(warning)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The operator's own clicks first: those are about something they did
            // a moment ago, where the line under them is about a question nobody
            // asked out loud.
            if let blame = Self.switchBlame(history.switchFailures) {
                Text(blame)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = history.rotationFailure {
                Text(failure)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One account: its name and switch on the first line, then its two quota
    /// windows.
    ///
    /// The note about a switched-off account rides on the name line so switching
    /// an account off does not move the list under the pointer. The name has
    /// layout priority (labels come from the gateway and can be long) and the note
    /// is truncated, with the whole note in the tooltip.
    ///
    /// Not private, so a test can render one row and measure its height.
    @ViewBuilder func accountRow(_ account: AccountUsage, in labels: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                // This account's line on the chart below, which is why the chart
                // has no legend of its own.
                Circle()
                    .fill(Self.accountColor(for: account.label, in: labels))
                    .frame(width: Self.accountDotSize, height: Self.accountDotSize)
                Text(account.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let state = history.switches?[account.label], state.disabled {
                    let note = Self.switchNote(state, now: history.now)
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(note)
                }
                if let auth = history.auth[account.label], let note = Self.authNote(auth) {
                    let text = Text(note.text)
                        .font(.system(size: 10))
                        .foregroundStyle(note.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if note.opensLogin {
                        Button {
                            if let url = Self.loginURL(base: history.baseURL, label: account.label) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            text
                        }
                        .buttonStyle(.plain)
                        .help(note.help)
                    } else {
                        text.help(note.help)
                    }
                }
                Spacer(minLength: 4)
                rotationSwitch(for: account.label)
            }
            windowRow("5h", account.fiveHour)
            windowRow("7d", account.sevenDay)
        }
    }

    /// The operator's switch for one account: ticked while the gateway routes to
    /// it, and inert whenever this app cannot say.
    ///
    /// With no answer from `/gw/status` the box is clear and disabled (§2.4); in
    /// flight it is inert too, so a double click cannot race. An account present in
    /// `/gw/usage` but missing from `/gw/status` (removed between the two answers)
    /// draws the same way, until the next quota poll drops the row.
    @ViewBuilder private func rotationSwitch(for label: String) -> some View {
        let state = history.switches?[label]
        let look = Self.switchAppearance(state, busy: history.inFlight.contains(label))
        Toggle("", isOn: Binding(get: { look.ticked },
                                 set: { history.setAccount(label: label, enabled: $0) }))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!look.usable)
            .help(Self.switchHelp(state))
            .accessibilityLabel(Self.switchAccessibilityLabel(label))
    }

    /// What the checkbox is called to somebody who cannot see it (the box has no
    /// visible label). A function so
    /// `testNoStringOnScreenNamesTheMetricByItsInternalWord` can check it (§4).
    static func switchAccessibilityLabel(_ label: String) -> String {
        "\(label) in the gateway rotation"
    }

    /// Whether the box is ticked and whether it can be clicked: a box this app
    /// cannot fill in must not be clickable either.
    ///
    /// Outside the view because `ImageRenderer` draws every state of this checkbox
    /// identically, so only this function can be tested.
    static func switchAppearance(_ state: AccountSwitch?, busy: Bool) -> (ticked: Bool, usable: Bool) {
        guard let state else { return (ticked: false, usable: false) }
        return (ticked: !state.disabled, usable: !busy)
    }

    /// Every click that would not go through, on one line, oldest label first.
    ///
    /// Ordered by label rather than by when it happened so that the line does not
    /// reshuffle itself under the pointer as a second account answers.
    static func switchBlame(_ failures: [String: String]) -> String? {
        guard !failures.isEmpty else { return nil }
        return failures.sorted { $0.key < $1.key }.map(\.value).joined(separator: "; ")
    }

    /// What the switch says when the pointer rests on it — and it may not claim a
    /// state nobody reported, so the unknown case has wording of its own.
    static func switchHelp(_ state: AccountSwitch?) -> String {
        guard let state else { return "The gateway did not say whether this account is in rotation" }
        return state.disabled
            ? "Put this account back into the gateway rotation"
            : "Take this account out of the gateway rotation"
    }

    /// The note beside a switched-off account's name (`accountRow`).
    ///
    /// Shows the moment when the gateway named one: an account disabled for an
    /// hour differs from one disabled indefinitely, the only kind this app writes.
    /// Worded by `resetLabel`, like every other moment here.
    static func switchNote(_ state: AccountSwitch, now: Date) -> String {
        var note = "off"
        if let until = state.disabledUntil {
            note += " (\(resetLabel(until, now: now)))"
        }
        if !state.disabledReason.isEmpty {
            note += " · \(state.disabledReason)"
        }
        return note
    }

    /// The note beside the name of an account whose token the gateway cannot renew
    /// (`accountRow`), or `nil` when there is nothing to say. Without it a dead
    /// account is invisible while any other one still routes: the line under the
    /// list appears only when none does, and names no account. `opensLogin` marks
    /// the note a click on which opens the gateway's login page (`loginURL`).
    static func authNote(_ auth: AccountAuth)
        -> (text: String, help: String, color: Color, opensLogin: Bool)? {
        switch auth.state {
        case "needs_manual_token":
            let login = "Click to log in again in the browser"
            return (text: "needs login",
                    help: auth.error.isEmpty ? login : "\(auth.error)\n\(login)",
                    color: .red,
                    opensLogin: true)
        case "refresh_backoff":
            return (text: "token renewal failing",
                    help: auth.error.isEmpty ? "The gateway keeps retrying" : auth.error,
                    color: .orange,
                    opensLogin: false)
        default:
            return nil
        }
    }

    /// The gateway's login page for one account, `/gw/login?account=<label>`.
    ///
    /// `URLComponents` leaves a `+` in a query as is, and the gateway reads a bare
    /// `+` as a space, so a plus-addressed email is encoded by hand.
    static func loginURL(base: URL, label: String) -> URL? {
        guard var components = URLComponents(url: base.appending(path: "gw").appending(path: "login"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "account", value: label)]
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
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

    /// Not private, so a test can render which branch this takes for lines that
    /// do not answer the current period.
    @ViewBuilder var plot: some View {
        // Nothing is built while the popover is down: `NSPopover` keeps its
        // content view controller for the life of the process, so this `body` is
        // rebuilt on every `usage.snapshot` publication, once a minute, shut or
        // not. On live data that is ~7300 marks and 62–86 ms of CPU per rebuild.
        // `isOpen` rather than `onAppear`/`onDisappear`, for the same reason.
        //
        // `isOpen` is not `@Published`; the redraw on open comes from the six
        // published fields `open(labels:)` writes unconditionally (`now`,
        // `switchFailures`, `fleetWarning`, `rotationFailure`, `auth`, `switches`). Do not
        // put those behind a `guard`: no test would notice the missing first
        // frame. `close()` publishes nothing; the blank lands on the next
        // publication.
        //
        // A blank rather than the empty branch's words: "no data" is a statement
        // about the gateway. The height comes from `chart`.
        if !history.isOpen {
            Color.clear
        // Lines are drawn only while they answer the period the picker names;
        // until the answer lands (up to five seconds) the lines in hand are the
        // previous window's.
        } else if history.seriesPeriod != history.period || history.series.allSatisfy(\.isEmpty) {
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
                    // a gap. The colour is keyed on the account, so all runs of
                    // one account share it.
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
                // The mean, drawn last so it sits on top of the account lines.
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
            // An explicit scale, for the colour each key gets: the mean's is ink
            // and no account may be handed it.
            //
            // Account colours are keyed on the snapshot's account list, like the
            // dots beside the names, not on `history.series`, which holds only the
            // accounts that answered; one failure would otherwise shift every
            // colour after it.
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
            // No legend: the dots beside the account names do its job, and the
            // plot gains about 16 of its 130 points (§4).
            .chartLegend(.hidden)
            .font(.system(size: 9))
        }
    }

    // MARK: Chart styling

    /// The mean is the line drawn at full strength; the accounts stay behind it.
    /// Width separates the lines where they run apart, opacity where they run
    /// together.
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
    /// Keyed on the account's place in the snapshot's list, the one list both
    /// surfaces have (the lines come only from accounts that answered). An account
    /// the snapshot does not list is grey.
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
    /// arrived, stale or not. A function so a test can hold the rule.
    static func headlinePercent(for snapshot: UsageSnapshot) -> Int? {
        snapshot.fleetSevenDayPercent
    }

    /// Past this age the burn ratio is not drawn at all, on this surface or on
    /// the menu bar, and the lead goes back to the weekly quota.
    ///
    /// Two of its own polling intervals (`UsageStore.historyIntervalSeconds`),
    /// like `footerStaleSeconds`: a figure meant to be up to ten minutes old is not
    /// stale at ten minutes. Read through `historiesAreFresh` by this surface and
    /// by `MenuBarIcon.ratio(for:now:)`.
    static let historyStaleSeconds: TimeInterval = 2 * UsageStore.historyIntervalSeconds

    /// Whether the histories half of the pass has said anything recently enough
    /// to draw. The one rule both surfaces read; it checks the stamps and the
    /// blame only (a `nil` ratio after fresh histories is `headlineRatio`'s case).
    ///
    /// A failure of the histories half freezes the figure, which can mislead
    /// either way (a stale alarm or a stale green). `/gw/usage` (~3 KB) is far
    /// smaller than a history (130–187 KB), so a slow link often delivers the
    /// quota and loses the histories.
    ///
    /// The age check covers a `/gw/usage` outage: `UsageStore.poll` then skips
    /// the histories block, so `historiesFailure` stays `nil` and neither stamp
    /// moves. Dating it in the footer alone would not reach the menu bar.
    ///
    /// The stamp is the arrival, never the attempt
    /// (`UsageSnapshot.historiesCheckedAt` moves on failure). A figure with no
    /// arrival stamp is not shown: every real pass stamps it.
    static func historiesAreFresh(for snapshot: UsageSnapshot, now: Date = Date()) -> Bool {
        guard snapshot.historiesFailure == nil,
              let fetchedAt = snapshot.historiesFetchedAt else { return false }
        return now.timeIntervalSince(fetchedAt) < historyStaleSeconds
    }

    /// The ratio the lead states — or `nil` when the quota has to lead instead.
    /// The one rule the whole lead block reads: its figure, its caption, its bar,
    /// its colour and whether the quota's supporting reading is drawn at all.
    struct HeadlineRatio: Equatable {
        /// Percentage points of quota burned over the measured window against the
        /// points the week refills over the same window, in per cent ("112% of the
        /// weekly refill rate"). It both colours both surfaces and is the printed
        /// figure, so the shade cannot disagree with the number.
        let percent: Double

        /// The burn was measured over a partly blocked fleet, so it reads low and
        /// everything drawn from it is a floor
        /// (`FleetCapacity.FleetBurn.isLowerBound`). A colour cannot carry a `≥`.
        let isLowerBound: Bool

        /// What the bar draws, 1.0 being a fleet burning exactly what its week
        /// refills. Unclamped: `QuotaBar` clamps at its width
        /// (`testTheLeadBarFillsWithTheRatioAndStopsAtTheRefillRate`).
        var ratio: Double { percent / 100 }

        /// The fleet is burning faster than the week refills, on the ramp's green
        /// anchor (`greenRatioPercent`) so the boundary lives in one place.
        var isOverRefill: Bool { percent >= UsagePopoverView.greenRatioPercent }
    }

    /// The lead's figure, or `nil` when there is none to state.
    ///
    /// Gated by `historiesAreFresh`. `nil` either because the histories are stale
    /// or failed, or because `FleetCapacity.burnAgainstRefill` refused; this
    /// surface has one fallback for both (§2.7 keeps them apart as facts).
    ///
    /// The menu bar draws this same figure through `MenuBarIcon.ratio`; without
    /// it the headline falls back to the quota and the menu bar draws an empty
    /// dashed bar. Neither states a number nobody measured.
    static func headlineRatio(for snapshot: UsageSnapshot, now: Date = Date()) -> HeadlineRatio? {
        guard historiesAreFresh(for: snapshot, now: now),
              let burn = snapshot.fleetBurn else { return nil }
        return HeadlineRatio(percent: burn.percent, isLowerBound: burn.isLowerBound)
    }

    /// A token rate as this surface writes it: `23.8M/h`.
    ///
    /// One decimal and a magnitude letter stepping each thousand, so an idle
    /// fleet reads `0/h` rather than a rounded-away `0.0M/h`.
    static func rateLabel(_ tokensPerHour: Double) -> String {
        for (scale, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "k")] where tokensPerHour >= scale {
            return String(format: "%.1f%@/h", tokensPerHour / scale, suffix)
        }
        return String(format: "%.0f/h", tokensPerHour)
    }

    /// The string in the headline's top row: the burn ratio when there is one,
    /// the mean when there is not, and a dash when there is neither.
    ///
    /// Prints `ratioLabel`, `≥` included: a figure that is a floor says so
    /// wherever it is written out. A function so a test can hold the fallback;
    /// the paint test cannot tell `—` from `100%`.
    static func headlineFigureLabel(for snapshot: UsageSnapshot, now: Date = Date()) -> String {
        if let ratio = headlineRatio(for: snapshot, now: now) { return ratioLabel(for: ratio) }
        return quotaLabel(for: snapshot)
    }

    /// The weekly quota as the headline writes it: the supporting reading under
    /// the lead and the lead's fallback. One function so the two cannot disagree.
    static func quotaLabel(for snapshot: UsageSnapshot) -> String {
        headlinePercent(for: snapshot).map { "\($0)%" } ?? "—"
    }

    /// The colour of that string: the ratio's own, or ink when the headline is
    /// back to being the mean.
    ///
    /// A function so a test can hold it; `UsagePopoverPaintTests` checks the
    /// rendering too.
    ///
    /// The quota figure is never coloured: `QuotaBar.color(for:)` would give it a
    /// second scale beside the ramp. The bar under it does take that scale, drawn
    /// like an account's window row.
    ///
    /// The plate is passed for `ratioColor`'s reason. The ramp reads the ratio
    /// this block states, as does the menu bar (`MenuBarIcon`), so number and
    /// colour come from one division.
    static func headlineFigureColor(for snapshot: UsageSnapshot,
                                    now: Date = Date(),
                                    on background: RampBackground) -> Color {
        headlineRatio(for: snapshot, now: now)
            .map { ratioColor(atPercent: $0.percent, on: background) } ?? .primary
    }

    /// The burn ratio written out as a percentage and qualified: the popover's
    /// lead, and the menu bar's accessibility description after its caption
    /// (`MenuBarIcon.describe`).
    ///
    /// The menu bar's picture drops the `≥` and caps at three digits
    /// (`MenuBarIcon.ceilingPercent`) to fit its 27 pt column; neither limit
    /// applies here.
    ///
    /// `≥` when the burn is a floor: an account sat at its ceiling while measured,
    /// so the true ratio is at least this one
    /// (`FleetCapacity.FleetBurn.isLowerBound`, §2.7). How much higher is unknown.
    ///
    /// Printed through `%.0f` after `rounded()`, not `Int`: `Int(_: Double)` traps
    /// past `Int.max`, and this figure is uncapped. Two readings a microsecond
    /// apart across a hundred-point fall give a ratio around 1.7e16 %, and
    /// `MenuBarIcon.image` calls `describe` on every redraw, so the clamp in
    /// `MenuBarIcon.label` does not cover this path.
    static func ratioLabel(for ratio: HeadlineRatio) -> String {
        (ratio.isLowerBound ? "≥" : "") + String(format: "%.0f%%", ratio.percent.rounded())
    }

    /// The ratio the ramp is coldest at, and below which it stops moving.
    ///
    /// The three anchors are the owner's: "≤ 70 cold blue, 70 → 100 blue through
    /// cyan into green, 100 green, 100 → 130 green through yellow and orange,
    /// ≥ 130 red". Between them `ratioColor(atPercent:on:)` interpolates hue (§4).
    /// 100 is the point where the week goes out as fast as it comes back.
    static let coldRatioPercent: Double = 70
    /// Where the ramp is green: a fleet burning exactly what its week refills.
    /// Shared by this ramp and `HeadlineRatio.isOverRefill` (read by
    /// `MenuBarIcon.warningColor`).
    ///
    /// `nonisolated` because `HeadlineRatio` is not on the main actor; the build
    /// must be clean under `-strict-concurrency=complete`.
    nonisolated static let greenRatioPercent: Double = 100
    /// Where the ramp reaches red and stops moving. Not a ceiling on the figure —
    /// the headline goes on printing whatever it is handed — a ceiling on the
    /// colour, because past half again over the refill rate there is nothing
    /// louder left to say.
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

        /// The same colour at another brightness or saturation; the legibility
        /// rule moves one coordinate at a time and the hue survives both.
        func at(brightness value: Double) -> RampAnchor {
            RampAnchor(hue: hue, saturation: saturation, brightness: value)
        }

        func at(saturation value: Double) -> RampAnchor {
            RampAnchor(hue: hue, saturation: value, brightness: brightness)
        }
    }

    /// The three anchors: `Color.blue`, `Color.green` and `Color.red` in `aqua`
    /// to four figures of hue, the same family `QuotaBar.color(for:)` uses.
    ///
    /// Only the hue survives drawing (`legible(_:on:)`): on a light plate the
    /// brightness drops (blue to 0.7955, red to 0.7451), on a dark one the
    /// saturation does (blue 0.6383, red 0.5228; green is untouched).
    ///
    /// Constants rather than system colours: the system colours resolve to these
    /// values in `aqua`, `vibrantLight` and `vibrantDark` (the status item is
    /// `vibrantDark`, §4) and differ only slightly in `darkAqua`, while dynamic
    /// `NSColor`s cannot be compared for equality, which the menu bar/popover
    /// tests rely on.
    private static let coldAnchor = RampAnchor(hue: 0.5869, saturation: 1.000, brightness: 1.000)
    private static let greenAnchor = RampAnchor(hue: 0.3586, saturation: 0.805, brightness: 0.804)
    private static let hotAnchor = RampAnchor(hue: 0.0089, saturation: 0.812, brightness: 1.000)

    /// The plate a ramp colour is drawn on, and what the legibility rule below
    /// needs to know about it. Measured on this machine (menu bar by screenshot,
    /// popover by rendering `NSVisualEffectView` at `.popover`):
    ///
    ///     light   menu bar rgb 0.883    popover rgb 0.9341
    ///     dark    menu bar rgb 0.17     popover rgb 0.2274
    ///
    /// Flat greys because "Reduce transparency" is on; without it the menu bar
    /// shows the wallpaper and these are only typical. Each case carries the
    /// least favourable plate of its family (darkest light, lightest dark), so a
    /// colour that clears the floor here clears it on the other surface too.
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
        /// bar's frame, `labelColor` at `calmFrameOpacity` (`MenuBarIcon.drawBar`)
        /// composited over `grey`. `labelColor` is black on light and white on
        /// dark, and `withAlphaComponent` replaces the alpha, so this is plain
        /// arithmetic; the rendering agrees
        /// (`testTheWarningIsNeverQuieterThanTheCalmStateItReplaces`).
        var calmInkGrey: Double {
            switch self {
            case .light: return grey * (1 - UsagePopoverView.calmFrameOpacity)
            case .dark: return grey + UsagePopoverView.calmFrameOpacity * (1 - grey)
            }
        }
    }

    /// The contrast every ramp colour has to reach against the plate under it.
    ///
    /// A warning may never be less legible than the calm state it replaces. 4.5
    /// is WCAG's floor for text below 18 pt (the smallest ramp-coloured thing is
    /// the menu bar's 9 pt number), used for everything the ramp paints rather
    /// than a looser 3:1 for graphics, so one 27 pt picture carries one
    /// brightness per reading. Luminance is linearised as WCAG requires.
    static let minimumContrastRatio: Double = 4.5

    /// The opacity the calm bar frame is drawn at (`MenuBarIcon.drawBar`). Lives
    /// here because `contrastFloor` is derived from it.
    ///
    /// `nonisolated` so `RampBackground`, a nested type that does not inherit
    /// this view's isolation, can read it.
    nonisolated static let calmFrameOpacity: Double = 0.55

    /// What every colour on the ramp has to reach against the plate it is drawn
    /// on: the WCAG floor, or the calm frame's own contrast when that is higher.
    ///
    /// Derived rather than fixed because the rule is a comparison: the calm frame
    /// is 4.44 on the light plate (so 4.5 binds) and 4.69 on the dark one (so the
    /// frame binds). On the dark plate the hot end therefore reaches exactly the
    /// calm frame's contrast; antialiasing gives the opaque warning stroke a small
    /// visible edge.
    ///
    /// The calm number (`labelColor` at full strength, 11.61 light, 8.57 dark) is
    /// not the target: no colour that keeps a hue reaches it, so a coloured
    /// number is quieter than ink. The frame is what the warning replaces mark for
    /// mark.
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
    /// A ramp rather than a step, by the owner's decision: a step cannot tell a
    /// fleet at 40% from one at 95%. The intermediate colours are where linear
    /// hue interpolation lands (cyan, then yellow and orange).
    ///
    /// The input is `HeadlineRatio.percent`, the figure the lead states, and both
    /// surfaces pass the same one so the shade always matches the number.
    ///
    /// The hue is the same on both plates; the plate only moves how light the
    /// colour is drawn (`testTheRampMeetsItsContrastFloorOnEveryPlate`).
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
    /// The hue never moves. A colour is darkened away from a light plate and
    /// lightened away from a dark one. Lightening uses two levers, in order:
    ///
    /// 1. Brightness up to 1, enough for the green half of the ramp.
    /// 2. Saturation down, moving along the tint line towards white with the hue
    ///    preserved; the only lever left once brightness is spent.
    ///
    /// On the dark plate this draws the cold blue at saturation 0.6383 and the red
    /// at 0.5228. Desaturating on a light plate would move the colour closer to
    /// the background, hence the `switch` on the plate.
    private static func legible(_ anchor: RampAnchor,
                                on background: RampBackground) -> RampAnchor {
        let floor = contrastFloor(on: background)
        switch background {
        case .light:
            let ceiling = (background.relativeLuminance + contrastOffset) / floor - contrastOffset
            guard luminance(of: anchor) > ceiling else { return anchor }
            // A ceiling at or under zero would mean no colour clears the floor;
            // the bisection then converges on black and the chromatic-marks test
            // fails loudly, rather than returning the colour unchanged.
            //
            // Luminance rises monotonically with brightness, so bisect. Twenty-four
            // halvings leave 6e-8, far below one colour byte.
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

    /// The sRGB components of an anchor at a brightness: the standard HSB
    /// conversion that `Color(hue:saturation:brightness:)` performs. At the three
    /// anchors the round trip through `NSColor` matches to four decimals.
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

    /// WCAG relative luminance of an sRGB triple: linearise each component, then
    /// weigh. Rec. 709 weights on gamma-encoded components would overstate the
    /// ramp's contrast.
    ///
    /// `nonisolated` because `RampBackground`, a nested type, does not inherit the
    /// view's main-actor isolation; it reads no state.
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

    /// When a window starts over. Empty when the gateway named no reset; the row
    /// already has a dash in the percentage.
    ///
    /// The smallest unit written is always explicit, because a bare unit is a
    /// range (`in 1d` is 24 to 48 hours). So the lower unit is printed even at
    /// zero (`in 5d 0h`, `in 4h 0m`); days stop at the hour.
    static func resetLabel(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "resets now" }
        if seconds < 3600 {
            // Minutes round up, so 30 seconds left says `in 1m`. The last minute
            // below an hour would round up to `in 60m`, so it is carried by hand
            // (the branch below floors and would write `in 0h 59m`).
            let minutes = Int((seconds / 60).rounded(.up))
            return minutes < 60 ? "in \(minutes)m" : "in 1h 0m"
        }
        // Hours, days and remainders round down: rounding a countdown up would
        // promise time that is not there (1d 23h 59m must not become `in 2d 0h`).
        if seconds < 86_400 {
            let hours = Int(seconds / 3600)
            return "in \(hours)h \(Int((seconds - Double(hours) * 3600) / 60))m"
        }
        let days = Int(seconds / 86_400)
        return "in \(days)d \(Int((seconds - Double(days) * 86_400) / 3600))h"
    }

    /// What a section with nothing in it says. Three states: "we have not asked
    /// yet" is not "we asked and there is nothing", and a gateway that was down at
    /// launch must not show "Loading…" forever (the failure line explains it).
    static func emptyLabel(landed: Bool, failed: Bool, nothing: String) -> String {
        guard landed else { return failed ? "Gateway did not answer" : "Loading…" }
        return nothing
    }

    /// What the accounts section says when it has nobody to list. A function so
    /// the arguments handed to `emptyLabel` are under test too.
    static func accountsEmptyLabel(_ snapshot: UsageSnapshot) -> String {
        emptyLabel(landed: snapshot.quotaFetchedAt != nil,
                   failed: snapshot.quotaFailure != nil,
                   nothing: "The gateway named no accounts")
    }

    /// What the chart says when it has no line to draw.
    ///
    /// `landed` is about the series for the current period only, not the last
    /// finished pass: a pass in which every account failed is not "the period held
    /// no data", and lines from the previous tab mean "Loading…". An empty account
    /// list after the quota poll landed also counts as landed: there is nobody to
    /// ask, for any period.
    ///
    /// `failed` covers both inputs: the quota poll (the account list) and the
    /// history requests.
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
    /// The three sources this popover shows: the quota poll, the chart's
    /// requests, and the account histories behind the lead figure. Not
    /// `UsageSnapshot.failureText`, which also carries `/gw/sessions`, whose
    /// figures are not on this surface. All failures are listed, since each is a
    /// separate question.
    static func failureText(quota: String?, chart: String?,
                            histories: String?) -> String? {
        let all = [quota, chart, histories].compactMap { $0 }
        return all.isEmpty ? nil : all.joined(separator: "; ")
    }

    /// Below this age the footer says nothing about it at all.
    ///
    /// Two polling intervals: both halves of this view are refetched once a minute
    /// (`UsageHistoryModel.refreshSeconds`, and `UsageStore`), so anything younger
    /// is the poll running normally.
    static let footerStaleSeconds: TimeInterval = 120

    /// How old the oldest thing on this surface is, or `nil` when the footer has
    /// nothing to say. One line: the age of a screen is the age of its oldest
    /// thing. The chart counts only while its lines answer the current period.
    ///
    /// The histories half is excluded: it refreshes every ten minutes, so folding
    /// it in would put a standing `as of 7m ago` under every healthy popover. The
    /// cost is that this line can understate the headline figure's age by up to
    /// `historyStaleSeconds` (e.g. when `/gw/usage` fails, `UsageStore.poll` skips
    /// the histories and no stamp moves); `historyStaleSeconds` removing the
    /// figure is what bounds that.
    ///
    /// Silent when nothing was fetched (the sections say "Loading…" or name the
    /// failure) and when data is fresh. Any failed last check, including
    /// `historiesFailed`, breaks the silence at any age, since then the age is
    /// what tells live figures from frozen ones.
    static func footerAgeLabel(quotaFetchedAt: Date?,
                               quotaFailed: Bool,
                               chartFetchedAt: Date?,
                               seriesPeriod: HistoryPeriod?,
                               period: HistoryPeriod,
                               chartFailed: Bool,
                               historiesFailed: Bool,
                               now: Date) -> String? {
        let chart = seriesPeriod == period ? chartFetchedAt : nil
        guard let oldest = [quotaFetchedAt, chart].compactMap({ $0 }).min() else { return nil }
        guard quotaFailed || chartFailed || historiesFailed
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

/// A quota window as a bar. Both surfaces own their colours (the menu bar's
/// picture is not a template, `MenuBarIcon`), and the ratio uses the continuous
/// ramp on both (`UsagePopoverView.ratioColor`).
///
/// `color(for:)` below answers "how full is this window", for an account's row
/// and the headline's supporting block; its 60 and 85 per cent are thresholds on
/// that. A caller filling a bar with anything else passes its own `tint`.
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
