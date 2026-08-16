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
    /// Why the last pass was incomplete, if it was. Kept beside the previous
    /// series rather than replacing them, exactly as `UsageStore` does.
    @Published private(set) var failure: String?
    /// When the lines on screen arrived, or `nil` while there are none.
    ///
    /// The age of the *series*, never the age of the attempt — the same split
    /// `UsageSnapshot` makes between `quotaFetchedAt` and `checkedAt`, and for
    /// the same reason. One stamp for both moved on every pass that finished,
    /// including the one where not a single account answered, and the chart then
    /// reported that the period held no data on the strength of an answer nobody
    /// had given.
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
    /// Ticks while the popover is open, so "updated N ago" stays true without a
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
    /// How often the clock behind "updated N ago" is nudged. Coarse on purpose:
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
        var failure: String?
    }

    /// One request per account, in parallel, with each account's failure kept as
    /// text instead of an error: an account the gateway will not answer for is
    /// an ordinary state, and the others still have a chart to draw.
    nonisolated static func load(client: UsageClient,
                                 labels: [String],
                                 since: Date) async -> Loaded {
        struct Fetched: Sendable {
            var series: AccountSeries
            var failure: String?
        }
        var series: [AccountSeries] = []
        var failures: [String] = []
        await withTaskGroup(of: Fetched.self) { group in
            for label in labels {
                group.addTask {
                    do {
                        let answer = try await client.history(label: label, since: since)
                        return Fetched(series: AccountSeries.make(label: label, points: answer.points),
                                       failure: nil)
                    } catch {
                        return Fetched(series: AccountSeries(label: label, segments: []),
                                       failure: "\(label): \(error)")
                    }
                }
            }
            for await item in group {
                if let failure = item.failure {
                    failures.append(failure)
                } else {
                    series.append(item.series)
                }
            }
        }
        series.sort { $0.label < $1.label }
        failures.sort()
        return Loaded(series: series, failure: failures.isEmpty ? nil : failures.joined(separator: "; "))
    }

    private func apply(_ loaded: Loaded, period: HistoryPeriod) {
        let moment = Date()
        if !loaded.series.isEmpty {
            // Somebody answered: these are the lines, and this is when they
            // arrived. An account that answered with nothing but holes is still
            // an answer — its entry is here, empty, and the chart may then
            // honestly say the period held no data.
            series = loaded.series
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
/// full size, then each account's two windows, then utilisation over time, then
/// how old all of it is.
struct UsagePopoverView: View {

    @ObservedObject var usage: UsageStore
    @ObservedObject var history: UsageHistoryModel

    /// The width of the popover. Wide enough for the chart's axis labels and a
    /// reset time on the same line as its bar.
    static let width: CGFloat = 320

    /// The one symbol in this view. Held by `testEverySymbolNameActuallyResolves`
    /// along with the row's four: an unknown name draws nothing at all.
    static let failureSymbolName = "exclamationmark.triangle.fill"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline
            Divider()
            accounts
            Divider()
            chart
            Divider()
            footer
        }
        .padding(14)
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
    private var headline: some View {
        let percent = Self.headlinePercent(for: usage.snapshot)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(percent.map { "\($0)%" } ?? "—")
                    .font(.system(size: 30, weight: .semibold))
                    .monospacedDigit()
                Text("недельная квота, среднее по флоту")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            QuotaBar(fraction: percent.map { Double($0) / 100 }, height: 8)
        }
    }

    // MARK: Accounts

    @ViewBuilder private var accounts: some View {
        if usage.snapshot.accounts.isEmpty {
            Text(Self.accountsEmptyLabel(usage.snapshot))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(usage.snapshot.accounts, id: \.label) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.label)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
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
                .frame(width: 74, alignment: .trailing)
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

            // The difference between the big number above and the lines below is
            // real and has to be said out loud rather than left to be inferred:
            // the gateway has no fleet-average series yet (asked for in issue 7),
            // so the chart can only be per account. Two quantities in one view
            // with nothing marking the boundary is exactly what §4 took out of
            // the row.
            Text("Линии — по аккаунтам; ряда «среднее по флоту» шлюз пока не отдаёт.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    // runs of one account share it and the legend has one entry
                    // per account rather than one per run.
                    ForEach(account.segments) { segment in
                        if segment.readings.count == 1, let only = segment.readings.first {
                            // A run of one draws no line at all — a reading
                            // alone between two holes would simply be missing.
                            PointMark(x: .value("время", only.timestamp),
                                      y: .value("%", only.value))
                            .foregroundStyle(by: .value("аккаунт", account.label))
                            .symbolSize(8)
                        } else {
                            ForEach(segment.readings, id: \.timestamp) { reading in
                                LineMark(x: .value("время", reading.timestamp),
                                         y: .value("%", reading.value),
                                         series: .value("отрезок", "\(account.label)#\(segment.id)"))
                                .foregroundStyle(by: .value("аккаунт", account.label))
                            }
                        }
                    }
                }
            }
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
            .chartLegend(position: .bottom, spacing: 4)
            .font(.system(size: 9))
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.ageLabel(fetchedAt: usage.snapshot.quotaFetchedAt,
                               checkedAt: usage.snapshot.checkedAt,
                               failed: usage.snapshot.quotaFailure != nil,
                               now: history.now))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(Self.chartAgeLabel(fetchedAt: history.fetchedAt,
                                    seriesPeriod: history.seriesPeriod,
                                    period: history.period,
                                    now: history.now))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if let failure = Self.failureText(quota: usage.snapshot.quotaFailure,
                                              history: history.failure) {
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

    /// A utilisation as the popover writes it. A dash when the gateway had no
    /// reading — never a zero (§2.4: a confidently wrong figure is worse than a
    /// missing one).
    static func percentLabel(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// When a window starts over, in the coarsest unit that still separates two
    /// of them. Empty when the gateway named no reset — the row has a dash in
    /// the percentage already, and a second one adds nothing.
    static func resetLabel(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "сброс вот-вот" }
        if seconds < 3600 { return "через \(Int((seconds / 60).rounded(.up))) мин" }
        if seconds < 86_400 { return "через \(Int(seconds / 3600)) ч" }
        return "через \(Int(seconds / 86_400)) д"
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
        guard landed else { return failed ? "Шлюз не ответил" : "Загрузка…" }
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
                   nothing: "Аккаунтов шлюз не назвал")
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
    /// nothing landed at all — which is "Загрузка…", not "the period held no
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
                          nothing: "За этот период данных нет")
    }

    /// How old the chart's lines are, said apart from the quota's age above
    /// because they are fetched apart: the quota is polled for the whole life of
    /// the process, the lines only while the popover is open — and they survive
    /// its closing, so a chart drawn from a pass made three popovers ago is the
    /// ordinary case rather than the odd one.
    ///
    /// No "the last check failed" clause of its own, unlike `ageLabel`: the
    /// reason is in the failure line two rows down, and `fetchedAt` here already
    /// refuses to move for a pass that brought no lines, so this sentence cannot
    /// contradict it.
    ///
    /// The same pair `plotEmptyLabel` is given, and for the same reason one row
    /// up: between a tap on `30d` and the answer to it the stamp in hand belongs
    /// to the previous window's lines, which the plot above is no longer
    /// drawing. Dated all the same, the footer said "график обновлён N назад"
    /// directly under "Загрузка…" — reachable on every change of period, for as
    /// long as the gateway takes, and surviving the popover's closing with the
    /// lines it dates. So in that state the chart is not dated at all, in the
    /// words of a chart that has no lines yet: it has none for the window being
    /// asked about.
    static func chartAgeLabel(fetchedAt: Date?,
                              seriesPeriod: HistoryPeriod?,
                              period: HistoryPeriod,
                              now: Date) -> String {
        guard let fetchedAt, seriesPeriod == period else { return "график ещё не обновлялся" }
        return "график обновлён \(ago(fetchedAt, now: now))"
    }

    /// The reasons behind what this view draws, all of them at once.
    ///
    /// The two halves are the two this popover shows: the quota poll and the
    /// chart's own requests. `UsageSnapshot.failureText` is the wrong source
    /// here — it also carries `/gw/sessions`, whose figures live in the panel's
    /// rows and not one of which is on this surface. Shown instead of the
    /// chart's own reason (and it was, being first), it left an empty chart with
    /// its cause named nowhere while explaining a number the user cannot see.
    ///
    /// Both when both failed, for the same reason: they are separate questions,
    /// and the first non-empty of them is not an answer to the other.
    static func failureText(quota: String?, history: String?) -> String? {
        let both = [quota, history].compactMap { $0 }
        return both.isEmpty ? nil : both.joined(separator: "; ")
    }

    /// How old the figures above are, and — separately — how the last attempt at
    /// them went.
    ///
    /// Two stamps rather than one, because they are two facts: `fetchedAt` is
    /// when these numbers arrived, `checkedAt` is when we last asked for any. A
    /// failed pass keeps the numbers and moves only the second, so a single
    /// stamp had the footer calling hour-old figures fresh while the orange line
    /// under it said the gateway was unreachable.
    ///
    /// Not finer than a minute, because that is how often they are asked for: a
    /// footer counting seconds would spend most of its life saying something
    /// that stopped being true a moment after it was drawn.
    static func ageLabel(fetchedAt: Date?, checkedAt: Date, failed: Bool, now: Date) -> String {
        let age = fetchedAt.map { "обновлено \(ago($0, now: now))" } ?? "ещё не обновлялось"
        guard failed else { return age }
        return "\(age); последняя проверка \(ago(checkedAt, now: now)) не удалась"
    }

    /// How long ago a moment was, in the coarsest unit that still says anything.
    static func ago(_ moment: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(moment))
        if seconds < 60 { return "меньше минуты назад" }
        if seconds < 3600 { return "\(Int(seconds / 60)) мин назад" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) ч назад" }
        return "\(Int(seconds / 86_400)) д назад"
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

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                if let fraction {
                    Capsule()
                        .fill(Self.color(for: fraction))
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
