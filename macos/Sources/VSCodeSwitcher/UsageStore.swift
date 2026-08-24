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
    /// slower schedule of `allowanceIntervalSeconds` and is not part of this
    /// cost.
    static let intervalSeconds: TimeInterval = 60

    /// The window the session figures are asked for. A week, by the user's
    /// decision; the gateway clamps it to its own retention and reports what it
    /// applied.
    ///
    /// `nonisolated` is load-bearing, and there are **two** lines in the file
    /// that must not lose it: this one and `historyWindowSeconds` below, whose
    /// own doc block spells the same failure out with its own timed test. (The
    /// third, `allowanceIntervalSeconds`, also carries the keyword but for a
    /// different reason — it has no `async` reader, so nothing hangs and a
    /// warning is what guards it. Its doc says so, and the difference is the
    /// point.) A `static let` on a `@MainActor` type is isolated to that actor;
    /// reading it from `poll` — which is `nonisolated async` — makes the
    /// compiler insert a hop to the main actor, silently and with no diagnostic
    /// under `-strict-concurrency=complete`. Everything after that read then
    /// runs *on the main thread*: from here, `/gw/sessions` and the walk over
    /// the transcript directories; from the hop on `historyWindowSeconds`,
    /// which `poll` reads earlier, the whole pass — no longer two HTTP calls but
    /// 2 + N, `/gw/usage` and `/gw/sessions` plus one history per account on the
    /// passes that fetch them. Which is exactly what §6 forbids. It showed up as
    /// `--dump` hanging forever — its main thread waits on the pass, the pass
    /// waits for its main thread — and was found by sampling the stuck process.
    /// `UsageTests.testPollDoesNotNeedTheMainThread` holds it.
    nonisolated static let windowSeconds: TimeInterval = 7 * 86_400

    /// How often the accounts' histories are fetched, which is not how often the
    /// gateway is polled.
    ///
    /// The allowance is an average over two days: it cannot move fast, and
    /// nothing is gained by asking ten times an hour. What is spent is real —
    /// one request per account of roughly 150 KB, which at the once-a-minute
    /// cadence of the rest of the pass is tens of megabytes an hour on a laptop
    /// that is often on a phone's tether.
    ///
    /// `nonisolated` for the reason spelled out over `windowSeconds` — but what
    /// guards it is not the same thing, and the difference was found by taking
    /// the keyword off (2026-08-17). Neither of its two readers is `async`:
    /// `shouldFetchAllowance` below is *synchronous*, and
    /// `UsagePopoverView.allowanceStaleSeconds` — which is two of these intervals, the
    /// age past which neither surface will show the figure — is a constant read
    /// on the main actor anyway. There is nowhere for the compiler to put a hop,
    /// so it emits none and nothing hangs; the timed test below stays green. What
    /// it emits instead is a warning under `-strict-concurrency=complete`, and a
    /// build that has to be clean under that flag is this line's guard. Give the
    /// constant an `async` reader and it inherits `windowSeconds`' failure mode
    /// along with its test.
    nonisolated static let allowanceIntervalSeconds: TimeInterval = 600

    /// The window the histories and the spend beside them are asked for. A
    /// constant, and it is the only window there is.
    ///
    /// **Two days rather than the seven the session figures use**, because seven
    /// is not on offer: the gateway's deepest answer is 2.2 to 2.7 days and
    /// asking for a week returns exactly the same points. Asking for what can be
    /// served keeps the request honest about its own depth, and
    /// `SustainableRate.measuredHours` reports what actually came back.
    ///
    /// **And a constant rather than a setting, which it was until the demand
    /// estimators went.** `usageLoadWindowHours` chose between two ways of
    /// estimating a week's demand and, by the same number, how deep to ask; both
    /// estimators are gone, and what is left has no use for a shorter window and
    /// two reasons to want this one. The floor: the allowance needs each
    /// account's day split into working and sleeping hours, and a series shorter
    /// than a day has not seen every hour of the day even once
    /// (`FleetCapacity.measureHourly` refuses it), so anything under 24 h answers
    /// nothing at all. The ceiling: what a longer window buys is a steadier
    /// exchange rate over more whole percentage points, and it is already
    /// steady — 6.934, 7.047 and 7.044 M tokens per point at 12, 24 and 48 h
    /// (2026-08-24, three accounts, a spread of 1.6%) — while past 48 h the
    /// gateway simply has nothing more to give.
    ///
    /// `nonisolated`, and here it is load-bearing in the original way: `poll` is
    /// `async` and reads this one directly, so without the keyword the compiler
    /// inserts a hop and the histories, the sessions call and the transcript
    /// walk all run on the main thread. Taken off, the pass deadlocks against
    /// the very thread `pollOnce` blocks on and
    /// `UsageTests.testTheAllowancePassDoesNotNeedTheMainThread` times out at
    /// 5.1 s (measured 2026-08-17). The timeout is what makes that a failure
    /// instead of a run that never comes back.
    nonisolated static let historyWindowSeconds: TimeInterval = 48 * 3600

    private let client: UsageClient
    private let cache: UsageCache
    private var timer: Timer?
    /// A pass is running; a tick that lands meanwhile is dropped rather than
    /// queued, because the next one is only a minute away.
    private var pollInFlight = false

    /// The store publishes whatever its cache already holds, rather than starting
    /// at `.empty`.
    ///
    /// The cache is this store's own last pass, read synchronously by
    /// `DataSource.build()` (§6); a store built over one that has a value in it
    /// and publishing nothing would put the two out of step for as long as the
    /// first pass takes. In the app the cache is made alongside the store and is
    /// empty, so there this line is `.empty` — its other reader is
    /// `UsagePopoverPaintTests`, which puts a landed poll on screen this way and
    /// is why `apply` did not have to stop being private.
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
    /// Each half is kept separately, because they fail separately — the quota
    /// figures can arrive while the session figures time out. Whatever did not
    /// arrive stays at its previous value and is blamed in its own half of the
    /// snapshot; the two halves that carry a stamp keep the one they arrived
    /// under rather than the stamp of the attempt — moving it along with the
    /// attempt is what made the footer call hour-old figures fresh.
    ///
    /// Three halves now, and the third does not run every pass: the histories
    /// behind the allowance are asked for once every
    /// `allowanceIntervalSeconds`, and every other pass steps over them with the
    /// previous figure untouched.
    nonisolated static func poll(client: UsageClient,
                                 previous: UsageSnapshot,
                                 now: Date = Date()) async -> UsageSnapshot {
        var result = previous

        do {
            let report = try await client.usage()
            result.fleetSevenDayMean = report.fleet?.sevenDay?.mean
            // Nothing estimates this one — the gateway measured it and this line
            // only weights the four counters and multiplies out to an hour
            // (`TokenRate.perHour`). It rides on the quota half's stamp because
            // it arrives with it, once a minute.
            result.fleetTokenRate = report.fleet?.tokens?.perHour()
            result.accounts = report.accounts
            result.quotaFetchedAt = now
            result.quotaFailure = nil
        } catch {
            result.quotaFailure = "/gw/usage: \(error)"
        }

        // The allowance's own half. It goes after the quota half and only if
        // that one answered, because it needs both things the answer carries:
        // the fleet's membership, and each account's window boundary.
        if result.quotaFailure == nil, shouldFetchAllowance(previous: previous, now: now) {
            // The attempt is stamped whatever comes of it, and that is what puts
            // a failing half back on its own cadence instead of on the
            // once-a-minute one. It used to be stamped on success alone, so a
            // history that kept failing was retried every minute: one round over
            // the live fleet is 481 KB (measured 2026-08-18, three accounts over
            // a 48 h window), which at ten minutes is 2.9 MB/h and at one minute
            // — carrying every account but the one that failed — is some
            // 19 MB/h, the very cost `allowanceIntervalSeconds` exists to avoid.
            // What the ten minutes cost is not a stale figure on screen: on a
            // failure both surfaces *remove* the figure (the popover falls back
            // to the mean, the menu bar to a colourless bar) and the footer's
            // reason line names the endpoint. The cost is the absence — one
            // transient error now buys 600 s with no allowance anywhere,
            // against the 60 s a per-pass retry would have cost. That is the
            // trade taken deliberately: the bodies are 130–187 KB against 3 KB
            // for `/gw/usage`, so this half failing alone on a slow link is the
            // ordinary case rather than the rare one, and retrying it every
            // minute is what the arithmetic above says of the tether.
            result.allowanceCheckedAt = now
            // Two requests, one window and one half. The histories say how many
            // percentage points the fleet burned; `/gw/sessions` over the *same*
            // `since` says how many tokens that cost, and their ratio is what
            // prices the allowance (`FleetCapacity.sustainable`). Asked together
            // rather than one after the other, so the half still costs one round
            // of `UsageClient.timeoutSeconds` rather than two, and awaited
            // separately so the blame can name the endpoint that failed — a half
            // that fails without saying which request is a half nobody can debug
            // (§4). The second body is cheap next to the first: 43 KB against
            // 481 KB for one round of histories (measured 2026-08-24, three
            // accounts over 48 h), so the ten-minute cadence goes from 2.9 to
            // 3.2 MB/h.
            let since = now.addingTimeInterval(-historyWindowSeconds)
            let labels = result.accounts.map(\.label)
            async let seriesAttempt = attempt { try await histories(client: client, labels: labels, since: since) }
            async let spendAttempt = attempt { try await client.sessions(since: since) }
            switch (await seriesAttempt, await spendAttempt) {
            case (.failed(let reason), _):
                result.allowanceFailure = "/gw/usage/<label>/history: \(reason)"
            case (_, .failed(let reason)):
                result.allowanceFailure = "/gw/sessions: \(reason)"
            case (.answered(let series), .answered(let spend)):
                // The window's spend, folded the one way four differently priced
                // counters may be folded (§2.7). Every session the gateway kept,
                // including the ones with no transcript on this machine: what is
                // being priced is what the fleet's points bought, and an agent
                // node's tokens cost points exactly like anyone else's.
                result.sustainable = FleetCapacity.sustainable(
                    histories: series,
                    accounts: result.accounts,
                    spentTokens: spend.sessions.reduce(0.0) { $0 + $1.tokens.weighted() })
                // The other stamp goes on the arrival, like `quotaFetchedAt` —
                // and a `nil` from `FleetCapacity.sustainable` is an arrival too.
                // It is the answer "there is no figure", which is a thing the
                // fleet can be, and holding the previous number over it would
                // state an allowance for a fleet that has stopped supporting
                // one.
                result.allowanceFetchedAt = now
                result.allowanceFailure = nil
            }
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

    /// Whether this pass fetches the histories, or leaves the previous figure
    /// alone.
    ///
    /// Asked of the *previous* snapshot's stamp and not of a stored deadline,
    /// so the schedule survives the pass being run by anything: `pollOnce`
    /// starts from `.empty`, whose stamp is `nil`, and therefore always fetches
    /// — a console tool that printed nothing because a timer had not come round
    /// yet would be printing the absence of a schedule rather than the numbers.
    ///
    /// The stamp of the *attempt*, and that is the whole difference between a
    /// schedule and an age: a failed round has to count against the next round,
    /// or a gateway answering `/gw/usage` while `/history` returns 500 is asked
    /// for 481 KB of histories every minute.
    nonisolated static func shouldFetchAllowance(previous: UsageSnapshot, now: Date) -> Bool {
        guard let last = previous.allowanceCheckedAt else { return true }
        return now.timeIntervalSince(last) >= allowanceIntervalSeconds
    }

    /// One request's answer, or why there is none — as text, because that is all
    /// anything downstream does with a failure here.
    ///
    /// It exists so the allowance half's two requests can be *started* together
    /// and *blamed* apart. `async let` hands back one value, and a thrown error
    /// arrives at a `catch` that can no longer say which of the two threw; a
    /// value that carries its own reason can. Text rather than the error itself
    /// because `any Error` is not `Sendable` and nothing needs more of it: the
    /// blame is a line in the popover's footer.
    enum Attempt<Answer: Sendable>: Sendable {
        case answered(Answer)
        case failed(String)
    }

    /// Runs one request and keeps whichever of the two it produced.
    private nonisolated static func attempt<Answer: Sendable>(
        _ work: @Sendable () async throws -> Answer) async -> Attempt<Answer> {
        do { return .answered(try await work()) } catch { return .failed("\(error)") }
    }

    /// One history per account, in parallel, keyed by the label that was
    /// *asked for* rather than the one the body echoes back — the same rule
    /// `UsageHistoryModel.load` follows, and `FleetCapacity.sustainable` looks
    /// the series up under the account's label.
    ///
    /// Raw points, deliberately: `UsageHistoryModel.load` is the other loader
    /// and it hands out `withoutSourceLag(answer.points)` because the chart wants
    /// the sawtooth gone. Smoothed input is wrong here — a lone reading below the
    /// ceiling among ceiling readings is exactly the shape that filter deletes,
    /// and it is the only thing keeping an otherwise pinned account inside the
    /// measurement. Smooth it away and the account is refused, taking its 100 pp
    /// of capacity out of the denominator along with its spending
    /// (`FleetCapacity.measure` spells the whole exposure out).
    ///
    /// In parallel, and that is what keeps `pollOnce`'s watchdog arithmetic
    /// true: sequentially the half would cost five seconds per account in the
    /// worst case and grow with the fleet, while `UsageClient.timeoutSeconds`
    /// bounds the whole group however many accounts there are.
    ///
    /// **It is a bound, but not because this is one round.** `URLSession.shared`
    /// opens at most 6 connections per host and `timeoutInterval` starts ticking
    /// when the task is *queued*, not when it reaches the wire, so the group is
    /// ⌈N / 6⌉ waves and the tail of them dies of the timeout rather than
    /// finishing late. Measured 2026-08-18 — twenty parallel GETs at a local
    /// server that answers in 2 s, each request with the client's own 5 s
    /// timeout: 6 answered at 2.03 s, 6 more at 4.04 s, and the remaining 8 all
    /// timed out at 5.03 s. At the three accounts this fleet has it is genuinely
    /// one round; past six it stops being one and the watchdog holds all the
    /// same, at the price of a half that comes back blamed.
    ///
    /// One account failing fails the half. The alternative — computing over
    /// whoever answered — is not obviously wrong, since `FleetCapacity` already
    /// counts capacity over contributors only, but it would move the published
    /// figure on a transient network fault with nothing on screen saying which
    /// fleet it was measured over. Keeping the previous figure and naming the
    /// blame is what the other two halves do.
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
        // Three rounds of five seconds — `/gw/usage`, then the allowance half,
        // then `/gw/sessions` over the week — plus the directory walk, with room
        // to spare. The allowance half is two requests and still one round: its
        // histories and its own `/gw/sessions` are started together. The
        // histories cost five seconds however many accounts there are, which is
        // why they are fetched in parallel: sequentially this number would have
        // to grow with the fleet, and a watchdog whose bound depends on what the
        // gateway happens to report is not a bound. Note what that bound is made
        // of past six accounts — the waves and the dying tail measured over
        // `histories` — because it is five seconds either way, but only one of
        // the two readings brings every history back.
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            var stalled = UsageSnapshot.empty
            // No half answered, so all three are blamed: nothing about a pass
            // that never came back is specific to one endpoint.
            stalled.quotaFailure = "the pass did not finish in 30 s"
            stalled.allowanceFailure = "the pass did not finish in 30 s"
            stalled.sessionsFailure = "the pass did not finish in 30 s"
            return stalled
        }
        return box.value
    }

    /// A finished pass, published, cached, and the latch released.
    ///
    /// Private, and the latch is the reason it has to be: a caller from outside
    /// the pass would clear `pollInFlight` under a pass still running, which is
    /// the one thing that guard exists to prevent. A test that needs a landed
    /// poll on screen seeds the cache and builds the store over it instead.
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
