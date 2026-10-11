import Combine
import Foundation

/// The last usage snapshot, readable synchronously from any thread.
///
/// `DataSource.build()` runs once or twice a second and has to stay disk-bound
/// (SPEC §6), so it reads this instead of waiting on a gateway that may not
/// answer for five seconds. The network lives in `UsageStore` alone.
///
/// `@unchecked Sendable`: the stored value is only ever touched under the lock.
final class UsageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UsageSnapshot = .empty

    var snapshot: UsageSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ value: UsageSnapshot) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

/// Polls the claude_gw gateway and keeps one always-available answer.
///
/// A gateway that is not there is the ordinary case, not a fault: the relay is a
/// launchd job, the tunnel goes up and down with the network. A failed pass
/// fills in `failure` and keeps the numbers from the pass before it — slightly
/// stale beats blank — and nothing about it reaches the rest of the app.
@MainActor
final class UsageStore: ObservableObject {

    @Published private(set) var snapshot: UsageSnapshot = .empty

    /// How often the gateway is asked. The figures it reports move over minutes,
    /// and every pass costs two HTTP round trips plus a walk over the transcript
    /// directories. The third endpoint, the accounts' histories, is on the far
    /// slower schedule of `historyIntervalSeconds` and is not part of this cost.
    static let intervalSeconds: TimeInterval = 60

    /// The window the session figures are asked for: a week, by the user's
    /// decision. The gateway serves exactly the window sent (checked at 30 and 90
    /// days, §2.7).
    ///
    /// `nonisolated` is load-bearing here and on `historyWindowSeconds`: a
    /// `static let` on a `@MainActor` type is main-actor isolated, and reading it
    /// from the `nonisolated async` `poll` makes the compiler insert a silent hop
    /// to the main actor (no diagnostic under `-strict-concurrency=complete`).
    /// Everything after the read then runs on the main thread, which §6 forbids,
    /// and `--dump` deadlocks (its main thread waits on the pass).
    /// `UsageTests.testPollDoesNotNeedTheMainThread` holds it.
    nonisolated static let windowSeconds: TimeInterval = 7 * 86_400

    /// The sliding window the per-row rate is counted over.
    ///
    /// Must stay an hour: the gateway's aggregates are windowed (§2.9), so tokens
    /// over the last 3600 s are already tokens per hour and nothing divides.
    /// Another length would silently stop being a rate while keeping the label.
    ///
    /// A separate request because the week's answer is one aggregate per session
    /// and cannot be sliced. It adds about 6% to the pass (6.7 KiB against
    /// 107.8 KiB for the week).
    ///
    /// `nonisolated`, guarded twice: reads inside the `async let` autoclosures make
    /// the build emit warnings under `-strict-concurrency=complete`, and the read
    /// in `sessionsBlame`'s argument would hop to the main thread, which
    /// `UsageTests.testPollDoesNotNeedTheMainThread` and
    /// `testTheHistoriesPassDoesNotNeedTheMainThread` catch on their timeouts.
    nonisolated static let hourWindowSeconds: TimeInterval = 3600

    /// How often the accounts' histories are fetched, which is not how often the
    /// gateway is polled.
    ///
    /// Bandwidth sets it. The ratio over the trailing
    /// `FleetCapacity.burnWindowHours` does move within ten minutes, so a faster
    /// cadence would be fresher, but one round over the fleet is ~250 KB (three
    /// accounts over `historyWindowSeconds`): 1.5 MB/h at ten minutes, 15 MB/h at
    /// one, on a laptop often tethered to a phone. What is on screen can be up to
    /// 600 s old; past two intervals both surfaces drop it
    /// (`UsagePopoverView.historyStaleSeconds`).
    ///
    /// `nonisolated` for `windowSeconds`' reason, but its readers
    /// (`shouldFetchHistories`, `UsagePopoverView.historyStaleSeconds`) are
    /// synchronous, so losing the keyword gives a warning under
    /// `-strict-concurrency=complete` rather than a hang. An `async` reader would
    /// bring `windowSeconds`' failure mode.
    nonisolated static let historyIntervalSeconds: TimeInterval = 600

    /// The window the histories are asked over.
    ///
    /// The gateway caps each history at `max_points` = 2000, and the cap, not
    /// retention, limits depth (it binds according to how often the gateway polls
    /// each account). Measured against all three accounts:
    ///
    ///     since   acc2                      acc3                      main
    ///      48 h   47.91 h, 1853 pts         47.88 h,  632 pts         43.09 h, 2000, truncated
    ///      72 h   59.89 h, 2000, truncated  71.95 h, 1519 pts         43.09 h, 2000, truncated
    ///     168 h   59.89 h, 2000, truncated  86.83 h, 2000, truncated  43.09 h, 2000, truncated
    ///
    /// The only reader is `FleetCapacity.burnAgainstRefill` (through `histories`),
    /// which discards everything older than `FleetCapacity.burnWindowHours`; the
    /// popover's chart asks for its own `HistoryPeriod` windows. So 48 h is
    /// oversized (one round costs about 1.1 MB/h more than an 8 h fetch would):
    ///
    ///     since   acc2      acc3       main      total     at one round / 10 min
    ///       8 h   21666       131 B    22667      44464 B   0.27 MB/h
    ///      12 h   32972       131 B    26843      59946 B   0.36 MB/h
    ///      48 h   94769    126142      27104     248015 B   1.49 MB/h
    ///
    /// Shortening it needs its own measurement of the slack a window anchored at
    /// the same `now` as its trim requires. The test on this constant asserts the
    /// value.
    ///
    /// `nonisolated` is load-bearing: `poll` is `async` and reads this directly,
    /// so without it the pass hops to the main thread and deadlocks against
    /// `pollOnce`; `UsageTests.testTheHistoriesPassDoesNotNeedTheMainThread` times
    /// out.
    nonisolated static let historyWindowSeconds: TimeInterval = 48 * 3600

    private let client: UsageClient
    private let cache: UsageCache
    private var timer: Timer?
    /// A pass is running; a tick that lands meanwhile is dropped rather than
    /// queued, because the next one is only a minute away.
    private var pollInFlight = false

    /// The store publishes whatever its cache already holds, rather than starting
    /// at `.empty`, so the store and the cache `DataSource.build()` reads (§6)
    /// never disagree. In the app the cache starts empty; `UsagePopoverPaintTests`
    /// seeds it to put a landed poll on screen.
    init(config: Config, cache: UsageCache) {
        client = UsageClient(baseURL: config.resolvedUsageBaseURL)
        self.cache = cache
        snapshot = cache.snapshot
    }

    // MARK: - Lifecycle

    func start() {
        schedule()
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One pass, now. Private because `start()` is the only caller there is:
    /// nothing in the UI asks for these numbers on demand, and the timer is
    /// the whole schedule.
    private func refresh() {
        guard !pollInFlight else { return }
        pollInFlight = true
        let client = client
        let previous = snapshot
        Task { [weak self] in
            // `poll` is `nonisolated async`, so it does not inherit the main
            // actor: the HTTP calls and the transcript walk both happen off the
            // main thread and only the finished value comes back.
            let value = await UsageStore.poll(client: client, previous: previous)
            guard let self else { return }
            self.apply(value)
        }
    }

    /// One pass: the endpoints, then the join against the local transcripts.
    ///
    /// Each half is kept separately, because they fail separately. Whatever did
    /// not arrive stays at its previous value and is blamed in its own half of the
    /// snapshot; stamps record when figures arrived, not the attempt.
    ///
    /// The histories half runs only once every `historyIntervalSeconds`; other
    /// passes leave its figure untouched.
    ///
    /// `projectsDirectory` is a test seam, like the defaulted argument on
    /// `UsageIndex.slugsBySessionId` and `ClaudeSessions.sessionTimes`.
    nonisolated static func poll(client: UsageClient,
                                 previous: UsageSnapshot,
                                 now: Date = Date(),
                                 projectsDirectory: URL = ClaudeSessions.projectsDirectory)
        async -> UsageSnapshot {
        var result = previous

        do {
            let report = try await client.usage()
            result.fleetSevenDayMean = report.fleet?.sevenDay?.mean
            // Measured by the gateway; `TokenRate.perHour` only weights the four
            // counters and scales to an hour. Rides on the quota half's stamp.
            result.fleetTokenRate = report.fleet?.tokens?.perHour()
            result.accounts = report.accounts
            result.quotaFetchedAt = now
            result.quotaFailure = nil
        } catch {
            result.quotaFailure = "/gw/usage: \(error)"
        }

        // The histories' own half. It goes after the quota half and only if that
        // one answered, because it needs both things the answer carries: the
        // fleet's membership, and each account's window boundary.
        if result.quotaFailure == nil, shouldFetchHistories(previous: previous, now: now) {
            // The attempt is stamped whatever comes of it, so a failing half
            // retries on its own ten-minute cadence rather than every minute
            // (each round is hundreds of KB). On a failure both surfaces remove
            // the figure and the footer names the endpoint; one transient error
            // costs up to 600 s without the figure.
            result.historiesCheckedAt = now
            // Who is out of the rotation, asked on the histories' cadence: 6.4 KB
            // against the 130–187 KB of the histories beside it.
            //
            // It fails open: if `/gw/status` fails, switched-off accounts stay in
            // the measurement. A frozen series carries the rate it had when the
            // gateway stopped polling it, so the mean can be off by up to ~30
            // points either way. That error lasts at most
            // `FleetCapacity.burnWindowHours - minimumMeasuredHours` = 2 h after a
            // switch-off, when the frozen series ages out of the window, and is
            // preferred over blanking the headline on every blip. The bound holds
            // only while the gateway stops polling switched-off accounts; the
            // blame line makes an outage visible.
            var switchedOff: Set<String> = []
            do {
                switchedOff = Set(try await client.status().accounts
                    .filter(\.disabled).map(\.label))
                result.rotationFailure = nil
            } catch {
                result.rotationFailure = "/gw/status: \(error)"
            }
            do {
                let series = try await histories(client: client,
                                                 labels: result.accounts.map(\.label),
                                                 since: now.addingTimeInterval(-historyWindowSeconds))
                result.fleetBurn = FleetCapacity.burnAgainstRefill(histories: series,
                                                                   accounts: result.accounts,
                                                                   switchedOff: switchedOff,
                                                                   now: now)
                // Stamped on arrival, like `quotaFetchedAt`. A `nil` from
                // `burnAgainstRefill` is an arrival too ("there is no figure"),
                // and must not leave the previous number standing.
                result.historiesFetchedAt = now
                result.historiesFailure = nil
            } catch {
                result.historiesFailure = "/gw/usage/<label>/history: \(error)"
            }
        }

        // The sessions half: the week a row's total spend is counted over, and
        // the sliding hour that makes it a rate.
        //
        // Started together so the half costs one `UsageClient.timeoutSeconds`,
        // awaited separately so each is blamed with its window (both hit
        // `/gw/sessions`, §4).
        async let weekAttempt = attempt {
            try await client.sessions(since: now.addingTimeInterval(-windowSeconds))
        }
        async let hourAttempt = attempt {
            try await client.sessions(since: now.addingTimeInterval(-hourWindowSeconds))
        }
        let week = await weekAttempt
        let hour = await hourAttempt

        // One resolution for both reports: `slugsBySessionId` walks every slug
        // directory under `~/.claude/projects` and is the expensive part (§6).
        // The union of ids, because the week's list is capped at the gateway's 200
        // largest consumers, so a live session can be in the hour and missing from
        // the week.
        var identifiers = Set<String>()
        if case .answered(let report) = week { identifiers.formUnion(report.sessions.map(\.sessionId)) }
        if case .answered(let report) = hour { identifiers.formUnion(report.sessions.map(\.sessionId)) }
        let slugsBySessionId = UsageIndex.slugsBySessionId(for: identifiers,
                                                          projectsDirectory: projectsDirectory)

        // Each report updates its own figures; one failing does not discard the
        // other's.
        var blame: [String] = []
        switch week {
        case .answered(let report):
            let folded = UsageIndex.fold(sessions: report.sessions,
                                         slugsBySessionId: slugsBySessionId)
            result.since = report.since
            result.truncated = report.truncated
            result.tokensBySlug = folded.tokensBySlug
            // Narrowed against this window: a life last written three days ago is
            // inside the week and outside the hour.
            result.contested = UsageIndex.narrowToWindow(
                folded.contested,
                since: now.addingTimeInterval(-windowSeconds),
                projectsDirectory: projectsDirectory)
            result.unmatched = folded.unmatched
            result.unmatchedSessions = folded.unmatchedSessions
        case .failed(let reason):
            blame.append(sessionsBlame(window: windowSeconds, reason: reason))
        }
        switch hour {
        case .answered(let report):
            // Folded exactly as the week is, against the same map and by the same
            // function, so there is one policy for "whose spend is this".
            let folded = UsageIndex.fold(sessions: report.sessions,
                                         slugsBySessionId: slugsBySessionId)
            result.hourlyTokensBySlug = folded.tokensBySlug
            result.hourlyContested = UsageIndex.narrowToWindow(
                folded.contested,
                since: now.addingTimeInterval(-hourWindowSeconds),
                projectsDirectory: projectsDirectory)
            // The hour's ownerless spend, as the week keeps it; it fills and
            // empties with the sliding hour.
            result.hourlyUnmatched = folded.unmatched
            result.hourlyUnmatchedSessions = folded.unmatchedSessions
        case .failed(let reason):
            blame.append(sessionsBlame(window: hourWindowSeconds, reason: reason))
        }
        result.sessionsFailure = blame.isEmpty ? nil : blame.joined(separator: "; ")

        return result
    }

    /// Whether this pass fetches the histories, or leaves the previous figure
    /// alone.
    ///
    /// Asked of the previous snapshot's stamp, not a stored deadline, so
    /// `pollOnce` (starting from `.empty`, stamp `nil`) always fetches. The stamp
    /// is of the attempt, so a failed round counts against the next and a
    /// failing `/history` is not refetched every minute.
    nonisolated static func shouldFetchHistories(previous: UsageSnapshot, now: Date) -> Bool {
        guard let last = previous.historiesCheckedAt else { return true }
        return now.timeIntervalSince(last) >= historyIntervalSeconds
    }

    /// One request's answer, or why there is none, as text.
    ///
    /// Lets the sessions half start its two requests together and blame them
    /// apart: a thrown error from `async let` cannot say which request threw.
    /// Text because `any Error` is not `Sendable` and the blame is only printed.
    enum Attempt<Answer: Sendable>: Sendable {
        case answered(Answer)
        case failed(String)
    }

    /// Runs one request and keeps whichever of the two it produced.
    private nonisolated static func attempt<Answer: Sendable>(
        _ work: @Sendable () async throws -> Answer) async -> Attempt<Answer> {
        do { return .answered(try await work()) } catch { return .failed("\(error)") }
    }

    /// The blame one of the two session calls leaves, naming the window it asked
    /// for as well as the path, since both calls go to `/gw/sessions` (§4). The
    /// window is rendered from the constant so the label follows it.
    ///
    /// Named `window` rather than `windowSeconds` so it does not shadow the week's
    /// constant inside this body.
    private nonisolated static func sessionsBlame(window: TimeInterval,
                                                  reason: String) -> String {
        "/gw/sessions?since=-\(Int(window / 3600))h: \(reason)"
    }

    /// One history per account, in parallel, keyed by the label that was asked
    /// for rather than the one the body echoes, as in `UsageHistoryModel.load`.
    ///
    /// Raw points, unlike `UsageHistoryModel.load`'s `withoutSourceLag`: a lone
    /// reading below the ceiling among ceiling readings is what keeps a pinned
    /// account inside the measurement, and the filter would delete it
    /// (`FleetCapacity.measure`).
    ///
    /// In parallel so `pollOnce`'s watchdog bound does not grow with the fleet.
    /// `URLSession.shared` opens at most 6 connections per host and the timeout
    /// starts when a task is queued, so past six accounts the tail times out and
    /// the half comes back blamed, but the bound still holds.
    ///
    /// One account failing fails the half: keeping the previous figure and naming
    /// the blame, as the other halves do, beats moving the figure on a transient
    /// fault with nothing saying which accounts it covers.
    private nonisolated static func histories(client: UsageClient,
                                              labels: [String],
                                              since: Date) async throws -> [String: HistorySeries] {
        try await withThrowingTaskGroup(of: (String, HistorySeries).self) { group in
            for label in labels {
                group.addTask { (label, try await client.history(label: label, since: since)) }
            }
            var byLabel: [String: HistorySeries] = [:]
            for try await (label, series) in group { byLabel[label] = series }
            return byLabel
        }
    }

    /// One pass, run to completion on the calling thread, for `--dump`, a
    /// straight-line console tool with no run loop.
    ///
    /// Each call already gives up after five seconds. The watchdog guards against
    /// a pass that hops to the main actor and waits on the thread blocked on this
    /// semaphore (held by a test); it turns that into a printed line instead of a
    /// hang.
    nonisolated static func pollOnce(config: Config, now: Date = Date()) -> UsageSnapshot {
        let client = UsageClient(baseURL: config.resolvedUsageBaseURL)
        let box = PollResult()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await UsageStore.poll(client: client, previous: .empty, now: now)
            semaphore.signal()
        }
        // Three rounds of five seconds (`/gw/usage`, the histories half,
        // `/gw/sessions` over week and hour) plus the directory walk, with room to
        // spare. Histories are fetched in parallel so this bound does not grow
        // with the fleet (past six accounts the tail times out instead, see
        // `histories`).
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            var stalled = UsageSnapshot.empty
            // No half answered, so all three are blamed: nothing about a pass
            // that never came back is specific to one endpoint.
            stalled.quotaFailure = "the pass did not finish in 30 s"
            stalled.historiesFailure = "the pass did not finish in 30 s"
            stalled.sessionsFailure = "the pass did not finish in 30 s"
            return stalled
        }
        return box.value
    }

    /// A finished pass, published, cached, and the latch released.
    ///
    /// Private because of the latch: a caller from outside the pass would clear
    /// `pollInFlight` under a pass still running. Tests seed the cache instead.
    private func apply(_ value: UsageSnapshot) {
        snapshot = value
        // Written on a failed pass too: the value carries the previous numbers
        // and the new `failure`, and the cache must never hold anything the
        // store does not.
        cache.store(value)
        pollInFlight = false
    }

    // MARK: - Timer

    private func schedule() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.intervalSeconds, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        // `.common`, like the snapshot poll: a menu or a resize loop must not
        // stop it.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// Carries the result of one pass out to a synchronous caller.
///
/// `@unchecked Sendable`: written once inside the task and read only after the
/// semaphore has been signalled, which orders the two.
private final class PollResult: @unchecked Sendable {
    var value: UsageSnapshot = .empty
}
