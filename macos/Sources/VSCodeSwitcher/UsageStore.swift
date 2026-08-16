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
    /// directories.
    static let intervalSeconds: TimeInterval = 60

    /// The window the session figures are asked for. A week, by the user's
    /// decision; the gateway clamps it to its own retention and reports what it
    /// applied.
    ///
    /// `nonisolated` is load-bearing, and this is the one line in the file that
    /// must not lose it. A `static let` on a `@MainActor` type is isolated to
    /// that actor; reading it from `poll` — which is `nonisolated async` — makes
    /// the compiler insert a hop to the main actor, silently and with no
    /// diagnostic under `-strict-concurrency=complete`. Everything after that
    /// read then runs *on the main thread*: two HTTP calls and a walk over the
    /// transcript directories, which is exactly what §6 forbids. It showed up as
    /// `--dump` hanging forever — its main thread waits on the pass, the pass
    /// waits for its main thread — and was found by sampling the stuck process.
    /// `UsageTests.testPollDoesNotNeedTheMainThread` holds it.
    nonisolated static let windowSeconds: TimeInterval = 7 * 86_400

    private let client: UsageClient
    private let cache: UsageCache
    private var timer: Timer?
    /// A pass is running; a tick that lands meanwhile is dropped rather than
    /// queued, because the next one is only a minute away.
    private var pollInFlight = false

    init(config: Config, cache: UsageCache) {
        client = UsageClient(baseURL: config.resolvedUsageBaseURL)
        self.cache = cache
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

    /// One pass: both endpoints, then the join against the local transcripts.
    ///
    /// Each half is kept separately, because they fail separately — the quota
    /// figures can arrive while the session figures time out. Whatever did not
    /// arrive stays at its previous value and is blamed in its own half of the
    /// snapshot; the quota half, the only one drawn with its age beside it,
    /// keeps the stamp it arrived under. Only `checkedAt` moves on every pass: it
    /// is the age of the attempt, and saying it out loud over unchanged numbers
    /// is what made the footer call hour-old figures fresh.
    nonisolated static func poll(client: UsageClient,
                                 previous: UsageSnapshot,
                                 now: Date = Date()) async -> UsageSnapshot {
        var result = previous
        result.checkedAt = now

        do {
            let report = try await client.usage()
            result.fleetSevenDayMean = report.fleet?.sevenDay?.mean
            result.accounts = report.accounts
            result.quotaFetchedAt = now
            result.quotaFailure = nil
        } catch {
            result.quotaFailure = "/gw/usage: \(error)"
        }

        do {
            let report = try await client.sessions(since: now.addingTimeInterval(-windowSeconds))
            let identifiers = Set(report.sessions.map(\.sessionId))
            let folded = UsageIndex.fold(sessions: report.sessions,
                                         slugsBySessionId: UsageIndex.slugsBySessionId(for: identifiers))
            result.since = report.since
            result.truncated = report.truncated
            result.tokensBySlug = folded.tokensBySlug
            result.contested = folded.contested
            result.unmatched = folded.unmatched
            result.unmatchedSessions = folded.unmatchedSessions
            result.sessionsFailure = nil
        } catch {
            result.sessionsFailure = "/gw/sessions: \(error)"
        }

        return result
    }

    /// One pass, run to completion on the calling thread. `--dump` is a
    /// straight-line console tool: it has no run loop, no store and no second
    /// chance to print the numbers later.
    ///
    /// A gateway that is not there is already handled inside the pass — each
    /// call gives up after five seconds and the reason comes back inside the
    /// snapshot. The watchdog on the wait is for the other failure, the one
    /// that actually happened here: a pass that hopped to the main actor and
    /// waited for the very thread standing on this semaphore. That is fixed and
    /// held by a test; the watchdog is what turns its return into a printed line
    /// instead of a dump that never comes back.
    nonisolated static func pollOnce(config: Config, now: Date = Date()) -> UsageSnapshot {
        let client = UsageClient(baseURL: config.resolvedUsageBaseURL)
        let box = PollResult()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await UsageStore.poll(client: client, previous: .empty, now: now)
            semaphore.signal()
        }
        // Two calls at five seconds each, plus the directory walk, with room to
        // spare.
        guard semaphore.wait(timeout: .now() + 20) == .success else {
            var stalled = UsageSnapshot.empty
            stalled.checkedAt = now
            // Neither half answered, so both are blamed: nothing about a pass
            // that never came back is specific to one endpoint.
            stalled.quotaFailure = "the pass did not finish in 20 s"
            stalled.sessionsFailure = "the pass did not finish in 20 s"
            return stalled
        }
        return box.value
    }

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
