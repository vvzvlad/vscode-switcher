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

    /// The window the session figures are asked for. A week, by the user's
    /// decision; whatever window the gateway applies is what it reports, and
    /// that is the one to show. It was written here that it "clamps to its own
    /// retention" — **never observed**, and re-probed 2026-09-05 20:27Z:
    /// `/gw/sessions?since=` comes back with exactly what was sent at 30 and at
    /// 90 days (§2.7).
    ///
    /// `nonisolated` is load-bearing, and there are **two** lines in the file
    /// that must not lose it: this one and `historyWindowSeconds` below, whose
    /// own doc block spells the same failure out with its own timed test. (The
    /// third, `historyIntervalSeconds`, also carries the keyword but for a
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

    /// The sliding window the per-row *rate* is counted over.
    ///
    /// **An hour, and the length is the whole mechanism rather than a taste.**
    /// The gateway's aggregates are windowed — a session's block covers the spend
    /// inside the window and nothing before it (measured; §2.9) — so the tokens it
    /// reports for the last 3600 s are already tokens per hour. Nothing divides
    /// anything. Change this number and the figure quietly stops being a rate
    /// while keeping its label: over two hours it would report twice the spend and
    /// call it an hourly rate, and there is no arithmetic anywhere downstream to
    /// notice.
    ///
    /// A second window rather than a slice of the week's, because the week's
    /// answer cannot be sliced: the gateway hands back one aggregate per session
    /// with nothing to split it by, so the only way to ask about an hour is to ask
    /// about an hour. The cost of asking is small and was measured rather than
    /// assumed — 6.7 KiB against 107.8 KiB for the week's body (2026-08-27, live
    /// gateway, 8 sessions in the hour against 115 in the week), so the pass grows
    /// by about 6%: 0.39 MB/h at the once-a-minute cadence, against the 6.3 MB/h
    /// the week's body already costs.
    ///
    /// `nonisolated`, and this is the third line in the file that must not lose
    /// the keyword — but **what guards it is both of the things that guard the
    /// other two, which is true of neither of them**, and that was measured by
    /// taking the keyword off (2026-08-27) rather than reasoned from the
    /// neighbours.
    ///
    /// The compiler objects, the way it does for `historyIntervalSeconds`: most
    /// of the reads here sit inside the `async let` autoclosures, which are
    /// `@Sendable` and nonisolated, so there is nowhere to put an implicit hop and
    /// the build stops being clean under `-strict-concurrency=complete` — five
    /// warnings, "main actor-isolated static property … cannot be accessed from
    /// outside of the actor".
    ///
    /// And the pass deadlocks anyway, the way it does for `windowSeconds`: the
    /// read in `sessionsBlame`'s argument is an ordinary one in the function body,
    /// it hops, and everything after it — both session calls and the walk over the
    /// transcript directories — runs on the main thread.
    /// `UsageTests.testPollDoesNotNeedTheMainThread` fails on its timeout at
    /// 5.117 s, and `testTheHistoriesPassDoesNotNeedTheMainThread` at 5.006 s.
    /// The timeout is what makes those failures rather than runs that never come
    /// back.
    nonisolated static let hourWindowSeconds: TimeInterval = 3600

    /// How often the accounts' histories are fetched, which is not how often the
    /// gateway is polled.
    ///
    /// **Bandwidth is the whole argument, and it used to have a second half that
    /// is now false.** "The figure they carry is an average over two days: it
    /// cannot move fast, and nothing is gained by asking ten times an hour" stood
    /// here; since 2026-09-09 the ratio is measured over a trailing
    /// `FleetCapacity.burnWindowHours` = 8 h, and a window that short does move
    /// inside ten minutes. Replaying the live series over the last 24 h
    /// (histories fetched 2026-09-09 18:55Z, load average 3.0 to 4.0), the
    /// printed integer changes **288** times at one-minute anchors against **45**
    /// at ten-minute ones, and takes 24 distinct values against 19. A faster
    /// cadence buys real freshness. What refuses to pay for it is the size of the
    /// bodies: one round over the fleet is 248 015 B — three accounts over the
    /// 48 h `historyWindowSeconds` asks for, measured 2026-09-09 17:54Z — which is
    /// 1.5 MB/h at ten minutes and 14.9 MB/h at one, on a laptop that is often on
    /// a phone's tether.
    ///
    /// So the cost of the cadence is named rather than argued away: what is on
    /// screen is up to 600 s old, and it changes across 45 of that day's 144
    /// ten-minute intervals — by 11 points at the median of the ones it changes
    /// on and 74 at the worst (same sweep). Past two
    /// intervals both surfaces take it down altogether
    /// (`UsagePopoverView.historyStaleSeconds`), which is where staleness stops
    /// being a cost and becomes an absence.
    ///
    /// `nonisolated` for the reason spelled out over `windowSeconds` — but what
    /// guards it is not the same thing, and the difference was found by taking
    /// the keyword off (2026-08-17). Neither of its two readers is `async`:
    /// `shouldFetchHistories` below is *synchronous*, and
    /// `UsagePopoverView.historyStaleSeconds` — which is two of these intervals, the
    /// age past which neither surface will show the figure — is a constant read
    /// on the main actor anyway. There is nowhere for the compiler to put a hop,
    /// so it emits none and nothing hangs; the timed test below stays green. What
    /// it emits instead is a warning under `-strict-concurrency=complete`, and a
    /// build that has to be clean under that flag is this line's guard. Give the
    /// constant an `async` reader and it inherits `windowSeconds`' failure mode
    /// along with its test.
    nonisolated static let historyIntervalSeconds: TimeInterval = 600

    /// The window the histories are asked over. A constant, and it is the only
    /// window there is.
    ///
    /// **Two days rather than the seven the session figures use**, because the
    /// account that limits the answer is already saturated at two. Measured
    /// 2026-09-05 15:35Z, three `since` values against all three accounts:
    ///
    ///     since   acc2                      acc3                      main
    ///      48 h   47.91 h, 1853 pts         47.88 h,  632 pts         43.09 h, 2000, truncated
    ///      72 h   59.89 h, 2000, truncated  71.95 h, 1519 pts         43.09 h, 2000, truncated
    ///     168 h   59.89 h, 2000, truncated  86.83 h, 2000, truncated  43.09 h, 2000, truncated
    ///
    /// main answers 43.09 h whether it is asked for two days, three or a week, so
    /// depth past 48 h cannot reach the account the fleet answer is limited by
    /// (`FleetBurn.measuredHours` is the shortest span). What it does buy is a
    /// wider spread between contributors — 43.1 / 59.9 / 86.8 h at a week against
    /// 43.1 / 47.9 / 47.9 h at 48 — and the accounts are averaged unweighted, so a
    /// wider spread means they answer about different stretches of time.
    ///
    /// **The mechanism is `max_points`, not retention, and this comment used to
    /// say the opposite.** "48 h is the deepest window the gateway will serve"
    /// was read off 2026-08-17, when `since` of 7 and 30 days came back identical
    /// with spans stopping at 51.75 / 52.43 / 65.85 h. Asked for a week today,
    /// acc3 comes back with 86.8 h and is still stopped by the 2000-point cap —
    /// retention binds nobody. What binds is how hard the gateway polls each
    /// account: at `since = 48 h` that is 46.4, 38.7 and 13.2 readings an hour
    /// over main, acc2 and acc3, and the cap counts points rather than hours. The
    /// ordering flipped with it — main was the deepest of the three in August and
    /// is the shallowest now — so the rule is the mechanism and never the
    /// ordering.
    ///
    /// **The argument for 48 was the ratio's, and since 2026-09-09 the ratio does
    /// not use it. Nothing has replaced it, and this says so rather than
    /// inventing one.**
    ///
    /// It used to be the ±1 pp sawtooth (§4) divided by the span: the figure was
    /// measured over whatever each series held, so this constant set its depth,
    /// and one endpoint landing on a tooth moved the answer by ±7.01 pp at a 12 h
    /// window against ±1.65 at 48 (measured 2026-09-05 02:50Z, adding and
    /// subtracting a point from each account's last reading in turn). The figure
    /// is now measured over a trailing `FleetCapacity.burnWindowHours` = 8 h, so
    /// that cost is set there and the table that prices it lives there.
    ///
    /// **What is left is a fetch four times deeper than its only reader**, and the
    /// tempting justification — "the popover's chart draws the other 40 hours" —
    /// is false: the chart asks for `HistoryPeriod.seconds`, one of 1 h, 6 h, 24 h,
    /// a week or a month, defaulting to the day, and 48 h is a window it never
    /// asks for at all (`UsageHistoryModel.applyRotation`, whose docblock carries
    /// that probe: the day pass is 212713 bytes over status and three histories,
    /// the hour pass 12346, and the 48 h column is named there as another
    /// consumer's window). This series has exactly one reader, `FleetCapacity.burnAgainstRefill`
    /// through `histories` below, and it now discards everything older than eight
    /// hours.
    ///
    /// So the honest state of this constant is: **oversized, deliberately left
    /// alone this round, and worth about 1.1 MB/h of the 1.5 it costs.** One round
    /// over the live fleet, measured 2026-09-09 17:54Z at load average 3.40, the
    /// same three accounts at three depths:
    ///
    ///     since   acc2      acc3       main      total     at one round / 10 min
    ///       8 h   21666       131 B    22667      44464 B   0.27 MB/h
    ///      12 h   32972       131 B    26843      59946 B   0.36 MB/h
    ///      48 h   94769    126142      27104     248015 B   1.49 MB/h
    ///
    /// (acc3 sends 131 bytes at the two short depths because it is the
    /// switched-off account and its series stopped 12 h before the probe — which
    /// is also why the 48 h column is not simply six times the 8 h one. The
    /// figures move with how much history the fleet holds: the same round was
    /// 481 KB on 2026-08-18, and that reading is not in conflict with this one.)
    ///
    /// A shorter fetch still needs its own measurement — how much slack a window
    /// anchored at the same `now` as its trim actually requires, and whether the
    /// gateway's clamping of `since` eats any of it — which is a change to make on
    /// purpose rather than as a side effect of this one. The test on this constant
    /// asserts the value and this reasoning, so moving it is a deliberate act with
    /// a place to read first.
    ///
    /// Deeper than 48 h is in any case not on offer: the accounts are capped at
    /// `max_points` = 2000, so a week's request comes back truncated on all three
    /// and covers 105.8 / 53.2 / 97.4 h (2026-09-09) — the *cap* against the
    /// polling rate, never retention, which binds nobody.
    ///
    /// **And a constant rather than a setting, which it was until the demand
    /// estimators went.** `usageLoadWindowHours` chose between two ways of
    /// estimating a week's demand and, by the same number, how deep to ask; the
    /// estimators are gone and so is the choice.
    ///
    /// `nonisolated`, and here it is load-bearing in the original way: `poll` is
    /// `async` and reads this one directly, so without the keyword the compiler
    /// inserts a hop and the histories, the sessions call and the transcript
    /// walk all run on the main thread. Taken off, the pass deadlocks against
    /// the very thread `pollOnce` blocks on and
    /// `UsageTests.testTheHistoriesPassDoesNotNeedTheMainThread` times out at
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
    /// Three halves now, and the third does not run every pass: the accounts'
    /// histories are asked for once every `historyIntervalSeconds`, and every
    /// other pass steps over them with the previous figure untouched.
    ///
    /// `projectsDirectory` is a test seam and nothing else — the same defaulted
    /// argument `UsageIndex.slugsBySessionId` and `ClaudeSessions.sessionTimes`
    /// already carry, and for the same reason: the fold onto slugs is only
    /// exercisable against a transcript tree that can be built, and the union the
    /// two reports resolve through is a rule that would otherwise be held by
    /// nothing.
    nonisolated static func poll(client: UsageClient,
                                 previous: UsageSnapshot,
                                 now: Date = Date(),
                                 projectsDirectory: URL = ClaudeSessions.projectsDirectory)
        async -> UsageSnapshot {
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

        // The histories' own half. It goes after the quota half and only if that
        // one answered, because it needs both things the answer carries: the
        // fleet's membership, and each account's window boundary.
        if result.quotaFailure == nil, shouldFetchHistories(previous: previous, now: now) {
            // The attempt is stamped whatever comes of it, and that is what puts
            // a failing half back on its own cadence instead of on the
            // once-a-minute one. It used to be stamped on success alone, so a
            // history that kept failing was retried every minute: one round over
            // the live fleet is 481 KB (measured 2026-08-18, three accounts over
            // a 48 h window), which at ten minutes is 2.9 MB/h and at one minute
            // — carrying every account but the one that failed — is some
            // 19 MB/h, the very cost `historyIntervalSeconds` exists to avoid.
            // What the ten minutes cost is not a stale figure on screen: on a
            // failure both surfaces *remove* the figure (the popover falls back
            // to the mean, the menu bar to a colourless bar) and the footer's
            // reason line names the endpoint. The cost is the absence — one
            // transient error now buys 600 s with no figure anywhere,
            // against the 60 s a per-pass retry would have cost. That is the
            // trade taken deliberately: the bodies are 130–187 KB against 3 KB
            // for `/gw/usage`, so this half failing alone on a slow link is the
            // ordinary case rather than the rare one, and retrying it every
            // minute is what the arithmetic above says of the tether.
            result.historiesCheckedAt = now
            // **One request, and it used to be two.** A second call to
            // `/gw/sessions` over the same `since` stood beside the histories,
            // and it was there to price a percentage point in tokens for the
            // allowance. Both sides of the figure are now percentage points of a
            // week (`FleetCapacity.burnAgainstRefill`), so there is nothing left
            // to convert and nothing left to ask: the half is a `do`/`catch`
            // again, and the blame names the one endpoint it can name. The 43 KB
            // that second body cost comes off the ten-minute cadence, taking it
            // from 3.2 back to 2.9 MB/h (bodies measured 2026-08-24, three
            // accounts over 48 h).
            // Who is out of the rotation, asked on the histories' cadence and not
            // on the minute: 6.4 KB against the 130–187 KB of the histories beside
            // it (measured 2026-09-09), so it is 4% on a half that already exists
            // rather than the 370 KB an hour it would cost on the minute poll.
            //
            // **It fails open, which is the opposite of what the rest of this half
            // does, and what bounds the error is the clock rather than its
            // direction.** "An absent account keeps a refill share it cannot burn
            // against, so the figure reads calmer than the truth" stood here and is
            // withdrawn: it assumes the account contributes a refill share and no
            // burn, and an account contributing no burn is one whose frozen series
            // reads flat, which is only sometimes what a frozen series does. What
            // it carries for the two hours it is still inside the window is the
            // rate it was burning at when the gateway stopped polling it, so
            // leaving it in moves the unweighted mean towards that rate — up or
            // down according to where it sat against its neighbours', which nothing
            // here knows. Which is exactly what `FleetBurn.isLowerBound` says of
            // the same exclusion one file over; this used to say the opposite.
            //
            // Measured over the live fleet, histories fetched 2026-09-09 18:55Z at
            // load average 3.0 to 4.0, replaying the whole two hours the flag is
            // worth — 25 anchors five minutes apart from acc3's last reading at
            // 05:38:28Z to its fall through the coverage floor at 07:38:28Z, acc2
            // the only other contributor because main was inside a 52.37 h hole:
            //
            //     12 anchors louder   worst +21.7 pp   21.1% -> 42.7%
            //     12 anchors calmer   worst -29.0 pp   84.3% -> 55.3%
            //      1 anchor  equal    the floor has just taken acc3 anyway
            //
            // So the price is up to about 30 points, in whichever direction the day
            // picks, and "a couple of points" it is not. What makes it tolerable is
            // that it cannot last: answering costs anything at all only when a
            // switch-off happened inside the last
            // `FleetCapacity.burnWindowHours - minimumMeasuredHours` = 2 h, after
            // which the frozen series ages out of the measurement window on its
            // own. Refusing, against that, costs the headline on every blip of a
            // 6 KB endpoint, for as long as the blip lasts. A bounded, self-healing
            // error beats a blank number here. The bound holds only as long as the
            // gateway stops polling a switched-off account, which is what it did on
            // 2026-09-09; if it ever keeps polling one, the error lasts as long as
            // the outage, and the blame line below is how that becomes visible.
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
                // The other stamp goes on the arrival, like `quotaFetchedAt` —
                // and a `nil` from `burnAgainstRefill` is an arrival too. It is
                // the answer "there is no figure", which is a thing the fleet can
                // be, and holding the previous number over it would state a rate
                // for a fleet that has stopped supporting one.
                result.historiesFetchedAt = now
                result.historiesFailure = nil
            } catch {
                result.historiesFailure = "/gw/usage/<label>/history: \(error)"
            }
        }

        // The sessions half, which is now two questions to one endpoint: the week
        // a row's total spend is counted over, and the sliding hour beside it that
        // makes the same question's answer a rate.
        //
        // Started together rather than one after the other, so the half costs one
        // round of `UsageClient.timeoutSeconds` instead of two. Awaited
        // separately so each can be blamed on its own — both go to
        // `/gw/sessions`, so the path alone does not say which failed, and the
        // blame names the window (§4). It is the last pair of this shape in the
        // file: the histories half had one until the figure stopped needing a
        // price in tokens.
        async let weekAttempt = attempt {
            try await client.sessions(since: now.addingTimeInterval(-windowSeconds))
        }
        async let hourAttempt = attempt {
            try await client.sessions(since: now.addingTimeInterval(-hourWindowSeconds))
        }
        let week = await weekAttempt
        let hour = await hourAttempt

        // **One resolution for both reports.** `slugsBySessionId` walks every slug
        // directory under `~/.claude/projects` and is the expensive part of this
        // pass (§6); resolving each report on its own would walk the same
        // directories twice a minute for an answer the first walk already holds.
        // The union rather than the week's identifiers alone, and that is not
        // belt-and-braces: the week's list is capped at the gateway's 200 largest
        // consumers, so a session that spent little over the week but is running
        // right now can be in the hour's report and absent from the week's. Folding
        // the hour against a map built from the week's ids would file exactly that
        // session — the live one — as spend with no owner.
        var identifiers = Set<String>()
        if case .answered(let report) = week { identifiers.formUnion(report.sessions.map(\.sessionId)) }
        if case .answered(let report) = hour { identifiers.formUnion(report.sessions.map(\.sessionId)) }
        let slugsBySessionId = UsageIndex.slugsBySessionId(for: identifiers,
                                                          projectsDirectory: projectsDirectory)

        // Each report updates its own figures, and one failing does not discard
        // the other's: they are two independent answers to the same question over
        // two windows, and a week's spend thrown away because the hour timed out
        // would be a figure deleted for no reason.
        var blame: [String] = []
        switch week {
        case .answered(let report):
            let folded = UsageIndex.fold(sessions: report.sessions,
                                         slugsBySessionId: slugsBySessionId)
            result.since = report.since
            result.truncated = report.truncated
            result.tokensBySlug = folded.tokensBySlug
            // Narrowed against this window and no other. The rule is one function
            // called twice, exactly as `fold` above it is — what differs is the
            // window, which is the whole point: a life last written three days ago
            // is inside the week and outside the hour.
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
            // function: the contested and unmatched policies are `fold`'s, and a
            // second policy for the same question would be two answers to "whose
            // spend is this" living in one snapshot.
            let folded = UsageIndex.fold(sessions: report.sessions,
                                         slugsBySessionId: slugsBySessionId)
            result.hourlyTokensBySlug = folded.tokensBySlug
            result.hourlyContested = UsageIndex.narrowToWindow(
                folded.contested,
                since: now.addingTimeInterval(-hourWindowSeconds),
                projectsDirectory: projectsDirectory)
            // And the hour's ownerless spend, which used to be dropped right here.
            // The week kept it and `--dump` printed it; the hour had no counterpart
            // anywhere, so a session with no local transcript vanished from the
            // hour with no line to notice it by. It is not a hypothetical bucket:
            // `--dump` on this machine printed 1 session and 179k ie in it on
            // 2026-08-27 and 0 the next night, which is the point — it fills and
            // empties with the sliding hour, and this branch was throwing away
            // whatever happened to be in it.
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
    nonisolated static func shouldFetchHistories(previous: UsageSnapshot, now: Date) -> Bool {
        guard let last = previous.historiesCheckedAt else { return true }
        return now.timeIntervalSince(last) >= historyIntervalSeconds
    }

    /// One request's answer, or why there is none — as text, because that is all
    /// anything downstream does with a failure here.
    ///
    /// It exists so the sessions half's two requests can be *started* together
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

    /// The blame one of the two session calls leaves, naming the window it asked
    /// for as well as the path.
    ///
    /// Both calls go to `/gw/sessions`, so the path alone names neither — and a
    /// half that fails without saying which request is a half nobody can debug
    /// (§4). The window is rendered from the constant rather than written out, so
    /// moving either constant moves its own label instead of leaving a blame that
    /// names a window nothing asks for.
    /// Named `window` rather than `windowSeconds` on purpose: the latter would
    /// shadow the week's constant inside this body, so a line added here later and
    /// meaning the constant would silently get the argument instead.
    private nonisolated static func sessionsBlame(window: TimeInterval,
                                                  reason: String) -> String {
        "/gw/sessions?since=-\(Int(window / 3600))h: \(reason)"
    }

    /// One history per account, in parallel, keyed by the label that was
    /// *asked for* rather than the one the body echoes back — the same rule
    /// `UsageHistoryModel.load` follows, and `FleetCapacity.burnAgainstRefill`
    /// looks the series up under the account's label.
    ///
    /// Raw points, deliberately: `UsageHistoryModel.load` is the other loader
    /// and it hands out `withoutSourceLag(answer.points)` because the chart wants
    /// the sawtooth gone. Smoothed input is wrong here — a lone reading below the
    /// ceiling among ceiling readings is exactly the shape that filter deletes,
    /// and it is the only thing keeping an otherwise pinned account inside the
    /// measurement. Smooth it away and the account is refused, taking its share
    /// of the refill out of the denominator along with its burn
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
    /// counts the refill over contributors only, but it would move the published
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
        // Three rounds of five seconds — `/gw/usage`, then the histories half,
        // then `/gw/sessions` over the week and the hour — plus the directory
        // walk, with room to spare. The histories cost five seconds however many
        // accounts there are, which is why they are fetched in parallel:
        // sequentially this number would have to grow with the fleet, and a
        // watchdog whose bound depends on what the gateway happens to report is
        // not a bound. Note what that bound is made of past six accounts — the
        // waves and the dying tail measured over `histories` — because it is five
        // seconds either way, but only one of the two readings brings every
        // history back.
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
