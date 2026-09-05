import XCTest
@testable import VSCodeSwitcher

/// Bodies copied verbatim out of live answers from the gateway on 2026-08-16.
/// Nothing here is tidied up: the point of a fixture is to be the thing that
/// actually arrives, keys nobody decodes and all.
enum UsageFixtures {
    static let sessions = """
    {
      "since": 1786761516, "now": 1786847916, "units": "tokens",
      "max_sessions": 200, "truncated": false,
      "sessions": [
        {
          "session_id": "121d7f47-540d-4e13-a603-25eaad87bd79",
          "bound_to": "acc2", "responses": 25, "incomplete": 0,
          "first_ts": 1786847534, "last_ts": 1786847911,
          "input_tokens": 50, "output_tokens": 24264,
          "cache_read_input_tokens": 5401028, "cache_creation_input_tokens": 41120,
          "measured_input_tokens": 25, "measured_output_tokens": 25,
          "measured_cache_read_input_tokens": 25, "measured_cache_creation_input_tokens": 25,
          "by_account": { "acc2": { "...": 0 } }
        }
      ]
    }
    """

    static let usage = """
    {"fleet": {"accounts": 3, "eligible": 2,
      "five_hour": {"mean": 21.0, "min": 14.0, "max": 28.0, "best_label": "acc3", "accounts": 2, "no_data": 0, "blocked_elsewhere": 1},
      "seven_day": {"mean": 58.667, "min": 5.0, "max": 99.0, "best_label": "acc2", "accounts": 3, "no_data": 0}},
     "accounts": {"acc2": {"five_hour": {"utilization": 28.0, "resets_at": "2026-08-16T03:00:00Z", "known": true},
                           "seven_day": {"utilization": 5.0, "resets_at": "2026-08-22T21:00:00Z", "known": true}, "...": {}}}}
    """

    /// The same report with a second account in it, for the one question a
    /// one-account fleet cannot ask: what it costs when an account is refused and
    /// leaves with its 100 pp of capacity.
    static let usageTwoAccounts = """
    {"fleet": {"accounts": 2, "eligible": 2,
      "seven_day": {"mean": 58.667, "min": 5.0, "max": 99.0, "best_label": "acc2", "accounts": 2, "no_data": 0}},
     "accounts": {"acc2": {"seven_day": {"utilization": 5.0, "known": true}},
                  "acc3": {"seven_day": {"utilization": 40.0, "known": true}}}}
    """

    /// The same endpoint on 2026-08-24, when it had grown the `tokens` block the
    /// headline's lead figure is read from. Copied verbatim, one account and the
    /// fleet, so the two can be checked against each other: the fleet's four
    /// rates are the sum of the accounts'.
    static let usageWithTokens = """
    {"fleet": {"accounts": 3, "eligible": 2,
      "tokens": {"window_seconds": 300,
                 "per_second": {"input_tokens": 218.53, "output_tokens": 174.427,
                                "cache_read_input_tokens": 55836.677,
                                "cache_creation_input_tokens": 1091.747},
                 "responses": 69, "incomplete": 0, "sessions": 6},
      "seven_day": {"mean": 50.0, "min": 10.0, "max": 99.0, "best_label": "main", "accounts": 3, "no_data": 0}},
     "accounts": {"acc2": {"five_hour": {"utilization": 25.0, "resets_at": "2026-08-24T00:50:00Z", "known": true},
                           "seven_day": {"utilization": 41.0, "resets_at": "2026-08-29T21:00:00Z", "known": true},
                           "tokens": {"window_seconds": 300,
                                      "per_second": {"input_tokens": 120.483, "output_tokens": 62.253,
                                                     "cache_read_input_tokens": 18936.567,
                                                     "cache_creation_input_tokens": 468.033},
                                      "responses": 21, "incomplete": 0, "sessions": 2},
                           "eligible": true, "unified_status": "allowed"}}}
    """

    static let history = """
    {"label": "main", "since": 1786700000, "now": 1786786400, "units": "percent",
     "max_points": 2000, "truncated": false,
     "points": [{"ts": 1786700123, "util_5h": 26.0, "util_7d": 99.0, "status": "allowed", "source": "poll"}]}
    """

    /// The same shapes with the holes that mean "the upstream did not say".
    static let sessionsWithNulls = """
    {"since": 1786761516, "truncated": true,
     "sessions": [{"session_id": "s-partial", "input_tokens": 50, "output_tokens": null,
                   "cache_read_input_tokens": 5401028}]}
    """

    static let usageWithoutReadings = """
    {"fleet": {"accounts": 3, "seven_day": {"mean": 58.667, "accounts": 0}},
     "accounts": {"acc9": {"five_hour": {"utilization": 0.0, "known": false},
                           "seven_day": {"utilization": null, "known": true}}}}
    """

    static let historyWithNulls = """
    {"label": "main", "since": 1786700000, "truncated": false,
     "points": [{"ts": 1786700123, "util_5h": null, "util_7d": 99.0}]}
    """

    static func decode<Body: Decodable>(_ text: String, as type: Body.Type) throws -> Body {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

/// Decoding the gateway's real bodies.
final class UsageDecodingTests: XCTestCase {

    func testSessionsBodyDecodesTheFourCountersAndTheAppliedWindow() throws {
        let report = try UsageFixtures.decode(UsageFixtures.sessions, as: SessionsReport.self)
        XCTAssertEqual(report.since, Date(timeIntervalSince1970: 1_786_761_516))
        XCTAssertFalse(report.truncated)
        XCTAssertEqual(report.sessions.count, 1)

        let session = try XCTUnwrap(report.sessions.first)
        XCTAssertEqual(session.sessionId, "121d7f47-540d-4e13-a603-25eaad87bd79")
        XCTAssertEqual(session.tokens.input, 50)
        XCTAssertEqual(session.tokens.output, 24264)
        XCTAssertEqual(session.tokens.cacheCreation, 41120)
        XCTAssertEqual(session.tokens.cacheRead, 5_401_028)
        XCTAssertTrue(session.tokens.isComplete)
    }

    /// The `since` that comes back is the one the gateway *applied*, which is
    /// the number to show — never the one that was asked for. "After clamping to
    /// its retention" stood here and is withdrawn: no clamping has ever been
    /// observed on any endpoint (re-probed 2026-09-05 20:27Z, §2.7). The rule
    /// holds anyway, and on the better reason — the answer is the authority on
    /// what it covers.
    func testTheAppliedWindowIsTheOneReported() throws {
        let report = try UsageFixtures.decode(UsageFixtures.sessionsWithNulls, as: SessionsReport.self)
        XCTAssertEqual(report.since, Date(timeIntervalSince1970: 1_786_761_516))
        XCTAssertTrue(report.truncated, "the cheapest sessions were dropped and the flag has to reach the model")
    }

    func testAMissingOrNullCounterIsNotZero() throws {
        let report = try UsageFixtures.decode(UsageFixtures.sessionsWithNulls, as: SessionsReport.self)
        let tokens = try XCTUnwrap(report.sessions.first).tokens
        XCTAssertEqual(tokens.input, 50)
        XCTAssertNil(tokens.output, "null means the upstream did not name it")
        XCTAssertNil(tokens.cacheCreation, "a missing key means the same")
        XCTAssertEqual(tokens.cacheRead, 5_401_028)
        XCTAssertFalse(tokens.isComplete)
    }

    func testUsageBodyDecodesTheFleetMeanAndTheAccounts() throws {
        let report = try UsageFixtures.decode(UsageFixtures.usage, as: UsageReport.self)
        XCTAssertEqual(report.fleet?.sevenDay?.mean, 58.667)
        XCTAssertEqual(report.accounts.map(\.label), ["acc2"])

        let account = try XCTUnwrap(report.accounts.first)
        XCTAssertEqual(account.fiveHour?.utilization, 28.0, "per cent, 0…100 — never a fraction")
        XCTAssertEqual(account.sevenDay?.utilization, 5.0)
        XCTAssertEqual(account.fiveHour?.resetsAt, try Date("2026-08-16T03:00:00Z", strategy: .iso8601))
        XCTAssertEqual(account.sevenDay?.resetsAt, try Date("2026-08-22T21:00:00Z", strategy: .iso8601))
    }

    /// `known: false` is "no reading", not "the quota is untouched". A
    /// confidently wrong percentage is worse than a missing one.
    func testAnUnknownWindowIsNilAndNotZero() throws {
        let report = try UsageFixtures.decode(UsageFixtures.usageWithoutReadings, as: UsageReport.self)
        let account = try XCTUnwrap(report.accounts.first)
        XCTAssertNil(account.fiveHour?.utilization, "known: false, even with a 0.0 next to it")
        XCTAssertNil(account.sevenDay?.utilization, "known: true with a null reading is still no reading")
    }

    /// The mean of no accounts is not zero either — and the averaging is the
    /// server's, never ours.
    func testAFleetMeanOverNoAccountsIsNil() throws {
        let report = try UsageFixtures.decode(UsageFixtures.usageWithoutReadings, as: UsageReport.self)
        XCTAssertNil(report.fleet?.sevenDay?.mean)
    }

    // MARK: - The live token rate

    /// The block the headline's lead figure is read straight out of, weighted
    /// the one way four differently priced counters may be weighted.
    ///
    /// `218.53 + 5 x 174.427 + 1.25 x 1091.747 + 0.1 x 55836.677 = 8039.0164`
    /// input-equivalent tokens a second, which is 28,940,459 an hour. Every
    /// number is the live body of 2026-08-24 and the arithmetic is redoable on
    /// paper.
    func testTheFleetsTokenRateIsWeightedAndCarriedToTheHour() throws {
        let report = try UsageFixtures.decode(UsageFixtures.usageWithTokens, as: UsageReport.self)
        let tokens = try XCTUnwrap(report.fleet?.tokens)
        XCTAssertEqual(tokens.windowSeconds, 300, "the body's own window, never a constant of ours")
        XCTAssertEqual(try XCTUnwrap(tokens.perHour()), 28_940_459.22, accuracy: 0.01, """
            output is billed at five times input and a cache read at a tenth, so the raw sum of \
            the four is a number that appears on no invoice (§2.7)
            """)
    }

    /// An older gateway has no `tokens` block at all, and that must cost the
    /// quota figures beside it nothing: the popover falls back to the weekly
    /// mean, which is exactly what it drew before this figure existed.
    func testAGatewayWithNoTokenBlockStillReportsItsQuota() throws {
        let report = try UsageFixtures.decode(UsageFixtures.usage, as: UsageReport.self)
        XCTAssertNil(report.fleet?.tokens, "the 2026-08-16 body, which had no such block")
        XCTAssertEqual(report.fleet?.sevenDay?.mean, 58.667, "and the half that was there still arrives")
    }

    /// Every way the block can be there and still not carry a rate. Each answers
    /// `nil`, and `nil` is what moves the headline back to the quota rather than
    /// what puts a wrong number on it.
    ///
    /// **"Every" was a promise this made and did not keep**, and the two forms it
    /// did not ask were the two that the arithmetic refuses rather than the
    /// decoder: a counter that is negative, and a counter so large that the
    /// figure overflows on its way to an hour. Both decode without complaint —
    /// they are ordinary JSON numbers — and removing the guard they land on
    /// killed 0 of 531 tests until they were added (2026-08-24). They also ask
    /// the guard from its two sides: the negative one is refused before the
    /// multiplication and the huge one only after it.
    func testEveryUnusableTokenBlockIsNoRateRatherThanZero() throws {
        func rate(_ body: String) throws -> TokenRate? {
            try UsageFixtures.decode("{\"fleet\": {\(body)}}", as: UsageReport.self).fleet?.tokens
        }
        let full = """
        "per_second": {"input_tokens": 1.0, "output_tokens": 2.0, \
        "cache_read_input_tokens": 3.0, "cache_creation_input_tokens": 4.0}
        """

        XCTAssertNil(try rate("\"tokens\": null"), "statistics off: a null block is not a rate of zero")
        XCTAssertNil(try rate("\"tokens\": {\"window_seconds\": 0, \(full)}")?.perHour(), """
            the gateway divided by this window, so a window of zero means whatever came back is \
            not a rate at all
            """)
        XCTAssertNil(try rate("\"tokens\": {\(full)}")?.perHour(),
                     "a block that names no window cannot say what its rates are an average of")
        XCTAssertNil(try rate("\"tokens\": {\"window_seconds\": 300}")?.perHour(),
                     "a window with no rates under it")
        XCTAssertNil(try rate("""
            "tokens": {"window_seconds": 300, "per_second": {"input_tokens": 1.0, \
            "cache_read_input_tokens": 3.0, "cache_creation_input_tokens": 4.0}}
            """)?.perHour(), """
            all four counters or none: output is five times input, so a rate missing it understates \
            by most of itself — and this figure has no `≥` to say so with (§2.7)
            """)
        XCTAssertNil(try rate("""
            "tokens": {"window_seconds": 300, "per_second": {"input_tokens": -1.0, \
            "output_tokens": 0.0, "cache_read_input_tokens": 0.0, \
            "cache_creation_input_tokens": 0.0}}
            """)?.perHour(), """
            a counter below zero decodes as happily as any other number, and a negative rate is \
            not a slower one — it is a body this app cannot state. The other three are zero on \
            purpose: what is refused is the weighted rate rather than the counter, and beside \
            the fixture above's own 2.0 / 3.0 / 4.0 a -1.0 input still totals +14.3 a second
            """)
        XCTAssertNil(try rate("""
            "tokens": {"window_seconds": 300, "per_second": {"input_tokens": 1e306, \
            "output_tokens": 0.0, "cache_read_input_tokens": 0.0, \
            "cache_creation_input_tokens": 0.0}}
            """)?.perHour(), """
            1e306 a second is a finite rate and 3600 times it is not: the check has to stand on \
            the figure that leaves, or the headline reads `infB/h` and the ramp is pinned red
            """)
    }

    /// Zero is the one reading here that is not an absence. A fleet with nothing
    /// running spends nothing, and printing `0/h` beside the lead is the true
    /// picture of that; answering `nil` instead would drop the supporting reading
    /// off the popover exactly when the news is good.
    func testAFleetSpendingNothingReadsZeroRatherThanNothing() throws {
        let idle = """
        {"fleet": {"tokens": {"window_seconds": 300, "per_second": {"input_tokens": 0.0, \
        "output_tokens": 0.0, "cache_read_input_tokens": 0.0, "cache_creation_input_tokens": 0.0}}}}
        """
        let tokens = try XCTUnwrap(try UsageFixtures.decode(idle, as: UsageReport.self).fleet?.tokens)
        XCTAssertEqual(tokens.perHour(), 0, "a reading of nothing spent, not the absence of a reading")
    }

    func testHistoryBodyDecodes() throws {
        let series = try UsageFixtures.decode(UsageFixtures.history, as: HistorySeries.self)
        XCTAssertEqual(series.label, "main")
        XCTAssertEqual(series.since, Date(timeIntervalSince1970: 1_786_700_000))
        XCTAssertFalse(series.truncated)

        let point = try XCTUnwrap(series.points.first)
        XCTAssertEqual(point.timestamp, Date(timeIntervalSince1970: 1_786_700_123))
        XCTAssertEqual(point.fiveHour, 26.0)
        XCTAssertEqual(point.sevenDay, 99.0)
    }

    func testANullSampleIsNotAReadingOfZero() throws {
        let series = try UsageFixtures.decode(UsageFixtures.historyWithNulls, as: HistorySeries.self)
        let point = try XCTUnwrap(series.points.first)
        XCTAssertNil(point.fiveHour)
        XCTAssertEqual(point.sevenDay, 99.0)
    }

    /// Every type spells its keys out. `.convertFromSnakeCase` maps `five_hour`
    /// to `fiveHour` but `util_5h` to `util5h`, so one of the two would go
    /// missing without a word — this holds that the explicit keys still match
    /// the wire format on both.
    func testTheKeysAreTheWireKeys() throws {
        let usage = try UsageFixtures.decode(UsageFixtures.usage, as: UsageReport.self)
        XCTAssertNotNil(usage.accounts.first?.fiveHour, "five_hour")
        let history = try UsageFixtures.decode(UsageFixtures.history, as: HistorySeries.self)
        XCTAssertNotNil(history.points.first?.fiveHour, "util_5h")
    }
}

/// The arithmetic of four differently-priced counters.
final class TokenArithmeticTests: XCTestCase {

    /// Hand-computed from the fixture: 50·1 + 24264·5 + 41120·1.25 + 5401028·0.1
    /// = 50 + 121320 + 51400 + 540102.8.
    func testWeightingOnTheLiveFixture() throws {
        let report = try UsageFixtures.decode(UsageFixtures.sessions, as: SessionsReport.self)
        let tokens = try XCTUnwrap(report.sessions.first).tokens
        XCTAssertEqual(tokens.weighted(), 712_872.8, accuracy: 0.001)
    }

    func testTheWeightsAreThePublishedRatios() {
        let weights = TokenWeights.inputEquivalent
        XCTAssertEqual(weights.input, 1)
        XCTAssertEqual(weights.output, 5, "output is 5x input on Opus, Sonnet and Haiku alike")
        XCTAssertEqual(weights.cacheCreation, 1.25, "the 5-minute TTL write")
        XCTAssertEqual(weights.cacheRead, 0.1)
    }

    /// A counter nobody named is counted as zero, which makes the total a lower
    /// bound — and `isComplete` is the flag that says so.
    func testAnUnnamedCounterCountsAsZeroAndIsAdmitted() {
        let partial = TokenCounts(input: 100, output: nil, cacheCreation: nil, cacheRead: nil)
        XCTAssertEqual(partial.weighted(), 100)
        XCTAssertFalse(partial.isComplete)
    }

    /// The invariant the whole representation exists for: `nil + 5` is 5 as a
    /// lower bound, and that 5 must not pass for a complete answer merely by no
    /// longer being nil.
    func testASumWithAnUnknownSummandDoesNotPretendToBeComplete() {
        let known = TokenCounts(input: 5, output: 5, cacheCreation: 5, cacheRead: 5)
        let unknown = TokenCounts(input: nil, output: 1, cacheCreation: 1, cacheRead: 1)

        let total = known + unknown
        XCTAssertEqual(total.input, 5, "nil + 5 is 5")
        XCTAssertEqual(total.output, 6)
        XCTAssertTrue(known.isComplete)
        XCTAssertFalse(unknown.isComplete)
        XCTAssertFalse(total.isComplete, "one unnamed counter poisons the whole sum")
        XCTAssertFalse((unknown + known).isComplete, "and the order does not matter")
    }

    func testAddingTwoUnknownsKeepsThemUnknown() {
        let left = TokenCounts(input: nil, output: 1, cacheCreation: 1, cacheRead: 1)
        let right = TokenCounts(input: nil, output: 1, cacheCreation: 1, cacheRead: 1)
        XCTAssertNil((left + right).input, "nothing was named, so there is nothing to report")
    }

    /// `.zero` is the seed of every sum, so it has to change neither the numbers
    /// nor their completeness.
    func testZeroIsTheIdentity() {
        let value = TokenCounts(input: 1, output: 2, cacheCreation: 3, cacheRead: 4)
        XCTAssertEqual(TokenCounts.zero + value, value)
        XCTAssertEqual(value + TokenCounts.zero, value)

        let partial = TokenCounts(input: nil, output: 2, cacheCreation: 3, cacheRead: 4)
        XCTAssertEqual(TokenCounts.zero + partial, partial)
        XCTAssertFalse((TokenCounts.zero + partial).isComplete)
        XCTAssertEqual(TokenCounts.zero.weighted(), 0)
    }
}

/// The client: one endpoint per method, and every failure typed rather than
/// fatal.
final class UsageClientTests: XCTestCase {

    /// Remembers the request a stub transport was handed.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URL?
        var url: URL? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func record(_ url: URL?) {
            lock.lock()
            stored = url
            lock.unlock()
        }
    }

    private func makeClient(body: String,
                            status: Int = 200,
                            log: RequestLog? = nil,
                            failure: (any Error)? = nil) -> UsageClient {
        UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            log?.record(request.url)
            if let failure { throw failure }
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            guard let response = HTTPURLResponse(url: url,
                                                 statusCode: status,
                                                 httpVersion: nil,
                                                 headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(body.utf8), response)
        }
    }

    func testSessionsAsksForTheAppliedWindowAndParsesTheBody() async throws {
        let log = RequestLog()
        let client = makeClient(body: UsageFixtures.sessions, log: log)
        let report = try await client.sessions(since: Date(timeIntervalSince1970: 1_786_000_000))

        XCTAssertEqual(log.url?.path, "/gw/sessions")
        XCTAssertEqual(log.url?.query, "since=1786000000")
        XCTAssertEqual(report.sessions.count, 1)
    }

    func testUsageHasNoQuery() async throws {
        let log = RequestLog()
        let client = makeClient(body: UsageFixtures.usage, log: log)
        _ = try await client.usage()

        XCTAssertEqual(log.url?.path, "/gw/usage")
        XCTAssertNil(log.url?.query)
    }

    func testHistoryPutsTheLabelInThePath() async throws {
        let log = RequestLog()
        let client = makeClient(body: UsageFixtures.history, log: log)
        let series = try await client.history(label: "main", since: Date(timeIntervalSince1970: 1_786_000_000))

        XCTAssertEqual(log.url?.path, "/gw/usage/main/history")
        XCTAssertEqual(series.points.count, 1)
    }

    /// Five seconds, and never a cached body: the numbers move every minute and
    /// a cache hit would be shown as a fresh reading.
    func testRequestsTimeOutAndIgnoreTheCache() async throws {
        let client = UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            XCTAssertEqual(request.timeoutInterval, 5)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.httpMethod, "GET")
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(UsageFixtures.usage.utf8), response)
        }
        _ = try await client.usage()
    }

    func testANonSuccessStatusIsAnError() async {
        let client = makeClient(body: "not found", status: 404)
        await assertFails(UsageError.status(404)) { _ = try await client.usage() }
    }

    func testABodyThatIsNotJSONIsAnError() async {
        let client = makeClient(body: "<html>relay is up, gateway is not</html>")
        await assertFails(UsageError.malformed("not JSON")) { _ = try await client.usage() }
    }

    func testAMissingRequiredFieldIsNamed() async {
        let client = makeClient(body: "{\"sessions\": []}")
        await assertFails(UsageError.malformed("no since")) {
            _ = try await client.sessions(since: Date())
        }
    }

    func testAConnectionThatDropsIsAnError() async {
        let client = makeClient(body: "", failure: URLError(.networkConnectionLost))
        do {
            _ = try await client.usage()
            XCTFail("a dropped connection has to surface as an error")
        } catch let error as UsageError {
            guard case .unreachable = error else {
                return XCTFail("expected .unreachable, got \(error)")
            }
        } catch {
            XCTFail("expected a UsageError, got \(error)")
        }
    }

    private func assertFails(_ expected: UsageError,
                             file: StaticString = #filePath,
                             line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as UsageError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected a UsageError, got \(error)", file: file, line: line)
        }
    }
}

/// Finding out which directories hold a session's transcript, from what Claude
/// Code left on disk. Nothing here opens a transcript, and the fixtures are
/// deliberately not valid JSON — a reader would have to fail on them.
final class UsageIndexTests: XCTestCase {

    private func makeProjectsDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A transcript filed under the slug of `directory`, exactly where Claude
    /// Code files one. The bytes are gibberish on purpose.
    private func file(_ sessionId: String, under directory: String, in root: URL) throws {
        let slug = root.appendingPathComponent(ClaudeSessions.slug(forPath: directory))
        try FileManager.default.createDirectory(at: slug, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: slug.appendingPathComponent("\(sessionId).jsonl"))
    }

    /// One session resumed in another directory has two files under two slugs,
    /// and both have to come back. Taking the first one found is the defect this
    /// suite exists for: the winner was whichever directory the walk reached
    /// first, and that could change between two polls.
    func testEverySlugHoldingTheSessionIsFound() throws {
        let root = try makeProjectsDirectory()
        let sessionId = UUID().uuidString
        try file(sessionId, under: "/Users/x/one", in: root)
        try file(sessionId, under: "/Users/x/two", in: root)

        XCTAssertEqual(UsageIndex.slugsBySessionId(for: [sessionId], projectsDirectory: root)[sessionId],
                       ["-Users-x-one", "-Users-x-two"],
                       "both copies, sorted, so two polls describe the session the same way")
    }

    /// Subagent transcripts live one level down, in `<sessionId>/subagents/`, and
    /// are not sessions the gateway ever reports.
    func testSubagentTranscriptsAreNotListed() throws {
        let root = try makeProjectsDirectory()
        let sessionId = UUID().uuidString
        try file(sessionId, under: "/Users/x/project", in: root)
        let nested = root.appendingPathComponent("-Users-x-project")
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("agent-deadbeef.jsonl"))

        let found = UsageIndex.slugsBySessionId(for: [sessionId, "agent-deadbeef"],
                                                projectsDirectory: root)
        XCTAssertEqual(found[sessionId], ["-Users-x-project"])
        XCTAssertNil(found["agent-deadbeef"], "a subagent is not a session")
    }

    /// A session running on another machine reports to the same gateway and has
    /// no transcript here. Ordinary, not an error.
    func testASessionWithNoTranscriptIsSimplyAbsent() throws {
        let root = try makeProjectsDirectory()
        XCTAssertTrue(UsageIndex.slugsBySessionId(for: ["nowhere-\(UUID().uuidString)"],
                                                  projectsDirectory: root).isEmpty)
    }

    func testAskingForNothingReadsNothing() throws {
        let root = try makeProjectsDirectory()
        XCTAssertTrue(UsageIndex.slugsBySessionId(for: [], projectsDirectory: root).isEmpty)
    }

    /// Several chats of the same project are several sessions in one directory,
    /// which is the ordinary case rather than a collision.
    func testSeveralSessionsOfOneDirectoryAreAllFound() throws {
        let root = try makeProjectsDirectory()
        let identifiers = [UUID().uuidString, UUID().uuidString]
        for sessionId in identifiers { try file(sessionId, under: "/Users/x/project", in: root) }

        let found = UsageIndex.slugsBySessionId(for: Set(identifiers), projectsDirectory: root)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.values), [["-Users-x-project"]])
    }
}

/// The whole join, over real directories: what Claude Code writes on disk, what
/// the gateway reports, and which row the number ends up on.
///
/// Built out of temporary directories rather than dictionaries because the rule
/// under test *is* the correspondence between a project on disk and a slug
/// directory on disk. A test that hands `assemble` a slug it computed itself
/// would agree with any slug function at all, including a wrong one.
final class UsageAttributionTests: XCTestCase {

    private var base = URL(fileURLWithPath: "/")
    private var projectsRoot = URL(fileURLWithPath: "/")
    /// Stands in for `~/.claude/projects`.
    private var transcripts = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-attribution-\(UUID().uuidString)")
        projectsRoot = base.appendingPathComponent("Projects")
        transcripts = base.appendingPathComponent("claude-projects")
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        addTeardownBlock { [base] in try? FileManager.default.removeItem(at: base) }
    }

    /// A project directory, with the named worktrees under it.
    private func makeProject(_ name: String, worktrees: [String] = []) throws -> ProjectInfo {
        let path = projectsRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        for worktree in worktrees {
            try FileManager.default.createDirectory(at: worktreePath(of: path.path, worktree),
                                                    withIntermediateDirectories: true)
        }
        return TestFixtures.project(path: path.path, rootName: name)
    }

    private func worktreePath(of project: String, _ name: String) -> URL {
        URL(fileURLWithPath: project)
            .appendingPathComponent(".claude/worktrees")
            .appendingPathComponent(name)
    }

    /// One transcript, filed under the slug of the directory the session started
    /// in. The bytes are gibberish: attribution must not depend on them.
    ///
    /// `writtenAt` dates the file, which is the one thing about it anything reads:
    /// a life last written to before a window opened cannot have spent inside it
    /// (`UsageIndex.narrowToWindow`). Left out, the file is dated now, which is
    /// inside every window a test can ask about.
    @discardableResult
    private func file(_ sessionId: String,
                      startedIn directory: String,
                      writtenAt: Date? = nil) throws -> String {
        let slugName = ClaudeSessions.slug(forPath: directory)
        let slug = transcripts.appendingPathComponent(slugName)
        try FileManager.default.createDirectory(at: slug, withIntermediateDirectories: true)
        let transcript = slug.appendingPathComponent("\(sessionId).jsonl")
        try Data("not json at all".utf8).write(to: transcript)
        if let writtenAt {
            try FileManager.default.setAttributes([.modificationDate: writtenAt],
                                                  ofItemAtPath: transcript.path)
        }
        return slugName
    }

    /// One subagent transcript of that session, in the place Claude Code puts it:
    /// `<slug>/<sessionId>/subagents/`, a level below the session's own file.
    ///
    /// It exists here because the gateway reports one aggregate for the whole
    /// `session_id` while a subagent's writing lands in a different file entirely,
    /// so the session's own mtime is not the whole of "was this life written to".
    @discardableResult
    private func subagentFile(_ name: String,
                              of sessionId: String,
                              startedIn directory: String,
                              writtenAt: Date) throws -> String {
        let slugName = ClaudeSessions.slug(forPath: directory)
        let directory = transcripts.appendingPathComponent(slugName)
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("\(name).jsonl")
        try Data("not json at all".utf8).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: writtenAt],
                                              ofItemAtPath: path.path)
        return slugName
    }

    /// A subagent entry that the directory listing names and `stat(2)` then
    /// refuses — the same race the parent transcript has, one level down.
    ///
    /// A dangling symlink is that state made deterministic. `contentsOfDirectory`
    /// returns the name (it does not follow the link), and `fileStamp` calls
    /// `stat`, which does follow it and fails — which is exactly what a file
    /// removed between the listing and the stamp looks like from inside
    /// `wasWrittenInWindow`. The alternative, removing the file after the listing,
    /// cannot be written from out here: the listing happens inside the function
    /// under test.
    @discardableResult
    private func unstatableSubagentFile(_ name: String,
                                        of sessionId: String,
                                        startedIn directory: String) throws -> String {
        let slugName = ClaudeSessions.slug(forPath: directory)
        let subagents = transcripts.appendingPathComponent(slugName)
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: subagents.appendingPathComponent("\(name).jsonl"),
            withDestinationURL: subagents.appendingPathComponent("removed-\(name).jsonl"))
        return slugName
    }

    private func session(_ identifier: String, input: Int) throws -> GatewaySession {
        try UsageFixtures.decode("""
        {"session_id": "\(identifier)", "input_tokens": \(input), "output_tokens": 0,
         "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
        """, as: GatewaySession.self)
    }

    /// The path the app takes: list the slug directories, fold the gateway's
    /// figures onto them, assemble the rows.
    private func attribute(_ sessions: [GatewaySession], projects: [ProjectInfo])
        -> (snapshot: SwitcherSnapshot, unmatched: TokenCounts, unmatchedSessions: Int) {
        let slugs = UsageIndex.slugsBySessionId(for: Set(sessions.map(\.sessionId)),
                                                projectsDirectory: transcripts)
        let folded = UsageIndex.fold(sessions: sessions, slugsBySessionId: slugs)
        // The window step the app takes between the fold and the assembly. Every
        // transcript these tests write is dated now, so nothing here is narrowed
        // away; it is in the path because leaving it out would make this helper a
        // different pipeline from the one it stands for.
        let contested = UsageIndex.narrowToWindow(
            folded.contested,
            since: Date().addingTimeInterval(-UsageStore.windowSeconds),
            projectsDirectory: transcripts)
        let snapshot = DataSource.assemble(projects: projects,
                                           windows: [],
                                           sessions: [],
                                           tokensBySlug: folded.tokensBySlug,
                                           contested: contested,
                                           worktrees: DataSource.worktrees(of: projects),
                                           accessibilityTrusted: true)
        return (snapshot, folded.unmatched, folded.unmatchedSessions)
    }

    private func spend(_ project: ProjectInfo, in snapshot: SwitcherSnapshot) -> Int? {
        snapshot.projects.first { $0.project?.path == project.path }?.usage?.input
    }

    /// The ordinary case: the session started in the project, so its file sits
    /// under the project's own slug.
    ///
    /// Checked by deleting the line that enters a project's own slug in
    /// `projectPathsBySlug`: this and most of the file below it fail.
    func testSpendUnderAProjectsOwnSlugLandsOnItsRow() throws {
        let project = try makeProject("switcher")
        try file("s1", startedIn: project.path)

        let result = attribute([try session("s1", input: 10)], projects: [project])
        XCTAssertEqual(spend(project, in: result.snapshot), 10)
        XCTAssertEqual(result.unmatchedSessions, 0)
    }

    /// A session started in a worktree belongs to the project the worktree is
    /// of. Nothing opens a window on `.claude/worktrees/<name>`, so keyed by its
    /// own slug the number would sit on no row at all.
    ///
    /// This is also the one case that cannot be answered from the slug alone:
    /// the slug of a worktree is not a prefix-match away from the slug of its
    /// project — the separator is gone, so `-x-portainer-` prefixes the slug of
    /// `portainer-agent` too. It is answered by having listed the worktree
    /// directories, which is what `DataSource.worktrees(of:)` is for.
    ///
    /// Checked by deleting the worktree pass in `projectPathsBySlug`, and again
    /// by having `attribute` pass `worktrees: [:]`: this test fails and the rest
    /// of the file does not.
    func testSpendUnderAWorktreeSlugLandsOnTheProjectsRow() throws {
        let project = try makeProject("switcher", worktrees: ["usage-ui"])
        try file("s1", startedIn: worktreePath(of: project.path, "usage-ui").path)

        let result = attribute([try session("s1", input: 7)], projects: [project])
        XCTAssertEqual(spend(project, in: result.snapshot), 7)
    }

    /// A slug that is no project and no worktree of one — an agent node's
    /// directory, `/private/tmp`, anything outside the scan roots — is not
    /// forced onto a row. It stays in the gateway's totals and belongs to
    /// nobody, which is what the app already says about spend it cannot place.
    func testASlugThatMatchesNoProjectLandsOnNoRow() throws {
        let project = try makeProject("switcher")
        try file("s1", startedIn: "/private/tmp/somewhere-else")

        let result = attribute([try session("s1", input: 10)], projects: [project])
        XCTAssertNil(spend(project, in: result.snapshot),
                     "the only project must not inherit a directory that is not it")
        XCTAssertEqual(result.snapshot.ambiguousUsageSessions, 0,
                       "one candidate is not a contest, however little it matches")
    }

    /// A session with no transcript here at all — the agent nodes run their own
    /// Claude Code and report to the same gateway. Real spend with no local
    /// owner, counted as such rather than dropped.
    func testASessionWithNoTranscriptAtAllIsUnmatched() throws {
        let project = try makeProject("switcher")

        let result = attribute([try session("elsewhere", input: 7)], projects: [project])
        XCTAssertEqual(result.unmatchedSessions, 1)
        XCTAssertEqual(result.unmatched.input, 7, "counted, and counted as nobody's")
        XCTAssertNil(spend(project, in: result.snapshot))
    }

    /// Two copies of one session, both inside one project — the session was
    /// resumed in a worktree of the project it started in. One session, one
    /// aggregate from the gateway, one number on the row.
    ///
    /// Checked by summing the contested tokens once per candidate slug in
    /// `settle`: this test fails with 20 and nothing else notices.
    func testTwoCopiesInsideOneProjectAreCountedOnceAndNotTwice() throws {
        let project = try makeProject("switcher", worktrees: ["usage-ui"])
        try file("s1", startedIn: project.path)
        try file("s1", startedIn: worktreePath(of: project.path, "usage-ui").path)

        let result = attribute([try session("s1", input: 10)], projects: [project])
        XCTAssertEqual(spend(project, in: result.snapshot), 10, "one session, one aggregate, once")
        XCTAssertEqual(result.snapshot.ambiguousUsageSessions, 0,
                       "two directories of one project are not a disagreement")
    }

    /// Two copies in two different projects. The gateway reports one aggregate
    /// for the whole session and there is nothing to divide it by, so neither
    /// project gets it and the fact is reported instead of being resolved by
    /// coin-flip.
    ///
    /// This is the defect the suite was written for. Checked by restoring "the
    /// first directory found wins": the spend then lands on one of the two
    /// projects — which one depends on the order the directories are listed in —
    /// and this test fails.
    func testTwoCopiesInTwoProjectsGoToTheAmbiguousBucket() throws {
        let first = try makeProject("switcher")
        let second = try makeProject("home-network")
        try file("s1", startedIn: first.path)
        try file("s1", startedIn: second.path)

        let result = attribute([try session("s1", input: 12)], projects: [first, second])
        XCTAssertNil(spend(first, in: result.snapshot))
        XCTAssertNil(spend(second, in: result.snapshot))
        XCTAssertEqual(result.snapshot.ambiguousUsageSessions, 1)
        XCTAssertEqual(result.snapshot.ambiguousUsage.input, 12, "counted, and named as nobody's")
    }

    /// The slug replaces every character outside `[A-Za-z0-9-]`, not just the
    /// separator, and cannot be turned back into a path. So the match runs
    /// forwards, through `ClaudeSessions.slug(forPath:)`.
    ///
    /// Checked by matching on a naive `/` → `-` replacement instead: the
    /// underscore and the dot survive, the slug does not match, and this test
    /// fails while every other project name in the file goes on matching.
    func testAProjectWithUnderscoresAndDotsInItsNameStillMatches() throws {
        let project = try makeProject("my_project.v2")
        try file("s1", startedIn: project.path)

        XCTAssertTrue(ClaudeSessions.slug(forPath: project.path).hasSuffix("-my-project-v2"),
                      "the name is not recoverable from the slug, which is the point")
        let result = attribute([try session("s1", input: 5)], projects: [project])
        XCTAssertEqual(spend(project, in: result.snapshot), 5)
    }

    /// The line `--dump` prints about the bucket. Silence would be the same
    /// silent loss the split exists to stop, one level up.
    ///
    /// One line per window, and the window is in the label: the two buckets hold
    /// two different sets of sessions, so a line that did not say which window it
    /// counted would be two facts wearing one name.
    func testTheDumpNamesTheAmbiguousBucketAndCountsIt() throws {
        let first = try makeProject("switcher")
        let second = try makeProject("home-network")
        try file("s1", startedIn: first.path)
        try file("s1", startedIn: second.path)

        let result = attribute([try session("s1", input: 12)], projects: [first, second])
        XCTAssertEqual(ConsoleDump.ambiguousLine(window: "7d",
                                                 sessions: result.snapshot.ambiguousUsageSessions,
                                                 tokens: result.snapshot.ambiguousUsage),
                       "ambiguous 7d:        1 sessions, 12 ie (in 12, out 0, cw 0, cr 0)")
        XCTAssertEqual(ConsoleDump.ambiguousLine(window: "1h", sessions: 0, tokens: .zero),
                       "ambiguous 1h:        0 sessions, -",
                       "and it is printed when the bucket is empty: a line that appears only "
                       + "when it is non-empty teaches nobody the bucket exists")
    }

    /// **Every figure in the usage section starts in one column, and the widest
    /// label is what that column is for.**
    ///
    /// The section was eight hand-counted runs of spaces plus one `column(…)` of
    /// 18, and `no local session:` fitted that at 17 characters. Giving it a window
    /// took it to 20, and `column` pads without ever truncating — so those two
    /// lines, and only those two, would have started their figures two columns
    /// right of every other line in the section, silently, with nothing anywhere to
    /// fail.
    ///
    /// Asked of **the whole assembled section**, and that is the correction this
    /// test needed. It used to compose four lines by hand out of `unmatchedLine`
    /// and `ambiguousLine` — the only two of the section's twelve labels that
    /// have a function of their own — while the other eight called `label` inline
    /// inside `printUsage` and were reachable from no test at all. `unavailable:` growing
    /// past the width would have pushed its own figure right, quietly, exactly the
    /// way the four windowed labels once did. That is the `spendColumnWidth` defect
    /// again: a constant pinned to its cell while the table it aligns is pinned to
    /// nothing, and it is fixed the same way — by extracting the composition
    /// (`ConsoleDump.usageLines`) and asking the rows.
    ///
    /// The fixture forces both optional lines out — `unavailable:`, and
    /// `window:` — so all twelve are measured. The widest inline label is
    /// `burn vs refill:` at 15 characters, which arrived with the lead metric and
    /// is the reason the count moved from eleven to twelve: the spend rate kept
    /// its own line when the burn ratio took the lead, and a line added past the
    /// label column is exactly what the count below is for.
    ///
    /// Two mutations, and the second is the one that shows the gap was real.
    /// Putting the width back to 18 takes down 3 test cases and 6 assertions of
    /// 639 (this one, `testTheDumpNamesTheAmbiguousBucketAndCountsIt` and
    /// `testTheHoursOwnerlessSpendIsKeptAndPrinted`). Writing the literal `12` at
    /// an inline call site — `column("unavailable:", 12)` in `usageLines`, where
    /// `column` then pads nothing, the label being 12 characters itself — takes
    /// down 1: this one. Run against the **pre-fix body** of this test, that same
    /// literal fails **0 of 639**, which is the finding in one number.
    func testTheUsageSectionsFiguresAllStartInOneColumn() throws {
        var usage = UsageSnapshot.empty
        usage.sessionsFailure = "/gw/sessions: timed out"
        usage.since = Date().addingTimeInterval(-UsageStore.windowSeconds)
        let lines = ConsoleDump.usageLines(usage, snapshot: .empty)

        XCTAssertEqual(lines.count, 12,
                       "the fixture has to reach every line of the section, the two conditional "
                       + "ones included, or the labels it does not draw go unmeasured")
        for line in lines {
            // The label is everything up to its colon; the figure starts at the
            // first non-blank after the padding. Asking where the padding ends is
            // the whole property — `column` never truncates, so a label wider than
            // the width simply moves its own figure right.
            let colon = try XCTUnwrap(line.firstIndex(of: ":"), "no label in \(line)")
            let figure = try XCTUnwrap(line[line.index(after: colon)...].firstIndex { $0 != " " },
                                       "no figure in \(line)")
            XCTAssertEqual(line.distance(from: line.startIndex, to: figure),
                           2 + ConsoleDump.usageLabelWidth,
                           "\(line) does not line up with the rest of the section")
        }
    }

    /// **The lead line of the section, asserted whole**, and until 2026-09-05
    /// nothing asked it anything at all.
    ///
    /// The test above is the only other one that touches this line and it feeds
    /// `UsageSnapshot.empty`, so `fleetBurn` is `nil` and the only branch ever
    /// reached is the `-`. Measured by mutation on a copy of the source that day:
    /// printing `refillRate` where the per cent belongs, dropping the `(>=)`, and
    /// swapping the two rates in the format string each failed **0 of 622** tests.
    /// The last of those is the one that matters — a fleet burning three times
    /// faster than it refills would have been drawn as one burning three times
    /// slower — and this line is the one the figure is checked against the gateway
    /// by hand from, which is what makes hand-checkable numbers its whole purpose.
    ///
    /// The two rates in the fixture differ, deliberately: equal rates make the
    /// swap invisible. So do the per cent and the refill rate, which is what makes
    /// printing one for the other visible.
    ///
    /// The first half is the live line, run 2026-09-05 15:33:41Z, and the second
    /// is the fleet of `testTheFigureIsBuiltFromRawPointsRatherThanSmoothedOnes` —
    /// one account pinned at its ceiling for four samples of five beside one that
    /// burns 50 pp over 48 h, which is 1.042 pp/h against 1.190 refilled and the
    /// `≥` the suppressed burn owes the reader.
    func testTheLeadLineNamesTheRatioItsDepthAndBothSidesOfTheDivision() throws {
        func burnLine(_ burn: FleetCapacity.FleetBurn) throws -> String {
            var usage = UsageSnapshot.empty
            usage.fleetBurn = burn
            let lines = ConsoleDump.usageLines(usage, snapshot: .empty)
            return try XCTUnwrap(lines.first { $0.contains("burn vs refill:") },
                                 "the section has no lead line at all")
        }

        XCTAssertEqual(
            // The refill rate is the expression production computes, not the
            // three digits it prints: built from the printed `1.786` the fixture
            // was an object the app cannot produce, and its per cent — derived
            // from that rounding — was 170.605 where the value gives 170.632.
            try burnLine(FleetCapacity.FleetBurn(percent: 170.632, burnRate: 3.047,
                                                 refillRate: 3 * 100.0 / 168, accounts: 3,
                                                 measuredHours: 43.09, isLowerBound: false)),
            "  burn vs refill:      171%, 3 accounts over 43.1 h,"
                + " 3.047 pp/h burned vs 1.786 pp/h refilled", """
            the live line of 2026-09-05 15:33:41Z, and every number in it is one of the figure's \
            own: swapping the two rates draws a fleet burning 1.7 times faster than it refills as \
            one burning 0.6 times as fast, and printing the refill rate as the per cent answers 2%
            """)

        XCTAssertEqual(
            try burnLine(FleetCapacity.FleetBurn(percent: 87.5, burnRate: 100.0 / 96,
                                                 refillRate: 200.0 / 168, accounts: 2,
                                                 measuredHours: 48, isLowerBound: true)),
            "  burn vs refill:      88% (>=), 2 accounts over 48.0 h,"
                + " 1.042 pp/h burned vs 1.190 pp/h refilled",
            "an account's burn was suppressed by its ceiling and the line printed the floor as a "
                + "reading: `(>=)` is the panel's `≥` spelled for a terminal")
    }

    /// The hour has a bucket of its own, and it is filled by the hour's own
    /// contested sessions rather than by the week's.
    ///
    /// The fixture is the case the split exists for: one session contested over
    /// the hour and **absent from the week's report altogether**. Today that state
    /// is reached by failure — the two `/gw/sessions` calls fail apart, and a week
    /// that timed out leaves no week's report at all (§2.9); the gateway's
    /// 200-consumer cap would reach it too, but is not firing on this machine
    /// (`SwitcherSnapshot.ambiguousHourlyUsage`). Sharing one bucket would report
    /// this spend under `7d` — where nothing else about that session appears — or
    /// not at all.
    func testTheHourHasItsOwnAmbiguousBucket() throws {
        let first = try makeProject("switcher")
        let second = try makeProject("home-network")
        try file("s1", startedIn: first.path)
        try file("s1", startedIn: second.path)

        let hourly = UsageIndex.fold(sessions: [try session("s1", input: 12)],
                                     slugsBySessionId: UsageIndex.slugsBySessionId(
                                        for: ["s1"], projectsDirectory: transcripts))
        XCTAssertEqual(hourly.contested.count, 1, "the fixture has to be contested to be about this")
        let snapshot = DataSource.assemble(projects: [first, second],
                                           windows: [],
                                           sessions: [],
                                           tokensBySlug: [:],
                                           contested: [],
                                           hourlyTokensBySlug: hourly.tokensBySlug,
                                           hourlyContested: hourly.contested,
                                           worktrees: DataSource.worktrees(of: [first, second]),
                                           accessibilityTrusted: true)

        XCTAssertEqual(snapshot.ambiguousHourlySessions, 1)
        XCTAssertEqual(snapshot.ambiguousHourlyUsage.input, 12, "counted, and named as nobody's")
        XCTAssertEqual(snapshot.ambiguousUsageSessions, 0,
                       "the week's bucket did not inherit the hour's session")
        XCTAssertEqual(snapshot.ambiguousUsage, .zero)
        // The row is unwrapped first, on purpose: `first {…}?.hourlyUsage` is `nil`
        // when there is no such row at all, so the assertion would pass without
        // ever having asked about the spend.
        for path in [first.path, second.path] {
            let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == path },
                                    "no row for \(path) to refuse the spend")
            XCTAssertNil(row.hourlyUsage, "contested spend landed on a row anyway")
        }
    }

    /// And the control half: the same session, both copies inside one project, is
    /// not a contest at all — its hourly figure lands on the row.
    ///
    /// Without it the test above passes for any rule that refuses everything.
    func testAnHourlySessionWhoseSlugsAgreeLandsOnTheRow() throws {
        let project = try makeProject("switcher", worktrees: ["usage-ui"])
        try file("s1", startedIn: project.path)
        try file("s1", startedIn: worktreePath(of: project.path, "usage-ui").path)

        let hourly = UsageIndex.fold(sessions: [try session("s1", input: 12)],
                                     slugsBySessionId: UsageIndex.slugsBySessionId(
                                        for: ["s1"], projectsDirectory: transcripts))
        XCTAssertEqual(hourly.contested.count, 1, "still contested at the fold; the project settles it")
        let snapshot = DataSource.assemble(projects: [project],
                                           windows: [],
                                           sessions: [],
                                           hourlyTokensBySlug: hourly.tokensBySlug,
                                           hourlyContested: hourly.contested,
                                           worktrees: DataSource.worktrees(of: [project]),
                                           accessibilityTrusted: true)

        let row = snapshot.projects.first { $0.project?.path == project.path }
        XCTAssertEqual(row?.hourlyUsage?.input, 12, "one session, one aggregate, once")
        XCTAssertEqual(snapshot.ambiguousHourlySessions, 0,
                       "two directories of one project are not a disagreement")
    }

    // MARK: - A session resumed in another project, over two windows

    /// The live pair of 2026-08-27, cut down to what decides it.
    ///
    /// Session `8fa4e946-…` had a copy under the slug of `hammerola` — 16.5 MB and
    /// being written at 20:01 that day — and a copy under the slug of
    /// `cad_snapshot_hub`, 6.1 MB and untouched since 2026-08-24 17:20. Both are
    /// real projects inside the scan roots, so the contest is genuine: over the
    /// week the gateway's single aggregate really does hold spend from both lives.
    /// Over the sliding hour it cannot: the second life is days outside it.
    ///
    /// The second project is named with underscores on purpose. `cad_snapshot_hub`
    /// and a directory literally called `cad-snapshot-hub` slug identically, which
    /// is what makes reading a slug backwards a way to invent a directory that
    /// never existed — and it cost a wrong diagnosis on this very session.
    private func resumedSession(now: Date, input: Int = 12, silentFor: TimeInterval = 3 * 86_400)
        throws -> (current: ProjectInfo, previous: ProjectInfo, contested: [ContestedSpend]) {
        let current = try makeProject("hammerola")
        let previous = try makeProject("cad_snapshot_hub")
        try file("s1", startedIn: current.path, writtenAt: now)
        try file("s1", startedIn: previous.path, writtenAt: now.addingTimeInterval(-silentFor))

        let folded = UsageIndex.fold(sessions: [try session("s1", input: input)],
                                     slugsBySessionId: UsageIndex.slugsBySessionId(
                                        for: ["s1"], projectsDirectory: transcripts))
        XCTAssertEqual(folded.contested.count, 1, "the fixture has to be contested to be about this")
        return (current, previous, folded.contested)
    }

    /// A live session file for `sessionId`, started in `cwd` — the record outside
    /// the transcript tree that says which life of the session is the current one.
    private func live(_ sessionId: String, startedIn cwd: String) -> ClaudeSessionInfo {
        TestFixtures.session(id: sessionId, cwd: cwd, state: .working)
    }

    private func narrow(_ contested: [ContestedSpend], since: Date) -> [ContestedSpend] {
        UsageIndex.narrowToWindow(contested, since: since, projectsDirectory: transcripts)
    }

    /// **The hour gives the contest to the life that is actually being written.**
    ///
    /// This is the defect the change was made for: on 2026-08-27 the hour reported
    /// 42.53M, of which 30.58M reached rows and 11.95M — the largest single
    /// spender on the machine, in a project with four agents working in it — was
    /// dropped as ambiguous. 28.1% of the hour, and the row it belonged to printed
    /// no rate at all, for the single reason that its chat had once been resumed
    /// somewhere else. SPEC §2.9 already named that outcome as the thing not to do.
    ///
    /// The mtime is what settles it, and it is not a tie-break between two
    /// transcripts (mtime and size as *tie-breaks* stay rejected — see
    /// `DataSource.settle`): it is the observation that a file untouched for three
    /// days cannot have spent anything in the last hour. The live session file
    /// agrees, and this fixture has one, because that is the shape the live case
    /// had.
    ///
    /// Checked by having `narrowToWindow` keep the newest copy instead of every
    /// copy inside the window — the tempting rule, and the one that would answer
    /// the week wrongly: this test stays green and its pair below fails.
    func testTheHourGivesTheContestToTheLifeThatWasWrittenInIt() throws {
        let now = Date()
        let fixture = try resumedSession(now: now)
        let projects = [fixture.current, fixture.previous]

        let snapshot = DataSource.assemble(
            projects: projects,
            windows: [],
            sessions: [live("s1", startedIn: fixture.current.path)],
            hourlyContested: narrow(fixture.contested,
                                    since: now.addingTimeInterval(-UsageStore.hourWindowSeconds)),
            worktrees: DataSource.worktrees(of: projects),
            accessibilityTrusted: true)

        let current = try XCTUnwrap(snapshot.projects.first { $0.project?.path == fixture.current.path })
        let previous = try XCTUnwrap(snapshot.projects.first { $0.project?.path == fixture.previous.path })
        XCTAssertEqual(current.hourlyUsage?.input, 12,
                       "the project being worked in right now still prints no rate")
        XCTAssertNil(previous.hourlyUsage, "the life that has been silent for days took the spend")
        XCTAssertEqual(snapshot.ambiguousHourlySessions, 0)
        XCTAssertEqual(snapshot.ambiguousHourlyUsage, .zero)
    }

    /// **And the week keeps the very same contest ambiguous, because over a week
    /// both lives really were running.**
    ///
    /// One rule, two windows, two different and correct answers — that pair is the
    /// whole change. Handing the week to `hammerola` as well would move up to four
    /// days of another project's work onto the wrong row: a new silent
    /// misattribution, which is the class of defect this path exists to remove.
    ///
    /// Checked by the mutation named on its pair above — `narrowToWindow` keeping
    /// only the newest copy — which resolves this contest to `hammerola` and turns
    /// this test red while leaving the hour's green.
    func testTheWeekKeepsTheSameContestAmbiguousBecauseBothLivesRanInsideIt() throws {
        let now = Date()
        let fixture = try resumedSession(now: now)
        let projects = [fixture.current, fixture.previous]

        let snapshot = DataSource.assemble(
            projects: projects,
            windows: [],
            sessions: [live("s1", startedIn: fixture.current.path)],
            contested: narrow(fixture.contested,
                              since: now.addingTimeInterval(-UsageStore.windowSeconds)),
            worktrees: DataSource.worktrees(of: projects),
            accessibilityTrusted: true)

        for project in projects {
            let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == project.path })
            XCTAssertNil(row.usage, "a week of another project's work landed on \(project.rootName)")
        }
        XCTAssertEqual(snapshot.ambiguousUsageSessions, 1)
        XCTAssertEqual(snapshot.ambiguousUsage.input, 12, "counted, and still named as nobody's")
    }

    /// **A copy that cannot be stat'ed keeps its claim on the window.**
    ///
    /// The rule was written down in `narrowToWindow`'s comment and held by nothing
    /// else: turning its `else { return true }` into `else { return false }` left
    /// the whole suite green. What it costs is not hypothetical. A copy is listed
    /// and then stat'ed, the writer that removes it is not synchronised with this
    /// pass at all, and any gap between the two will do — so a copy can be listed
    /// and be gone by the time it is asked about. If the copy that vanishes is the
    /// *winning* one, the contest is left holding a single claim, `settle` counts
    /// it, and a whole session's spend lands on a row it does not belong to. That
    /// is the silent misattribution `contested` exists to prevent.
    ///
    /// **The rule is written twice, so it is asked twice.** `wasWrittenInWindow`
    /// stats two kinds of file — the parent transcript and every `*.jsonl` under
    /// `subagents/` — and each has its own `else { return true }`. Only the parent's
    /// was held here, and flipping the subagent one to `false` took down nothing at
    /// all. The cost is the same and just as reachable, and the caching is beside
    /// the point on both halves: the `subagents/` listing goes through no cache at
    /// all (`UsageIndex.listingCache` serves `slugsBySessionId` alone), and the slug
    /// listings that do are re-checked against directory mtime on every call, so
    /// neither half's listing is any staler than the pass it runs in.
    ///
    /// Four lives, because a direction needs a control: the one written inside the
    /// window survives, the one three days stale is dropped, the one whose own
    /// transcript is missing survives with the first, and the one that is stale by
    /// its transcript but has a subagent entry that cannot be stat'ed survives too.
    /// Without the stale life this would agree with a rule that narrows nothing at
    /// all.
    func testACopyThatCannotBeStatedKeepsItsClaimOnTheWindow() throws {
        let now = Date()
        let longAgo = now.addingTimeInterval(-3 * 86_400)
        let fresh = try makeProject("hammerola")
        let stale = try makeProject("cad_snapshot_hub")
        let vanishing = try makeProject("research_mcp")
        let racing = try makeProject("ukuetis_site")
        try file("s1", startedIn: fresh.path, writtenAt: now)
        try file("s1", startedIn: stale.path, writtenAt: longAgo)
        let vanished = try file("s1", startedIn: vanishing.path, writtenAt: now)
        // Stale by its own transcript, so the listing is reached, and the only
        // thing the listing names is a file the stamp cannot answer about.
        try file("s1", startedIn: racing.path, writtenAt: longAgo)
        let raced = try unstatableSubagentFile("agent-1", of: "s1", startedIn: racing.path)

        // Listed first and removed second, which is the order the race takes: the
        // slug is in the contest because the listing saw it, and the file is gone
        // by the time the stamp is asked for.
        let contested = UsageIndex.fold(
            sessions: [try session("s1", input: 12)],
            slugsBySessionId: UsageIndex.slugsBySessionId(for: ["s1"],
                                                          projectsDirectory: transcripts)).contested
        XCTAssertEqual(contested.first?.slugs.count, 4, "the fixture has to hold all four lives")
        try FileManager.default.removeItem(at: transcripts.appendingPathComponent(vanished)
                                            .appendingPathComponent("s1.jsonl"))

        // The fourth life is only about the subagent branch if the listing really
        // does name the file and the stamp really is what fails. Both halves are
        // asked, because a fixture that quietly listed nothing would pass the
        // assertion below for the wrong reason.
        let subagents = transcripts.appendingPathComponent(raced)
            .appendingPathComponent("s1/subagents")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: subagents.path),
                       ["agent-1.jsonl"], "the listing has to name the file for this to be the race")
        XCTAssertNil(fileStamp(atPath: subagents.appendingPathComponent("agent-1.jsonl").path),
                     "and the stamp has to be the half that fails")

        let survivors = Set(narrow(contested,
                                   since: now.addingTimeInterval(-UsageStore.hourWindowSeconds))
            .first?.slugs ?? [])
        XCTAssertTrue(survivors.contains(ClaudeSessions.slug(forPath: fresh.path)),
                      "the life written inside the window lost its claim")
        XCTAssertTrue(survivors.contains(vanished),
                      "a copy that could not be stat'ed was dropped from the contest, which is "
                      + "how a whole session's spend is handed to whichever copy is left")
        XCTAssertTrue(survivors.contains(raced),
                      "a copy whose subagent file could not be stat'ed was dropped, which costs "
                      + "exactly what the parent transcript's half of this rule costs")
        XCTAssertFalse(survivors.contains(ClaudeSessions.slug(forPath: stale.path)),
                       "a life three days out of the window kept its claim, so this fixture "
                       + "would agree with a rule that narrows nothing")
    }

    /// **A life whose subagent is writing could have spent**, even while the
    /// session's own transcript stands still.
    ///
    /// The narrowing asked `<slug>/<sessionId>.jsonl` and nothing else, and that is
    /// not where a subagent writes: its records go to
    /// `<slug>/<sessionId>/subagents/agent-*.jsonl` (§2.6.3) while the gateway
    /// keeps reporting one aggregate for the whole `session_id`. So the parent file
    /// can stand still through a long stretch of real spending. That is a live
    /// table, and the population moves with the finding, so neither is a fixed
    /// number: passes on 2026-08-27 and 2026-08-28 over 609 session transcripts
    /// with 344 `subagents/` directories found 10 and then 6 with a subagent file
    /// newer than their parent, the largest gap 917.5 s (15.29 min) and then
    /// 124.2 s, while recounts on 2026-08-28 saw 613 transcripts, 345 directories
    /// and 5 such sessions both times, gap 355.8 s (5.93 min) at 05:44 and 330.2 s
    /// at 05:58. All
    /// fit inside the hour, so nothing is misattributed today — which is luck: a
    /// subagent running longer than the window drops the working life out of the
    /// survivors and leaves a rival copy that a resume had merely touched, and the
    /// live-session veto is no backstop because it only sees sessions started from
    /// the VSCode extension.
    ///
    /// Both lives carry a `subagents/` directory on purpose. What keeps the first
    /// one is that something under it was written *inside the window*, not that it
    /// has subagents at all.
    func testASubagentWritingKeepsALifeWhoseTranscriptStandsStill() throws {
        let now = Date()
        let longAgo = now.addingTimeInterval(-3 * 86_400)
        let working = try makeProject("hammerola")
        let quiet = try makeProject("cad_snapshot_hub")
        try file("s1", startedIn: working.path, writtenAt: longAgo)
        try subagentFile("agent-1", of: "s1", startedIn: working.path, writtenAt: now)
        try file("s1", startedIn: quiet.path, writtenAt: longAgo)
        try subagentFile("agent-1", of: "s1", startedIn: quiet.path, writtenAt: longAgo)

        let contested = UsageIndex.fold(
            sessions: [try session("s1", input: 12)],
            slugsBySessionId: UsageIndex.slugsBySessionId(for: ["s1"],
                                                          projectsDirectory: transcripts)).contested
        XCTAssertEqual(contested.first?.slugs.count, 2, "the fixture has to be contested")

        let survivors = narrow(contested,
                               since: now.addingTimeInterval(-UsageStore.hourWindowSeconds))
            .first?.slugs
        XCTAssertEqual(survivors, [ClaudeSessions.slug(forPath: working.path)],
                       "the life being written to by a subagent was narrowed away, and the "
                       + "contest handed to the copy a resume had merely touched")
    }

    /// A live session whose **own** life was narrowed out of the window, while a
    /// rival copy was being written inside it. The two records describe two
    /// different situations, and the safe answer is the one that was there before:
    /// ambiguous.
    ///
    /// This is the reachable form of the veto's condition, and it took a second
    /// look to find. The fixture here used to name `/private/tmp/somewhere-else` —
    /// a directory among none of the copies — which cannot happen: a running
    /// session has a transcript under the slug of the directory it started in, and
    /// `slugsBySessionId` lists every copy there is, so the live slug is always one
    /// of them at the fold. What removes it is the *narrowing*: the live session's
    /// own transcript can be silent longer than the window (it is idle, or the
    /// hour has slid past its last record) while the other life of the same
    /// `session_id`, resumed elsewhere, is being written right now. Then the hour
    /// has exactly one claim standing and it is not the one the live record names.
    ///
    /// Reachable rather than decorative in the second sense too — the narrowing
    /// has left exactly one claim standing, so without the veto this spend lands on
    /// `hammerola`.
    ///
    /// Checked by deleting the live-session refusal in `settle`. It used to say
    /// here that this test fails "and its neighbours do not", which was never run:
    /// the mutation takes down **2 test cases and 6 assertions** of 639 — this one
    /// and `testBothWindowsAreSettledAgainstTheSameLiveSessions`, which is exactly
    /// right, since that one exists to check the veto reaches both windows. Rerun
    /// on the fixture above (2026-08-28), because a fixture change is a change to
    /// what the mutation can be caught by: same 2 cases, same 6 assertions.
    func testALiveSessionWhoseOwnLifeFellOutOfTheWindowLeavesTheContestAmbiguous() throws {
        let now = Date()
        let fixture = try resumedSession(now: now)
        let projects = [fixture.current, fixture.previous]

        let snapshot = DataSource.assemble(
            projects: projects,
            windows: [],
            sessions: [live("s1", startedIn: fixture.previous.path)],
            hourlyContested: narrow(fixture.contested,
                                    since: now.addingTimeInterval(-UsageStore.hourWindowSeconds)),
            worktrees: DataSource.worktrees(of: projects),
            accessibilityTrusted: true)

        let current = try XCTUnwrap(snapshot.projects.first { $0.project?.path == fixture.current.path })
        XCTAssertNil(current.hourlyUsage,
                     "the surviving claim was taken for the answer while the live session says "
                     + "its own life is the other one")
        XCTAssertEqual(snapshot.ambiguousHourlySessions, 1)
    }

    /// **One `session_id`, one live row.** This is the invariant that lets
    /// `DataSource.liveSlugsBySessionId` be a map at all, and therefore lets the
    /// contest veto ask one question and get one answer.
    ///
    /// It replaces a `LiveStart.disputed` case that refused a contest when two live
    /// sessions claimed one identifier from two different directories. That case
    /// could not fire: the only producer of its input is
    /// `ClaudeSessions.liveSessions`, which dedupes by session id, so the pair never
    /// reached the map and the only test for it built the pair by hand — a test of
    /// the line next to it rather than of the system. Its comment was wrong as well
    /// as unreachable, claiming a protection against
    /// `Dictionary(uniquingKeysWith:)` picking one of two disagreeing answers while
    /// `liveSessions` had already done exactly that one layer below, keeping the
    /// lexicographically first `<pid>.json`. So: the branch is gone, and this holds
    /// the reason it is unnecessary. It is what has to go red before the veto's
    /// assumption is reopened.
    ///
    /// Two session files naming one identifier from two directories, and a pid that
    /// really is alive — this process — because `isSessionProcessAlive` throws out
    /// everything else before the dedup is ever reached.
    func testOneSessionIdYieldsOneLiveRow() throws {
        let sessionsDirectory = base.appendingPathComponent("claude-sessions")
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let identifier = "live-\(UUID().uuidString)"
        for (name, cwd) in [("100.json", "first"), ("200.json", "second")] {
            let body = """
            {"sessionId": "\(identifier)", "cwd": "\(projectsRoot.appendingPathComponent(cwd).path)",
             "entrypoint": "claude-vscode", "pid": \(getpid())}
            """
            try Data(body.utf8).write(to: sessionsDirectory.appendingPathComponent(name))
        }

        let sessions = ClaudeSessions.liveSessions(config: .default,
                                                   sessionsDirectory: sessionsDirectory)
        XCTAssertEqual(sessions.count, 1,
                       "two files named one session and both became rows, so the veto now has "
                       + "two answers to one question and the map keeps whichever it likes")
        XCTAssertEqual(sessions.first?.cwd, projectsRoot.appendingPathComponent("first").path,
                       "the winner is the lexicographically first file, not directory order")
        // Asked of the map's *answer*, not of its size: `count == 1` is true for
        // any non-empty `sessions` here, since the fixture has one identifier and
        // a dictionary keyed by it cannot hold two — an assertion with no "no" in
        // it, green under the very mutation it was put here to catch.
        XCTAssertEqual(DataSource.liveSlugsBySessionId(of: sessions)[identifier],
                       ClaudeSessions.slug(forPath: projectsRoot.appendingPathComponent("first").path),
                       "the veto is answered about a directory the surviving row does not name")
    }

    /// No live session at all — both lives are over — and both copies were written
    /// inside the window. This is the case that has to keep behaving exactly as it
    /// did before any of this: two claims, nothing to choose between them,
    /// ambiguous.
    ///
    /// Checked by the same "keep the newest copy" mutation as the week's test: it
    /// hands this spend to whichever life was written last, which is the coin-flip
    /// with a straight face `settle` has always refused.
    func testWithNoLiveSessionAndBothLivesInsideTheWindowNothingIsResolved() throws {
        let now = Date()
        let fixture = try resumedSession(now: now.addingTimeInterval(-3 * 86_400),
                                         silentFor: 2 * 86_400)
        let projects = [fixture.current, fixture.previous]

        let snapshot = DataSource.assemble(
            projects: projects,
            windows: [],
            sessions: [],
            contested: narrow(fixture.contested,
                              since: now.addingTimeInterval(-UsageStore.windowSeconds)),
            worktrees: DataSource.worktrees(of: projects),
            accessibilityTrusted: true)

        for project in projects {
            let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == project.path })
            XCTAssertNil(row.usage, "\(project.rootName) was handed a contest nobody can settle")
        }
        XCTAssertEqual(snapshot.ambiguousUsageSessions, 1)
    }

    /// **Both windows are settled against the same live sessions**, and nothing
    /// else in the suite says so.
    ///
    /// `spread` is one function called twice because "whose spend is this" may have
    /// only one policy in one snapshot (SPEC §2.9). The live-session map is that
    /// policy, so a window given it while the other went without would be exactly
    /// the split the single function exists to prevent — and it would be invisible,
    /// since each window's figures are read on their own.
    ///
    /// The fixture makes both windows resolvable on their own: the rival life is a
    /// month old, so it falls outside the week as well as the hour, and only the
    /// live session's refusal keeps either figure off a row.
    ///
    /// The live record names that rival life, and it used to name
    /// `/private/tmp/somewhere-else` — a directory among none of the copies, which
    /// cannot happen for the reason
    /// `testALiveSessionWhoseOwnLifeFellOutOfTheWindowLeavesTheContestAmbiguous`
    /// gives: a running session has a transcript under the slug of the directory it
    /// started in, and `slugsBySessionId` lists every copy there is. Pointing it at
    /// `previous` costs the fixture nothing — that life is already a month silent,
    /// so both windows narrow it away and the veto fires in both exactly as before —
    /// and it buys the difference between "implausible" and "impossible": a session
    /// resumed elsewhere and left idle for a month is a session anyone could have.
    ///
    /// Checked by passing `[:]` to one `spread` call and then to the other, and
    /// the two directions are **not** symmetric — the note here used to claim each
    /// way round turns one half red "and nothing else in the file notices", which
    /// holds for one of them only. Starving the **week** takes down 1 test case and
    /// 2 assertions of 639: this one, alone, as claimed. Starving the **hour**
    /// takes down 2 test cases and 4 assertions — this one and
    /// `testALiveSessionWhoseOwnLifeFellOutOfTheWindowLeavesTheContestAmbiguous`,
    /// whose fixture is an hourly contest and which therefore has every right to
    /// notice. Rerun on the fixture above (2026-08-28), because moving the live
    /// record is a change to what those mutations can be caught by: same 1 case and
    /// 2 assertions, same 2 cases and 4 assertions. Deleting the veto in `settle`
    /// outright was rerun on it too — all four assertions here go red, 2 cases and
    /// 6 assertions of 639 across the file, exactly as before the move.
    func testBothWindowsAreSettledAgainstTheSameLiveSessions() throws {
        let now = Date()
        let fixture = try resumedSession(now: now, silentFor: 30 * 86_400)
        let projects = [fixture.current, fixture.previous]

        let snapshot = DataSource.assemble(
            projects: projects,
            windows: [],
            sessions: [live("s1", startedIn: fixture.previous.path)],
            contested: narrow(fixture.contested,
                              since: now.addingTimeInterval(-UsageStore.windowSeconds)),
            hourlyContested: narrow(fixture.contested,
                                    since: now.addingTimeInterval(-UsageStore.hourWindowSeconds)),
            worktrees: DataSource.worktrees(of: projects),
            accessibilityTrusted: true)

        let current = try XCTUnwrap(snapshot.projects.first { $0.project?.path == fixture.current.path })
        XCTAssertNil(current.usage, "the week was settled without the live sessions")
        XCTAssertNil(current.hourlyUsage, "the hour was settled without the live sessions")
        XCTAssertEqual(snapshot.ambiguousUsageSessions, 1)
        XCTAssertEqual(snapshot.ambiguousHourlySessions, 1)
    }

    /// The worktree listing is the one piece of disk `assemble` cannot do for
    /// itself. A project with no `.claude/worktrees` must not appear in it at
    /// all — that guard is what keeps 96 failing `contentsOfDirectory` calls off
    /// a path that runs once a second.
    func testOnlyProjectsThatHaveWorktreesAreListed() throws {
        let bare = try makeProject("plain")
        let withTree = try makeProject("switcher", worktrees: ["usage-ui"])

        let found = DataSource.worktrees(of: [bare, withTree])
        XCTAssertNil(found[bare.path])
        XCTAssertEqual(found[withTree.path], [withTree.path + "/.claude/worktrees/usage-ui"])
    }
}

/// Folding per-session figures into per-directory and then per-project ones.
final class UsageJoinTests: XCTestCase {

    private func session(_ identifier: String, input: Int) throws -> GatewaySession {
        try UsageFixtures.decode("""
        {"session_id": "\(identifier)", "input_tokens": \(input), "output_tokens": 0,
         "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
        """, as: GatewaySession.self)
    }

    func testSessionsOfOneDirectoryAreSummed() throws {
        let folded = UsageIndex.fold(sessions: [try session("a", input: 10), try session("b", input: 5)],
                                     slugsBySessionId: ["a": ["-Users-x-project"], "b": ["-Users-x-project"]])
        XCTAssertEqual(folded.tokensBySlug["-Users-x-project"]?.input, 15)
        XCTAssertEqual(folded.unmatchedSessions, 0)
        XCTAssertEqual(folded.unmatched, .zero)
        XCTAssertTrue(folded.contested.isEmpty)
    }

    func testASessionWithNoLocalTranscriptIsUnmatchedRatherThanDropped() throws {
        let folded = UsageIndex.fold(sessions: [try session("a", input: 10), try session("node", input: 7)],
                                     slugsBySessionId: ["a": ["-Users-x-project"]])
        XCTAssertEqual(folded.tokensBySlug.count, 1)
        XCTAssertEqual(folded.unmatchedSessions, 1)
        XCTAssertEqual(folded.unmatched.input, 7)
    }

    /// A session found under two slugs is set aside whole rather than counted
    /// under either. The gateway reports one aggregate for the session and the
    /// fold has no project list to ask whether the two slugs mean two projects,
    /// so the question is passed on instead of being answered here.
    func testASessionUnderTwoSlugsIsSetAsideRatherThanCounted() throws {
        let folded = UsageIndex.fold(sessions: [try session("a", input: 10), try session("b", input: 5)],
                                     slugsBySessionId: ["a": ["-x-one", "-x-two"],
                                                        "b": ["-x-two"]])
        XCTAssertEqual(folded.tokensBySlug, ["-x-two": TokenCounts(input: 5, output: 0,
                                                                   cacheCreation: 0, cacheRead: 0)],
                       "only the session with one slug was folded")
        XCTAssertEqual(folded.contested, [ContestedSpend(sessionId: "a",
                                                         slugs: ["-x-one", "-x-two"],
                                                         tokens: try session("a", input: 10).tokens)])
        XCTAssertEqual(folded.unmatchedSessions, 0, "it has a transcript; whose is the open question")
    }

    func testAnUnnamedCounterSurvivesTheFold() throws {
        let partial = try UsageFixtures.decode("""
        {"session_id": "p", "input_tokens": 10, "output_tokens": null}
        """, as: GatewaySession.self)
        let folded = UsageIndex.fold(sessions: [try session("a", input: 1), partial],
                                     slugsBySessionId: ["a": ["-x"], "p": ["-x"]])
        XCTAssertEqual(folded.tokensBySlug["-x"]?.input, 11)
        XCTAssertEqual(folded.tokensBySlug["-x"]?.isComplete, false)
    }

    // MARK: - Attribution to rows

    private let projectPath = "/Users/x/Data/Projects/switcher"

    private func tokens(_ input: Int) -> TokenCounts {
        TokenCounts(input: input, output: 0, cacheCreation: 0, cacheRead: 0)
    }

    /// Keyed by directory here and slugged on the way in, exactly as Claude Code
    /// slugs it when it files a transcript. These tests are about which row the
    /// number lands on; that the slug of a directory on disk is the one the app
    /// computes is held by `UsageAttributionTests`, over real directories.
    private func assemble(spend: [String: TokenCounts],
                          hourly: [String: TokenCounts] = [:],
                          sessions: [ClaudeSessionInfo] = [],
                          windows: [VSCodeWindowInfo] = [],
                          worktrees: [String] = []) -> SwitcherSnapshot {
        DataSource.assemble(projects: [TestFixtures.project(path: projectPath, rootName: "switcher")],
                            windows: windows,
                            sessions: sessions,
                            tokensBySlug: Dictionary(uniqueKeysWithValues: spend.map {
                                (ClaudeSessions.slug(forPath: $0.key), $0.value)
                            }),
                            hourlyTokensBySlug: Dictionary(uniqueKeysWithValues: hourly.map {
                                (ClaudeSessions.slug(forPath: $0.key), $0.value)
                            }),
                            worktrees: worktrees.isEmpty ? [:] : [projectPath: worktrees],
                            accessibilityTrusted: true)
    }

    func testSpendInTheProjectDirectoryLandsOnItsRow() {
        let snapshot = assemble(spend: [projectPath: tokens(10)])
        let row = snapshot.projects.first { $0.project?.path == projectPath }
        XCTAssertEqual(row?.usage?.input, 10)
        XCTAssertEqual(row?.usageInputEquivalent, 10)
    }

    func testTheProjectAndItsWorktreesAddUp() {
        let one = projectPath + "/.claude/worktrees/one"
        let two = projectPath + "/.claude/worktrees/two"
        let snapshot = assemble(spend: [projectPath: tokens(10), one: tokens(7), two: tokens(3)],
                                worktrees: [one, two])
        let row = snapshot.projects.first { $0.project?.path == projectPath }
        XCTAssertEqual(row?.usage?.input, 20)
    }

    /// A subdirectory of a project is *not* the project, and this is a deliberate
    /// narrowing rather than an oversight.
    ///
    /// The old rule matched paths and so counted `<project>/macos` as the
    /// project's. The rule matches slugs now, and a slug has lost the
    /// separators: `-Users-x-Data-Projects-switcher-macos` is exactly what a
    /// project genuinely called `switcher-macos` would be filed under, and
    /// nothing can tell the two apart after the fact. Worktrees are the one
    /// exception, and only because they are *enumerated* — the app knows their
    /// real paths and slugs those.
    ///
    /// So such spend lands on no row, which is the honest outcome. On the live
    /// 7-day window it costs nothing: all 30 local sessions were filed under a
    /// project's own slug or a worktree's (measured 2026-08-17).
    func testSpendUnderASubdirectorySlugDoesNotReachTheProject() {
        let snapshot = assemble(spend: [projectPath + "/macos": tokens(3)])
        XCTAssertNil(snapshot.projects.first { $0.project?.path == projectPath }?.usage)
    }

    func testAWindowRowCarriesItsProjectsSpend() {
        let window = TestFixtures.window(index: 0, title: "topic \u{2014} switcher (Workspace)")
        let snapshot = assemble(spend: [projectPath: tokens(10)], windows: [window])
        XCTAssertEqual(snapshot.openWindows.first?.usage?.input, 10)
        XCTAssertTrue(snapshot.projects.isEmpty, "the project has a window, so it has no second row")
    }

    /// A directory outside every scan root has a row of its own as soon as an
    /// agent runs there, and that row keeps its own spend — found by slugging
    /// its own path, the same forward direction everything else uses.
    func testAnOrphanRowKeepsItsOwnSpend() {
        let snapshot = assemble(spend: [projectPath: tokens(10), "/tmp/scratch": tokens(4)],
                                sessions: [TestFixtures.session(id: "s1", cwd: "/tmp/scratch", state: .working)])
        let orphan = snapshot.projects.first { $0.id == "cwd:/tmp/scratch" }
        XCTAssertEqual(orphan?.usage?.input, 4)
        XCTAssertEqual(snapshot.projects.first { $0.project?.path == projectPath }?.usage?.input, 10)
    }

    func testARowWithNoSpendCarriesNoNumberRatherThanZero() {
        let snapshot = assemble(spend: [:])
        let row = snapshot.projects.first { $0.project?.path == projectPath }
        XCTAssertNil(row?.usage)
        XCTAssertNil(row?.usageInputEquivalent, "no figure at all is not a figure of zero")
    }

    /// Spend the gateway reports for a directory nobody has a row for is not
    /// invented into one: it stays in the snapshot's totals.
    func testSpendOutsideEveryRowDoesNotCreateARow() {
        let snapshot = assemble(spend: ["/tmp/finished-last-week": tokens(4)])
        XCTAssertNil(snapshot.projects.first { $0.id.hasPrefix("cwd:") })
    }

    /// Two windows on one project both carry the project's whole spend, and both
    /// carry the same number. The decision, not an accident: the figure belongs
    /// to the project. Sessions reach a window only through `distribute`, which
    /// matches the chat topic against a title prefix VSCode truncated and gives
    /// the rest to the frontmost window (SPEC §8), so a per-window share would
    /// be that guess with a number printed on it. Both rows are labelled with
    /// the project's name, so one figure twice reads correctly.
    ///
    /// The consequence worth naming: the rows of a snapshot no longer add up to
    /// its total once a project has two windows. That is why `--dump` prints the
    /// total and the rows and asserts nothing between them.
    func testBothWindowsOfOneProjectCarryTheSameSpend() {
        let first = TestFixtures.window(index: 0,
                                        title: "one thing \u{2014} switcher (Workspace)",
                                        windowNumber: 11)
        let second = TestFixtures.window(index: 1,
                                         title: "another \u{2014} switcher (Workspace)",
                                         windowNumber: 12)
        let snapshot = assemble(spend: [projectPath: tokens(10)], windows: [first, second])

        XCTAssertEqual(snapshot.openWindows.count, 2)
        XCTAssertEqual(snapshot.openWindows.map { $0.usage?.input }, [10, 10],
                       "the project's spend, whole, on each of its windows")
        XCTAssertEqual(snapshot.openWindows.compactMap(\.usageInputEquivalent), [10, 10])
    }

    // MARK: - The sliding hour, on the same rows

    /// The hour is spread over the projects by the very same rule as the week —
    /// the same slug map, the same function — so it lands on the same row, and a
    /// worktree's slug folds onto its project here too.
    ///
    /// Asked with *different* numbers in the two windows, because equal ones would
    /// pass with the row wired to either: what this holds is that the row carries
    /// both and does not confuse them.
    func testTheHourLandsOnTheSameRowTheWeekDoes() throws {
        let worktree = projectPath + "/.claude/worktrees/one"
        let snapshot = assemble(spend: [projectPath: tokens(10)],
                                hourly: [projectPath: tokens(3), worktree: tokens(4)],
                                worktrees: [worktree])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })

        XCTAssertEqual(row.usage?.input, 10, "the week is where it was")
        XCTAssertEqual(row.hourlyUsage?.input, 7, "the project's hour, plus its worktree's")
        XCTAssertEqual(row.hourlyInputEquivalent, 7)
    }

    /// A window row carries its project's hour, exactly as it carries its week.
    func testAWindowRowCarriesItsProjectsHour() throws {
        let window = TestFixtures.window(index: 0, title: "topic \u{2014} switcher (Workspace)")
        let snapshot = assemble(spend: [projectPath: tokens(10)],
                                hourly: [projectPath: tokens(3)],
                                windows: [window])
        let row = try XCTUnwrap(snapshot.openWindows.first)
        XCTAssertEqual(row.usage?.input, 10)
        XCTAssertEqual(row.hourlyUsage?.input, 3)
    }

    /// And so does an orphan `cwd:` row, keyed by its own directory's slug. This
    /// is where a live agent outside the scan roots shows up, so it is the last
    /// row that may be left without the figure that says it is working (§2.2.1).
    func testAnOrphanRowKeepsItsOwnHour() throws {
        let snapshot = assemble(spend: ["/tmp/scratch": tokens(9)],
                                hourly: ["/tmp/scratch": tokens(4)],
                                sessions: [TestFixtures.session(id: "s1", cwd: "/tmp/scratch",
                                                                state: .working)])
        let orphan = try XCTUnwrap(snapshot.projects.first { $0.id == "cwd:/tmp/scratch" })
        XCTAssertEqual(orphan.usage?.input, 9)
        XCTAssertEqual(orphan.hourlyUsage?.input, 4)
    }

    /// **The capped week.** The gateway keeps its 200 largest consumers over the
    /// week and drops the rest, so a session spending right now after a quiet week
    /// is in the hour's report and absent from the week's (§2.9). Its row still
    /// has to show the rate: that session is the very one the rate exists for.
    ///
    /// The fixture genuinely has no week figure for this project — the week's
    /// table is about another directory entirely — because a fixture that happened
    /// to carry one would prove nothing about the case.
    func testARowAbsentFromTheWeeksReportStillShowsItsHour() throws {
        let snapshot = assemble(spend: ["/tmp/somebody-else": tokens(500)],
                                hourly: [projectPath: tokens(6)])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })

        XCTAssertNil(row.usage, "the week's report does not mention this project at all")
        XCTAssertNil(row.usageInputEquivalent)
        XCTAssertEqual(row.hourlyUsage?.input, 6, "and the hour still reaches its row")
        XCTAssertEqual(SwitcherRowView.rateLabel(for: row), "6/h")
    }

    /// The mirror of `testARowWithNoSpendCarriesNoNumberRatherThanZero`: nothing
    /// reported for the hour is no figure, not a figure of zero.
    func testARowWithNoHourCarriesNoRateRatherThanZero() throws {
        let snapshot = assemble(spend: [projectPath: tokens(10)])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })
        XCTAssertNil(row.hourlyUsage)
        XCTAssertNil(row.hourlyInputEquivalent, "no figure at all is not a figure of zero")
        XCTAssertNil(SwitcherRowView.rateLabel(for: row))
        XCTAssertEqual(ConsoleDump.rateCell(for: row), "-")
    }

    /// The hour's lower bound is marked on both surfaces, on the same terms as the
    /// week's — and the week beside it stays exact, so neither mark can be the
    /// other's leaking through.
    func testAPartlyKnownHourIsMarkedAsALowerBound() throws {
        let partial = TokenCounts(input: 1000, output: nil, cacheCreation: nil, cacheRead: nil)
        let snapshot = assemble(spend: [projectPath: tokens(2000)], hourly: [projectPath: partial])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })

        XCTAssertTrue(row.hourlyIsLowerBound)
        XCTAssertEqual(SwitcherRowView.rateLabel(for: row), "≥1k/h")
        XCTAssertEqual(ConsoleDump.rateCell(for: row), ">=1k/h")
        XCTAssertFalse(row.usageIsLowerBound, "the week knows all four and says so")
        XCTAssertEqual(ConsoleDump.usageCell(for: row), "2k")
    }

    // MARK: - What is known, and what is only a lower bound

    /// The gateway named none of the four counters. `weighted()` folds every
    /// unnamed counter in as zero and so answers 0 — which is the sum of nothing
    /// known, not a spend of zero — and the flag that says so, `isComplete`, is
    /// gone the moment the number is taken out on its own. So the accessor the
    /// UI reads answers `nil` and the dump prints a dash.
    func testARowThatKnowsNothingShowsNoNumberRatherThanAConfidentZero() throws {
        let unnamed = TokenCounts(input: nil, output: nil, cacheCreation: nil, cacheRead: nil)
        let snapshot = assemble(spend: [projectPath: unnamed])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })

        XCTAssertNotNil(row.usage, "the gateway did report for this directory")
        XCTAssertEqual(row.usage?.weighted(), 0, "and the arithmetic still answers zero")
        XCTAssertNil(row.usageInputEquivalent, "which is not a number anybody may be shown")
        XCTAssertFalse(row.usageIsLowerBound, "there is no number for a bound to be under")
        XCTAssertEqual(ConsoleDump.usageCell(for: row), "-")
    }

    /// Part of the four named: the number is real and partial, so it is shown
    /// with the mark that says it is a floor.
    func testAPartlyKnownRowIsANumberMarkedAsALowerBound() throws {
        let partial = TokenCounts(input: 1000, output: nil, cacheCreation: nil, cacheRead: nil)
        let snapshot = assemble(spend: [projectPath: partial])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })

        XCTAssertEqual(row.usageInputEquivalent, 1000)
        XCTAssertTrue(row.usageIsLowerBound)
        XCTAssertEqual(ConsoleDump.usageCell(for: row), ">=1k")
    }

    func testACompletelyKnownRowIsANumberWithoutTheMark() throws {
        let snapshot = assemble(spend: [projectPath: tokens(1000)])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })
        XCTAssertFalse(row.usageIsLowerBound)
        XCTAssertEqual(ConsoleDump.usageCell(for: row), "1k")
    }

    /// The mark has to appear in both sections of the dump. The windows section
    /// prints the four counters, the projects section prints the one number, and
    /// the two columns are read against each other: a lower bound that looks
    /// exact in one of them is worse than in neither.
    func testBothDumpSectionsMarkALowerBound() throws {
        let partial = TokenCounts(input: 1000, output: nil, cacheCreation: nil, cacheRead: nil)
        let window = TestFixtures.window(index: 0, title: "topic \u{2014} switcher (Workspace)")

        let withWindow = assemble(spend: [projectPath: partial], windows: [window])
        let windowRow = try XCTUnwrap(withWindow.openWindows.first)
        XCTAssertTrue(ConsoleDump.formatTokens(try XCTUnwrap(windowRow.usage)).hasPrefix(">="),
                      "windows section")

        let withoutWindow = assemble(spend: [projectPath: partial])
        let projectRow = try XCTUnwrap(withoutWindow.projects.first { $0.project?.path == projectPath })
        XCTAssertTrue(ConsoleDump.usageCell(for: projectRow).hasPrefix(">="), "projects section")
    }

    /// Counters that name nothing print as a dash there too. `0 ie (in ?, out ?,
    /// cw ?, cr ?)` is the same confident zero, and the line it turns up on is
    /// `no local session: 0 sessions` — where it contradicts the count standing
    /// next to it.
    func testCountersThatNameNothingPrintAsADash() {
        XCTAssertEqual(ConsoleDump.formatTokens(.zero), "-")
        XCTAssertEqual(ConsoleDump.formatTokens(TokenCounts(input: nil, output: nil,
                                                            cacheCreation: nil, cacheRead: nil)), "-")
        XCTAssertEqual(ConsoleDump.formatTokens(TokenCounts(input: 0, output: 0,
                                                            cacheCreation: 0, cacheRead: 0)),
                       "0 ie (in 0, out 0, cw 0, cr 0)",
                       "a measured zero is a number and stays one")
    }
}

/// Which project a working directory belongs to — the rule both loops of
/// `assemble` route through, the gateway's directories and the live sessions
/// alike. It lives in this file because attributing spend is what made it
/// load-bearing a second time.
///
/// Asked of `DataSource.project(for:in:prefixes:)` directly rather than through
/// `assemble`: the matching is what has to be pinned down, and through the
/// assembly every case needs a fixture of several projects and comes back as a
/// figure missing from a row rather than as the wrong match. The suite exists
/// because none of this was held by anything — deleting the `+ "/"` that
/// `prefixes(of:)` is entirely made of left the whole suite green.
final class ProjectMatchingTests: XCTestCase {

    private func match(_ cwd: String, in paths: [String]) -> String? {
        let projects = paths.map {
            TestFixtures.project(path: $0, rootName: ($0 as NSString).lastPathComponent)
        }
        return DataSource.project(for: cwd,
                                  in: projects,
                                  prefixes: DataSource.prefixes(of: projects))?.path
    }

    /// A path that merely *starts* with a project's path is not inside it. This
    /// is the separator's whole job, and the machine has the pairs that make it
    /// cost something: `asakusa_lab` beside `asakusa_lab_glaze_resolver`,
    /// `portainer` beside `portainer-agent`. Without it the younger project's
    /// entire spend, and every session running in it, is attributed to the older
    /// project's row.
    ///
    /// Checked by deleting the `+ "/"`: this test is the only one that fails,
    /// every other test in the suite passes (re-checked 2026-08-17, when the
    /// suite was 409 tests: three assertions here, 408 others green).
    /// Note which assertions do the work — three of the five below, and the two
    /// that stay green stay green for two different reasons. The one with both
    /// projects in the list is green either way because the deeper prefix wins
    /// the sibling back; the control is green either way because it is genuine
    /// containment, which matches with the separator and without it. The
    /// separator only shows up when the sibling is not in the list.
    func testASiblingWhoseNameStartsWithAnothersIsNotInsideIt() {
        XCTAssertNil(match("/a/bc", in: ["/a/b"]),
                     "half a path component is not containment")
        XCTAssertNil(match("/a/bc/src", in: ["/a/b"]),
                     "and neither is anything below it")
        XCTAssertEqual(match("/a/b/src", in: ["/a/b"]), "/a/b",
                       "the control: the same shape one separator over")

        // The live pair, in the shape it has on disk, both alone and together.
        XCTAssertNil(match("/Users/x/Projects/portainer-agent", in: ["/Users/x/Projects/portainer"]))
        XCTAssertEqual(match("/Users/x/Projects/portainer-agent/src",
                             in: ["/Users/x/Projects/portainer", "/Users/x/Projects/portainer-agent"]),
                       "/Users/x/Projects/portainer-agent",
                       "the spend of the agent stays on the agent's row")
    }

    /// An exact match beats a project the path merely sits inside — and does so
    /// whichever order the two arrive in. The walk returns the moment it sees
    /// the exact match and keeps the deepest prefix as a running maximum, so
    /// meeting the container first must not change the answer.
    ///
    /// That the exact branch exists at all is covered everywhere (deleting it
    /// fails 28 tests). What only this holds is which of the two wins when both
    /// are there: letting the deepest prefix win instead — the exact match
    /// remembered and used only as a fallback — fails this test and nothing
    /// else.
    func testAnExactMatchWinsOverAProjectThatContainsIt() {
        XCTAssertEqual(match("/a/b/c", in: ["/a/b", "/a/b/c"]), "/a/b/c", "container first")
        XCTAssertEqual(match("/a/b/c", in: ["/a/b/c", "/a/b"]), "/a/b/c", "exact first")
    }

    /// Of several projects a directory sits inside, the deepest one takes it —
    /// again in both orders, because the maximum is running and the tie rule is
    /// "the first one wins".
    ///
    /// Checked by keeping the first containing project instead of the deepest:
    /// this test is the only one that fails, every other test in the suite
    /// passes (re-checked 2026-08-17, when the suite was 409 tests: this one,
    /// 408 others green) — and only the `shallow first`
    /// half of it fails, since with the deep project first the broken rule
    /// happens to answer correctly. Which is the whole reason for asking both
    /// orders.
    func testTheDeepestContainingProjectWins() {
        XCTAssertEqual(match("/a/b/c/d", in: ["/a", "/a/b"]), "/a/b", "shallow first")
        XCTAssertEqual(match("/a/b/c/d", in: ["/a/b", "/a"]), "/a/b", "deep first")
    }
}

/// The one wire from the gateway poll into the panel.
final class UsageWiringTests: XCTestCase {

    /// `DataSource.build()` reads `UsageCache` and hands the numbers to
    /// `assemble`. That single argument is the whole feature: removing it leaves
    /// every other test in this file green, because they all call `assemble`
    /// directly and pass the spend in themselves.
    ///
    /// So this one goes the way the app does — a real `DataSource` over a real
    /// scan root, with the cache filled the way a finished poll fills it.
    func testTheSnapshotCarriesWhatThePollLeftInTheCache() throws {
        let root = try makeTemporaryDirectory()
        let project = root.appendingPathComponent("switcher")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)

        let cache = UsageCache()
        var polled = UsageSnapshot.empty
        polled.tokensBySlug = [ClaudeSessions.slug(forPath: project.path): TokenCounts(input: 10, output: 2,
                                                        cacheCreation: 0, cacheRead: 0)]
        cache.store(polled)

        var config = Config.default
        config.projectRoots = [root.path]
        config.scanDepth = 1
        // No application answers to this identifier, so the window list comes
        // back empty and the run needs no Accessibility grant — the same trick
        // `--no-windows` uses.
        config.editorBundleID = "xyz.vvzvlad.vscode-switcher.no-such-editor"

        let snapshot = DataSource(config: config, usage: cache).snapshot()
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == project.path },
                                "the scan should have found the project")
        XCTAssertEqual(row.usage?.input, 10)
        XCTAssertEqual(row.usageInputEquivalent, 20, "10 input plus 2 output at five times input")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.standardizedFileURL
    }
}

/// The pass itself: what it keeps when the gateway is not there, and where it
/// runs.
final class UsageStoreTests: XCTestCase {

    /// Answers the three endpoints from the fixtures, or fails whichever of them
    /// is handed `nil`.
    ///
    /// The history is checked for first, because its path (`/gw/usage/acc2/
    /// history`) begins with the quota endpoint's and would otherwise be served
    /// the quota body — which decodes into nothing and would look like a
    /// malformed gateway rather than a test that misrouted itself.
    /// - Parameters:
    ///   - sessionsBySince: a body for one particular `/gw/sessions` window,
    ///     keyed by the `since` it asks for. The pass makes two calls to that one
    ///     path — the week's and the sliding hour's — so a test that needs to
    ///     tell them apart has to answer them apart; anything not named here
    ///     falls back to `sessions`. (It was three while the histories half
    ///     priced a percentage point in tokens; that request is gone.)
    ///   - unreachableSince: the windows that fail instead of answering, same key.
    ///     Failing *one* window is the only way to ask whether the blame names it.
    private func transport(usage: String? = UsageFixtures.usage,
                           sessions: String? = "{\"since\": 1786761516, \"sessions\": []}",
                           sessionsBySince: [Int: String] = [:],
                           unreachableSince: Set<Int> = [],
                           history: String? = UsageStoreTests.risingHistory,
                           historyByLabel: [String: String] = [:],
                           status: Int = 200,
                           log: RequestLog? = nil) -> UsageClient.Transport {
        { request in
            let path = request.url?.path ?? ""
            log?.record(request.url)
            let body: String?
            if path.hasSuffix("/history") {
                // `/gw/usage/<label>/history`, so the label is the component
                // before the last one — which is what lets a fixture give two
                // accounts two different series.
                let label = request.url?.pathComponents.dropLast().last ?? ""
                body = historyByLabel[label] ?? history
            } else if path.hasSuffix("/sessions") {
                let since = request.url.flatMap {
                    URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "since" }?.value
                }.flatMap(Int.init)
                if let since, unreachableSince.contains(since) {
                    throw UsageError.unreachable("nothing listening")
                }
                body = since.flatMap { sessionsBySince[$0] } ?? sessions
            } else {
                body = usage
            }
            guard let body else { throw UsageError.unreachable("nothing listening") }
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            guard let response = HTTPURLResponse(url: url, statusCode: status,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(body.utf8), response)
        }
    }

    /// One account's series as the gateway sends it, `readings` spread evenly
    /// over `overHours`.
    private static func historySeries(label: String = "acc2",
                                      readings: [Double],
                                      overHours: Double = 48) -> String {
        let start = 1_786_700_000.0
        let step = readings.count > 1 ? overHours * 3600 / Double(readings.count - 1) : 0
        let points = readings.enumerated().map { index, value in
            "{\"ts\": \(start + Double(index) * step), \"util_7d\": \(value)}"
        }
        return "{\"label\": \"\(label)\", \"since\": \(start), "
            + "\"points\": [\(points.joined(separator: ","))]}"
    }

    /// The default history: acc2 burning 50 pp over 48 h, which is 175 pp of a
    /// week against the 100 pp one account is worth — 175%, and not a lower
    /// bound, so every field of the answer is distinguishable from a default.
    private static let risingHistory = historySeries(readings: [0, 25, 50])

    private func client(_ transport: @escaping UsageClient.Transport) -> UsageClient {
        UsageClient(baseURL: Config.default.resolvedUsageBaseURL, transport: transport)
    }

    /// A window's worth of spending, for the passes that need the sessions half
    /// to carry something rather than an empty list. One session, and its
    /// counters weigh 65.6M input-equivalent:
    /// `50 + 5 x 24264 + 1.25 x 41120 + 0.1 x 654_181_300`.
    ///
    /// It used to be load-bearing on the *histories* half: that half asked its
    /// own `/gw/sessions` to price a percentage point in tokens, and this body
    /// was the numerator of the price. Both sides of the figure are percentage
    /// points now, so this is fixture furniture again.
    private static let spendingSessions = """
    {"since": 1786761516, "sessions": [
      {"session_id": "s-1", "input_tokens": 50, "output_tokens": 24264,
       "cache_creation_input_tokens": 41120, "cache_read_input_tokens": 654181300}]}
    """

    /// **The histories half asks one endpoint, and `/gw/sessions` is not it.**
    ///
    /// It used to ask two. The figure was a token rate over a token allowance,
    /// and the allowance was priced by dividing a window's tokens by that same
    /// window's percentage points — so the half asked `/gw/sessions` with the
    /// `since` it asked the histories with, because a ratio of two different
    /// windows is the price of nothing. Both sides of the figure are percentage
    /// points now, so there is nothing left to convert: the second request is
    /// gone and the half is a plain `do`/`catch`.
    ///
    /// What is asked of `/gw/sessions` is therefore exactly the panel's own two
    /// windows — the week and the sliding hour — and neither of them may drift
    /// onto the histories' 48 h. Driven from a real pass rather than from the
    /// constants, because the mistake this catches is a *caller* that kept the
    /// old request: counting the calls is the only way to see one that answers
    /// harmlessly and costs 43 KB every ten minutes.
    func testTheHistoriesHalfAsksNoSessionQuestionOfItsOwn() async {
        let log = RequestLog()
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        _ = await UsageStore.poll(client: client(transport(usage: UsageFixtures.usageWithTokens,
                                                           sessions: Self.spendingSessions,
                                                           log: log)),
                                  previous: .empty, now: now)

        let histories = log.windows(of: "/history")
        let sessions = log.windows(of: "/sessions")
        XCTAssertEqual(histories.count, 1, "the histories are asked for once and over one window")
        XCTAssertEqual(Set(sessions), [now.timeIntervalSince1970 - UsageStore.windowSeconds,
                                       now.timeIntervalSince1970 - UsageStore.hourWindowSeconds],
                       "the two windows the panel's own figures are counted over moved")
        XCTAssertEqual(sessions.count, 2, """
            the pass made a third call to /gw/sessions: the histories half is asking a question \
            of its own again, and nothing reads its answer
            """)
        XCTAssertFalse(sessions.contains(histories[0]), """
            a session report was asked for over the histories' own window, which is the request \
            that priced a point in tokens and has no reader left
            """)
    }

    /// A good pass produces both readings the surfaces print, and the second one
    /// is the arithmetic `FleetCapacity.burnAgainstRefill` was tested on.
    ///
    /// `usageWithTokens` names one account, `acc2`, and `risingHistory` is its
    /// series: 50 pp burned over 48 h, which is 1.0417 pp/h. One contributor
    /// refills 100 pp over 168 h, which is 0.5952 pp/h. 175%, and it is over the
    /// refill rate — the state the menu bar colours for.
    func testAGoodPassProducesBothOfTheHeadlineReadings() async {
        let snapshot = await UsageStore.poll(
            client: client(transport(usage: UsageFixtures.usageWithTokens,
                                     sessions: Self.spendingSessions)),
            previous: .empty, now: Date())

        XCTAssertEqual(snapshot.fleetTokenRate ?? 0, 28_940_459.22, accuracy: 0.01,
                       "the live rate is the gateway's own, weighted and carried to the hour")
        let burn = try? XCTUnwrap(snapshot.fleetBurn)
        XCTAssertEqual(burn?.percent ?? 0, 175, accuracy: 0.01)
        XCTAssertEqual(burn?.burnRate ?? 0, 50.0 / 48, accuracy: 0.0001)
        XCTAssertEqual(burn?.refillRate ?? 0, 100.0 / 168, accuracy: 0.0001,
                       "one contributor refills one account's week and no more")
        XCTAssertEqual(burn?.accounts, 1)
        XCTAssertEqual(burn?.measuredHours ?? 0, 48, accuracy: 0.01)
        XCTAssertEqual(burn?.isLowerBound, false, "nothing in the series touched a ceiling")
    }

    /// The half's blame names the endpoint it asked, because a half that fails
    /// without saying where is a half nobody can debug (§4).
    ///
    /// **One endpoint to name, and that is the change.** While two requests made
    /// up this half they went to two different paths, an `Attempt` pair told them
    /// apart, and this test asked that `/gw/sessions` failing be blamed on
    /// `/gw/sessions` rather than on the histories. With the second request gone
    /// the question left is the other half of the same rule: the histories
    /// failing must not reach the *sessions* half's blame, which is a separate
    /// field with its own window in it.
    func testTheHistoriesHalfIsBlamedByItsOwnName() async {
        let noHistory = await UsageStore.poll(
            client: client(transport(usage: UsageFixtures.usageWithTokens,
                                     sessions: Self.spendingSessions, history: nil)),
            previous: .empty, now: Date())
        XCTAssertEqual(noHistory.historiesFailure?.contains("/gw/usage/<label>/history"), true)
        XCTAssertNil(noHistory.sessionsFailure, "the week's own half answered and is not to blame")
        XCTAssertNil(noHistory.quotaFailure)

        // And the other way round: the sessions half failing leaves the histories
        // half alone, figure and all. They share an endpoint no longer, so there
        // is nothing to confuse — which is the claim being pinned.
        let noSessions = await UsageStore.poll(
            client: client(transport(usage: UsageFixtures.usageWithTokens, sessions: nil)),
            previous: .empty, now: Date())
        XCTAssertNil(noSessions.historiesFailure,
                     "the histories answered: blaming them would send the reader to the wrong place")
        XCTAssertEqual(noSessions.fleetBurn?.percent ?? 0, 175, accuracy: 0.01,
                       "the figure the histories did answer was thrown away with the other half")
        XCTAssertEqual(noSessions.sessionsFailure?.contains("/gw/sessions"), true)
    }

    func testAGoodPassFillsInEverythingAndReportsNoFailure() async {
        let now = Date()
        let snapshot = await UsageStore.poll(client: client(transport()), previous: .empty, now: now)
        XCTAssertNil(snapshot.failureText)
        XCTAssertEqual(snapshot.since, Date(timeIntervalSince1970: 1_786_761_516))
        XCTAssertEqual(snapshot.fleetSevenDayMean, 58.667)
        XCTAssertEqual(snapshot.accounts.map(\.label), ["acc2"])
        XCTAssertEqual(snapshot.quotaFetchedAt, now)
    }

    /// A gateway that is not there is ordinary: the numbers from the pass before
    /// stay put and only the blame changes. Blinking to blank would be worse.
    ///
    /// And the stamp stays with the numbers it belongs to. Moving it along with
    /// the attempt is what had the popover describing hour-old figures as
    /// fetched a moment ago, with the reason they were not standing right
    /// underneath. The pass keeps no stamp of the attempt at all any more: what
    /// says a failed pass ran are the numbers it left standing and the blame it
    /// wrote, both of them here.
    func testAFailedPassKeepsThePreviousNumbersAndTheirStamps() async {
        let earlier = Date(timeIntervalSince1970: 1_786_700_000)
        var previous = UsageSnapshot.empty
        previous.tokensBySlug = ["-x": TokenCounts(input: 1, output: 2, cacheCreation: 3, cacheRead: 4)]
        previous.fleetSevenDayMean = 42
        previous.quotaFetchedAt = earlier

        let now = Date()
        let snapshot = await UsageStore.poll(client: client(transport(usage: nil, sessions: nil)),
                                             previous: previous,
                                             now: now)
        XCTAssertEqual(snapshot.tokensBySlug, previous.tokensBySlug)
        XCTAssertEqual(snapshot.fleetSevenDayMean, 42)
        XCTAssertEqual(snapshot.quotaFailure?.contains("/gw/usage"), true)
        XCTAssertEqual(snapshot.sessionsFailure?.contains("/gw/sessions"), true)
        XCTAssertEqual(snapshot.quotaFetchedAt, earlier, "the figures did not change hands")
    }

    /// The two halves fail separately, so one arriving must not be held back by
    /// the other — and neither may the other's stamp or the other's blame.
    func testOneHalfCanArriveWithoutTheOther() async {
        let earlier = Date(timeIntervalSince1970: 1_786_700_000)
        var previous = UsageSnapshot.empty
        previous.quotaFetchedAt = earlier
        let now = Date()

        let snapshot = await UsageStore.poll(client: client(transport(usage: nil)),
                                             previous: previous, now: now)
        XCTAssertEqual(snapshot.quotaFailure?.contains("/gw/usage"), true)
        XCTAssertNil(snapshot.sessionsFailure)
        XCTAssertEqual(snapshot.since, Date(timeIntervalSince1970: 1_786_761_516))
        XCTAssertEqual(snapshot.quotaFetchedAt, earlier)
    }

    /// And a half that comes back after a failure clears its own blame without
    /// touching the other's: two passes, the first with nothing listening, the
    /// second with the quota endpoint answering again.
    func testAHalfThatRecoversClearsOnlyItsOwnBlame() async {
        let first = await UsageStore.poll(client: client(transport(usage: nil, sessions: nil)),
                                          previous: .empty)
        XCTAssertNotNil(first.quotaFailure)
        XCTAssertNotNil(first.sessionsFailure)

        let second = await UsageStore.poll(client: client(transport(sessions: nil)), previous: first)
        XCTAssertNil(second.quotaFailure, "the quota half answered and is still blamed")
        XCTAssertNotNil(second.sessionsFailure, "the sessions half still is not answering")
        XCTAssertNotNil(second.quotaFetchedAt)
    }

    /// The bridge `--dump` uses, against a port nothing listens on: a gateway
    /// that is not there has to come back as a line to print, not as a dump that
    /// never returns and not as a crash.
    ///
    /// What it asserts is as important as that it passes. "There is a failure,
    /// no numbers and no fleet mean" is *also* what the 20-second watchdog
    /// returns, so a test that stops there passes just as happily over a pass
    /// that deadlocked on the main actor — checked by removing `nonisolated`
    /// from `UsageStore.windowSeconds`, where it went green in 20.005 s. So the
    /// failure has to name the endpoints that could not be reached, and the
    /// whole thing has to be over long before the watchdog: two refused
    /// connections are immediate, and even two full client timeouts would be
    /// ten seconds.
    func testTheSynchronousPassSurvivesAGatewayThatIsNotThere() throws {
        var config = Config.default
        config.usageBaseURL = "http://127.0.0.1:1"

        let started = Date()
        let snapshot = UsageStore.pollOnce(config: config)
        let elapsed = Date().timeIntervalSince(started)

        let failure = try XCTUnwrap(snapshot.failureText)
        XCTAssertTrue(failure.contains("/gw/usage: unreachable"), "got \(failure)")
        // Both session windows, each named: with a gateway that is not there they
        // fail together, and a line naming only one of them would read as though
        // the other had answered.
        XCTAssertTrue(failure.contains("/gw/sessions?since=-168h: unreachable"), "got \(failure)")
        XCTAssertTrue(failure.contains("/gw/sessions?since=-1h: unreachable"), "got \(failure)")
        XCTAssertLessThan(elapsed, 5,
                          "a refused connection is immediate; this waited like a pass that hung")
        XCTAssertTrue(snapshot.tokensBySlug.isEmpty)
        XCTAssertTrue(snapshot.hourlyTokensBySlug.isEmpty)
        XCTAssertNil(snapshot.fleetSevenDayMean)
    }

    /// The pass must not need the main thread — §6, and more immediately: the
    /// synchronous bridge `--dump` uses blocks the main thread while it waits.
    ///
    /// This deadlocked in exactly one way, and the way is not obvious: reading a
    /// `static let` declared on the `@MainActor` store made the compiler insert
    /// a hop to the main actor, silently and with no diagnostic under
    /// `-strict-concurrency=complete`, and everything after that read ran on the
    /// main thread. A timed wait rather than an open one so the regression is a
    /// failure and not a hung test run.
    func testPollDoesNotNeedTheMainThread() {
        let client = client(transport())
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await UsageStore.poll(client: client, previous: .empty)
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success,
                       "the pass waited for a main thread that is standing right here")
    }

    // MARK: - The sliding hour

    private func makeProjectsDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-hour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A transcript filed under the slug of `directory`, where Claude Code files
    /// one. Never opened — the slug of the directory is the whole signal, and
    /// `writtenAt` is the one thing about the file itself that anything reads.
    private func file(_ sessionId: String,
                      under directory: String,
                      in root: URL,
                      writtenAt: Date? = nil) throws {
        let slug = root.appendingPathComponent(ClaudeSessions.slug(forPath: directory))
        try FileManager.default.createDirectory(at: slug, withIntermediateDirectories: true)
        let transcript = slug.appendingPathComponent("\(sessionId).jsonl")
        try Data("not json at all".utf8).write(to: transcript)
        if let writtenAt {
            try FileManager.default.setAttributes([.modificationDate: writtenAt],
                                                  ofItemAtPath: transcript.path)
        }
    }

    /// A `/gw/sessions` body naming the given sessions, each with `input` input
    /// tokens and nothing else — so a figure that arrives is traceable to the
    /// window that carried it.
    private static func sessionsBody(_ sessionIds: [String], input: Int) -> String {
        let items = sessionIds.map {
            "{\"session_id\": \"\($0)\", \"input_tokens\": \(input), \"output_tokens\": 0, "
                + "\"cache_creation_input_tokens\": 0, \"cache_read_input_tokens\": 0}"
        }
        return "{\"since\": 1786761516, \"sessions\": [\(items.joined(separator: ","))]}"
    }

    /// **The hour is asked for as an hour, and that length is the figure's entire
    /// claim to being a rate.**
    ///
    /// The gateway's aggregates are windowed — measured, §2.9 — so the spend it
    /// reports for the last 3600 s already *is* tokens per hour, and no code
    /// anywhere divides it by anything. Which is exactly why the constant needs
    /// holding: at two hours the row would print twice the rate under the same
    /// label, and every test of the arithmetic would stay green, there being no
    /// arithmetic to fail. So the value is asserted with the reasoning beside it —
    /// the pattern `historyWindowSeconds` already uses for a bound no fixture can
    /// be walked to.
    ///
    /// Two halves that *are* walkable stand next to it. The request must actually
    /// go out over this window, and the hour and the week must stay two different
    /// questions: collapse them and the pass pays twice for one body while the
    /// "rate" silently becomes the week's total.
    func testTheHourlyFigureIsAskedOverExactlyOneSlidingHour() async {
        let log = RequestLog()
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        _ = await UsageStore.poll(client: client(transport(log: log)), previous: .empty, now: now)

        let windows = log.windows(of: "/sessions")
        XCTAssertTrue(windows.contains(now.timeIntervalSince1970 - UsageStore.hourWindowSeconds),
                      "no call asked for the sliding hour; the pass asked for \(windows)")
        XCTAssertEqual(Set(windows).count, 2, """
            the pass asks /gw/sessions over two windows — the week's and the hour's — and they \
            collapsed into one, so some figure is now counted over a window that is not its \
            own: got \(windows)
            """)
        XCTAssertEqual(UsageStore.hourWindowSeconds, 3600, """
            one hour exactly. The row prints the spend inside this window as tokens per hour \
            with no division anywhere, so any other value relabels the figure rather than \
            rescaling it. Move it and the docblock above says what else has to move
            """)
        XCTAssertLessThan(UsageStore.hourWindowSeconds, UsageStore.windowSeconds,
                          "the rate and the total became one question over one window")
    }

    /// **Both reports resolve their slugs through one union of identifiers.**
    ///
    /// `slugsBySessionId` walks every slug directory under `~/.claude/projects`
    /// and is the expensive part of the pass (§6), so it runs once — and once
    /// means the identifiers of *both* reports have to go into it.
    ///
    /// The week's list alone will not do, and the reason is not caution: the
    /// gateway keeps the 200 largest consumers and drops the rest, so a session
    /// that has spent little across the week but is burning right now can be in
    /// the hour's report and missing from the week's. Fold the hour against a map
    /// built from the week's identifiers and that session — the live one, the only
    /// kind this figure exists to show — is filed as spend with no owner.
    ///
    /// The fixture puts each window's session in a different project, so the two
    /// folds cannot borrow each other's answer: the mutation "resolve the week's
    /// identifiers only" empties the hourly map outright.
    func testBothWindowsFoldTheirSlugsThroughOneUnionOfIdentifiers() async throws {
        let root = try makeProjectsDirectory()
        try file("s-week", under: "/Users/x/slow", in: root)
        try file("s-hour", under: "/Users/x/busy", in: root)

        let now = Date(timeIntervalSince1970: 1_786_800_000)
        let weekSince = Int(now.timeIntervalSince1970 - UsageStore.windowSeconds)
        let hourSince = Int(now.timeIntervalSince1970 - UsageStore.hourWindowSeconds)

        let snapshot = await UsageStore.poll(
            client: client(transport(sessionsBySince: [
                weekSince: Self.sessionsBody(["s-week"], input: 11),
                hourSince: Self.sessionsBody(["s-hour"], input: 7)])),
            previous: .empty, now: now, projectsDirectory: root)

        XCTAssertEqual(snapshot.tokensBySlug["-Users-x-slow"]?.input, 11,
                       "the week's own fold stopped working")
        XCTAssertEqual(snapshot.hourlyTokensBySlug["-Users-x-busy"]?.input, 7, """
            the hour's session resolved to no slug at all, which is what a map built from the \
            week's identifiers alone does to a session the week's 200-session cap left out
            """)
        XCTAssertEqual(snapshot.unmatchedSessions, 0,
                       "a session with a transcript right here was called ownerless")
    }

    /// One window failing leaves the other's figure standing, and the blame names
    /// which window was lost.
    ///
    /// **Deliberately not the rule the histories half used to follow.** There, one
    /// lost request took both figures with it, because the two were halves of one
    /// ratio — a token rate over a token allowance — and a ratio of one half is
    /// nothing. That pair is gone (both sides of the figure are percentage points
    /// now), and this one was never it: these are two independent answers to the
    /// same question over two windows, so throwing away a week's spend because the
    /// hour timed out would delete a figure for no reason at all.
    ///
    /// And both calls go to `/gw/sessions`, so the path names neither — a half
    /// that fails without saying which request is a half nobody can debug (§4).
    /// This is the last pair of that shape in the pass.
    /// Each direction is checked for the blame it should carry *and* for the blame
    /// it should not: naming the window that answered sends the reader to the
    /// wrong request, which is the whole failure this guards.
    func testOneWindowFailingLeavesTheOtherStandingAndIsBlamedByName() async throws {
        let root = try makeProjectsDirectory()
        try file("s-week", under: "/Users/x/slow", in: root)
        try file("s-hour", under: "/Users/x/busy", in: root)

        let now = Date(timeIntervalSince1970: 1_786_800_000)
        let weekSince = Int(now.timeIntervalSince1970 - UsageStore.windowSeconds)
        let hourSince = Int(now.timeIntervalSince1970 - UsageStore.hourWindowSeconds)
        let bodies = [weekSince: Self.sessionsBody(["s-week"], input: 11),
                      hourSince: Self.sessionsBody(["s-hour"], input: 7)]

        let lostHour = await UsageStore.poll(
            client: client(transport(sessionsBySince: bodies, unreachableSince: [hourSince])),
            previous: .empty, now: now, projectsDirectory: root)
        XCTAssertEqual(lostHour.tokensBySlug["-Users-x-slow"]?.input, 11,
                       "the week answered and was discarded along with the hour")
        XCTAssertTrue(lostHour.hourlyTokensBySlug.isEmpty,
                      "a window that never answered left a figure behind")
        XCTAssertEqual(lostHour.sessionsFailure?.contains("since=-1h"), true,
                       "got \(lostHour.sessionsFailure ?? "no blame at all")")
        XCTAssertEqual(lostHour.sessionsFailure?.contains("-168h"), false,
                       "the week answered; naming it sends the reader to the wrong request")

        let lostWeek = await UsageStore.poll(
            client: client(transport(sessionsBySince: bodies, unreachableSince: [weekSince])),
            previous: .empty, now: now, projectsDirectory: root)
        XCTAssertEqual(lostWeek.hourlyTokensBySlug["-Users-x-busy"]?.input, 7,
                       "the hour answered and was discarded along with the week")
        XCTAssertTrue(lostWeek.tokensBySlug.isEmpty,
                      "a window that never answered left a figure behind")
        XCTAssertEqual(lostWeek.sessionsFailure?.contains("-168h"), true,
                       "got \(lostWeek.sessionsFailure ?? "no blame at all")")
        XCTAssertEqual(lostWeek.sessionsFailure?.contains("since=-1h"), false,
                       "the hour answered; naming it sends the reader to the wrong request")
    }

    /// The hour is folded by the same `fold` as the week, so a session resumed in
    /// another directory is set aside in both and counted in neither.
    ///
    /// A second policy for "whose spend is this" would put two answers to one
    /// question in one snapshot. The cost of having no policy at all is worse than
    /// it looks: dropping the hour's contested sessions would leave a project
    /// being worked in *right now* reading as idle, for the single reason that its
    /// chat was once resumed somewhere else.
    func testTheHourSetsAsideAContestedSessionExactlyAsTheWeekDoes() async throws {
        let root = try makeProjectsDirectory()
        try file("s-both", under: "/Users/x/one", in: root)
        try file("s-both", under: "/Users/x/two", in: root)

        let now = Date(timeIntervalSince1970: 1_786_800_000)
        let hourSince = Int(now.timeIntervalSince1970 - UsageStore.hourWindowSeconds)
        let snapshot = await UsageStore.poll(
            client: client(transport(sessions: Self.sessionsBody(["s-both"], input: 9),
                                     sessionsBySince: [
                                        hourSince: Self.sessionsBody(["s-both"], input: 4)])),
            previous: .empty, now: now, projectsDirectory: root)

        XCTAssertEqual(snapshot.contested.map(\.slugs), [["-Users-x-one", "-Users-x-two"]])
        XCTAssertEqual(snapshot.hourlyContested.map(\.slugs), [["-Users-x-one", "-Users-x-two"]],
                       "the hour dropped a contested session the week kept")
        XCTAssertEqual(snapshot.hourlyContested.first?.tokens.input, 4,
                       "the hour's contested spend came from the week's body")
        XCTAssertTrue(snapshot.hourlyTokensBySlug.isEmpty,
                      "a contested session was counted onto a row after all")
    }

    /// **Each window narrows a contested session against its own length.**
    ///
    /// One session, two copies, and the second copy last written three days ago:
    /// inside the week, days outside the hour. So the week keeps both claims — over
    /// seven days the gateway's single aggregate really does hold spend from both
    /// lives — and the hour keeps one, because a file nothing has touched since
    /// Tuesday cannot have spent in the last sixty minutes. Which project each
    /// claim belongs to is settled a layer up; what is held here is that the two
    /// windows are narrowed apart.
    ///
    /// Checked by narrowing the hour with `windowSeconds` instead of
    /// `hourWindowSeconds`: the hour then keeps the stale copy and this fails.
    func testEachWindowNarrowsAContestedSessionAgainstItsOwnLength() async throws {
        let root = try makeProjectsDirectory()
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        try file("s-both", under: "/Users/x/current", in: root, writtenAt: now)
        try file("s-both", under: "/Users/x/stale", in: root,
                 writtenAt: now.addingTimeInterval(-3 * 86_400))

        let hourSince = Int(now.timeIntervalSince1970 - UsageStore.hourWindowSeconds)
        let snapshot = await UsageStore.poll(
            client: client(transport(sessions: Self.sessionsBody(["s-both"], input: 9),
                                     sessionsBySince: [
                                        hourSince: Self.sessionsBody(["s-both"], input: 4)])),
            previous: .empty, now: now, projectsDirectory: root)

        XCTAssertEqual(snapshot.contested.map(\.slugs), [["-Users-x-current", "-Users-x-stale"]],
                       "both lives ran inside the week and both have to keep their claim")
        XCTAssertEqual(snapshot.hourlyContested.map(\.slugs), [["-Users-x-current"]],
                       "a life last written three days ago still claims the last hour")
        XCTAssertEqual(snapshot.hourlyContested.first?.sessionId, "s-both",
                       "the identifier is what lets the live sessions be asked about this entry")
    }

    /// **The hour's ownerless spend reaches the snapshot, and a line of `--dump`.**
    ///
    /// The week has always kept `unmatched` and printed it; the hourly fold threw
    /// its copy away, so spend by a session with no local transcript — the agent
    /// nodes, mostly — left the hour with nothing anywhere to notice it by. That
    /// bucket does fill: `--dump` on this machine printed `no local session 1h:
    /// 1 sessions, 179k ie` on 2026-08-27 beside the week's `1 sessions, 7.52M ie`,
    /// the same session `71fbe714-…` in both, and `0 sessions, -` at 02:37 the next
    /// night while the week still held it. So the hourly fold was discarding a live
    /// figure — a stronger reason for the field than an empty bucket would have
    /// been, and the reason the line is printed even when it reads zero.
    ///
    /// Checked by deleting the two assignments in the hourly branch of `poll`: the
    /// counters go to zero and this fails.
    func testTheHoursOwnerlessSpendIsKeptAndPrinted() async throws {
        let root = try makeProjectsDirectory()
        try file("s-here", under: "/Users/x/project", in: root)

        let now = Date(timeIntervalSince1970: 1_786_800_000)
        let hourSince = Int(now.timeIntervalSince1970 - UsageStore.hourWindowSeconds)
        let snapshot = await UsageStore.poll(
            client: client(transport(sessions: Self.sessionsBody(["s-here"], input: 11),
                                     sessionsBySince: [
                                        hourSince: Self.sessionsBody(["s-here", "s-node"], input: 7)])),
            previous: .empty, now: now, projectsDirectory: root)

        XCTAssertEqual(snapshot.hourlyUnmatchedSessions, 1)
        XCTAssertEqual(snapshot.hourlyUnmatched.input, 7, "counted, and counted as nobody's")
        XCTAssertEqual(snapshot.unmatchedSessions, 0,
                       "the week's session has a transcript right here; its bucket must stay empty")
        XCTAssertEqual(ConsoleDump.unmatchedLine(window: "1h",
                                                 sessions: snapshot.hourlyUnmatchedSessions,
                                                 tokens: snapshot.hourlyUnmatched),
                       "no local session 1h: 1 sessions, 7 ie (in 7, out 0, cw 0, cr 0)")
        XCTAssertEqual(ConsoleDump.unmatchedLine(window: "7d",
                                                 sessions: snapshot.unmatchedSessions,
                                                 tokens: snapshot.unmatched),
                       "no local session 7d: 0 sessions, -",
                       "printed empty, like every other bucket in the section")
    }

    // MARK: - The histories' own half

    /// **The window the histories are asked over is a constant, and this holds
    /// the value, not merely a floor under it.**
    ///
    /// It was a setting — `usageLoadWindowHours`, which chose between two ways of
    /// estimating the week's demand and, by the same number, how deep to fetch.
    /// Both estimators are gone and the setting with them, so the depth is fixed,
    /// and it is fixed at 48 h for a reason on each side.
    ///
    /// **From below the floor moved, and it is now the measurement's own.** While
    /// the figure was a token allowance the depth was argued from the split of the
    /// day: a series shorter than 24 h has not seen every hour of the day even
    /// once, so it could not be split, and 23 h answered nothing. There is no
    /// split any more. What refuses a short series now is
    /// `FleetCapacity.minimumMeasuredHours` = 6 h, four times shallower — and it
    /// is still a refusal rather than a worse figure, which is what the control
    /// half below proves. **That is why this control had to be re-derived rather
    /// than re-pointed:** kept at 23/24 h it would have gone on passing while
    /// testing a boundary that no longer exists anywhere in the code.
    ///
    /// **From above the argument changed too, because the figure did.** The old
    /// one leant on the price of a point in tokens being steady across the range
    /// (6.934 / 7.047 / 7.044 M tokens a point over 12, 24 and 48 h); there is no
    /// price of a point now. What a short window costs the ratio is the ±1 pp
    /// sawtooth of §4 divided by the span — one endpoint landing on a tooth moves
    /// the whole figure. Measured 2026-09-05 02:50Z on the live histories, adding
    /// and subtracting one point from each account's last reading in turn:
    ///
    ///     window   answer    what one point of sawtooth moves it by
    ///       12 h   378.5%    ±7.01 pp
    ///       24 h   149.5%    -2.34 … +5.59 pp
    ///       48 h   112.8%    ±1.65 pp
    ///        6 h   no answer at all
    ///
    /// and deeper than 48 h the answer stops getting any deeper: the account that
    /// binds it is stopped by `max_points` = 2000 and comes back with the same
    /// 43.09 h whether it is asked for 48 h, 72 or a week (2026-09-05 15:35Z;
    /// `UsageStore.historyWindowSeconds` carries the table). **Retention is not
    /// the mechanism and this docblock used to say it was**, on the 2026-08-17
    /// reading that `since` of 7 and 30 days came back identical — asked for a
    /// week today acc3 reaches 86.8 h and is still stopped by the cap, so
    /// retention binds nobody. Neither end is a boundary a fixture can be walked
    /// to, so that side is held by an equality on the value with the reasoning
    /// written beside it: moving the constant is then a deliberate act with a
    /// place to read first.
    ///
    /// **A floor alone would not have held it, and that was measured rather than
    /// reasoned.** With only `>= 24 h` asserted here, shortening the constant on
    /// a copy of the source killed nothing at all at 48 → 24 h — 0 of 532 — and
    /// killed exactly this test at 24 → 23 h (2026-08-24). The equality is what
    /// closes that, and it is now the *only* thing that does: with the floor down
    /// at 6 h, 48 → 12 h leaves the control half green as well.
    func testTheHistoriesAreAskedOverAFixedWindowTheRatioIsSteadyOver() async {
        let log = RequestLog()
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        _ = await UsageStore.poll(client: client(transport(log: log)), previous: .empty, now: now)

        XCTAssertEqual(log.windows(of: "/history"),
                       [now.timeIntervalSince1970 - UsageStore.historyWindowSeconds],
                       "the pass asked for a window of its own rather than the one constant")
        XCTAssertEqual(UsageStore.historyWindowSeconds, 48 * 3600, """
            48 h, and both ends of that are measured: at 12 h one point of the gateway's \
            sawtooth moves the figure by 7 pp against 1.65 at 48, at 6 h the series comes back \
            5.99 h long and no account is measured at all, and past 48 h the answer stops \
            getting deeper — the account that binds it is capped at 2000 points and returns the \
            same 43 h asked for two days or for a week, retention holding nobody. Move it and \
            re-measure both ends — the docblock above says how
            """)

        // The control, and it is the whole point: just under the measurement's
        // floor nothing is answered, so the floor is a boundary rather than a
        // taste. 5.99 h is not an arbitrary short window — it is the length the
        // gateway actually returns for a six-hour request, which is why the 6 h
        // row of the table above says "no answer at all" rather than a number.
        //
        // **Both halves are literals, and the deep one used to be `floor`.**
        // Built from the constant it rode it: at 6 → 12 h a series `overHours:
        // floor` is 12 h long, clears a floor of 12, and the half stayed green,
        // while the shallow half at 5.99 h went on refusing for a reason that had
        // nothing to do with the value under test. So the only thing 6 → 12 h
        // failed was the equality below — a pin on a literal, with nothing asking
        // what the constant promises. 6.5 h is just above today's floor and
        // straddles it with the 5.99: move the constant and this pair stops
        // straddling, which is the failure the pin alone could not produce.
        let floor = FleetCapacity.minimumMeasuredHours
        XCTAssertEqual(floor, 6, "the 5.99 h and 6.5 h below straddle this value and only this one")
        let shallow = await UsageStore.poll(
            client: client(transport(sessions: Self.spendingSessions,
                                     history: Self.historySeries(readings: [0, 25, 50],
                                                                 overHours: 5.99))),
            previous: .empty, now: now)
        XCTAssertNil(shallow.fleetBurn,
                     "5.99 h of history answered a ratio, so the floor is not where it says")
        let deep = await UsageStore.poll(
            client: client(transport(sessions: Self.spendingSessions,
                                     history: Self.historySeries(readings: [0, 25, 50],
                                                                 overHours: 6.5))),
            previous: .empty, now: now)
        XCTAssertNotNil(deep.fleetBurn, "the floor is one to stand on, not one to fall through")
    }

    /// The same deadlock, one endpoint further on. `historyWindowSeconds` is
    /// another `static let` on a `@MainActor` type read straight from the
    /// `nonisolated async` pass, and losing `nonisolated` on it hops the rest of
    /// the pass — two HTTP calls, the histories and the transcript walk — onto a
    /// main thread that is standing on a semaphore right here.
    ///
    /// Only that one, and the difference is worth naming because the two
    /// constants read alike. `historyIntervalSeconds` has no `async` reader —
    /// `shouldFetchHistories` is synchronous and `UsagePopoverView.historyStaleSeconds`
    /// is a constant — so there is nowhere for the compiler to put a hop: taking
    /// its `nonisolated` off (2026-08-17) leaves this test green and fails the
    /// build instead, under the `-strict-concurrency=complete` the project has to
    /// be clean under. What holds it is the compiler; what holds
    /// `historyWindowSeconds` is the timeout below.
    ///
    /// The timeout is the whole test. Without it a regression is a run that
    /// never comes back, which is what this looked like when it happened to
    /// `windowSeconds`: `--dump` hung forever and had to be found by sampling
    /// the stuck process.
    ///
    /// A previous snapshot with no stamp, so the half actually runs — a pass
    /// that skipped it would never read either constant and would prove nothing.
    func testTheHistoriesPassDoesNotNeedTheMainThread() {
        let client = client(transport())
        let semaphore = DispatchSemaphore(value: 0)
        let answer = PollAnswer()
        Task.detached {
            answer.value = await UsageStore.poll(client: client, previous: .empty)
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success,
                       "the pass waited for a main thread that is standing right here")
        // The arrival stamp rather than the figure, because the stamp is what
        // says the half *ran*: it goes on whatever the fleet turned out to
        // support, and a `nil` figure is an arrival too. That the half ran is the
        // whole claim — it is what read the constants.
        XCTAssertNotNil(answer.value.historiesFetchedAt,
                        "the histories were never fetched, so neither constant was ever read")
    }

    /// The half runs on its own clock, and the reason is bandwidth: each pass is
    /// one request per account of roughly 150 KB, and at the once-a-minute
    /// cadence of the rest of the pass that is tens of megabytes an hour on a
    /// laptop. The figure is an average over two days and cannot move fast
    /// enough to be worth it.
    ///
    /// Driven to the state where the skip could fail to happen before it is
    /// asked about: the first pass has to fetch, or "no second request" would be
    /// true of a store that never asks at all.
    func testTheHistoriesAreNotFetchedAgainWhileTheFigureIsYoung() async {
        let log = RequestLog()
        let client = client(transport(log: log))
        let start = Date(timeIntervalSince1970: 1_786_800_000)

        let first = await UsageStore.poll(client: client, previous: .empty, now: start)
        XCTAssertEqual(log.historyRequests, 1, "the first pass did not fetch a history at all")
        XCTAssertEqual(first.historiesFetchedAt, start)
        XCTAssertEqual(first.historiesCheckedAt, start,
                       "on a pass that answered, the attempt and the arrival are one moment")

        let interval = UsageStore.historyIntervalSeconds
        let soon = await UsageStore.poll(client: client, previous: first,
                                         now: start.addingTimeInterval(interval - 1))
        XCTAssertEqual(log.historyRequests, 1,
                       "the histories were fetched again a second before the interval was up")
        XCTAssertNotNil(first.fleetBurn, "with no figure to carry, carrying it proves nothing")
        XCTAssertEqual(soon.fleetBurn, first.fleetBurn,
                       "the figure changed on a pass that never asked")
        XCTAssertEqual(soon.historiesFetchedAt, start, "a skipped pass moved the stamp")

        let later = await UsageStore.poll(client: client, previous: soon,
                                          now: start.addingTimeInterval(interval))
        XCTAssertEqual(log.historyRequests, 2, "the interval came round and nothing was fetched")
        XCTAssertEqual(later.historiesFetchedAt, start.addingTimeInterval(interval))
    }

    /// The points that reach `FleetCapacity` are the gateway's own.
    ///
    /// The other loader in this app, `UsageHistoryModel.load`, hands out
    /// `withoutSourceLag(answer.points)` because the chart wants the sawtooth
    /// gone, and routing this half through it would be an easy mistake to make
    /// and a hard one to see. The fixture is the shape where it is not subtle: a
    /// lone reading one point *below* the ceiling among ceiling readings is
    /// exactly what that filter deletes, and it is the only thing keeping an
    /// otherwise pinned account inside the measurement. Smoothed, the account is
    /// refused as one that spent the whole window blocked, and it leaves with its
    /// 100 pp of capacity as well as its demand.
    ///
    /// Both halves are asserted here, because "the answer is not nil" alone
    /// would pass over a filter that had never been applied to anything: the
    /// filter is run on the very same points to show it does change them, and the
    /// smoothed series is then put through `FleetCapacity` to show what that
    /// would have cost.
    ///
    /// **The account the filter refuses need not burn anything, and that is what
    /// changed with the metric.** While the allowance was the reader, the fixture
    /// had to spend points as well as touch its ceiling — a flat series priced no
    /// tokens, so it was refused either way and the filter cost nothing visible.
    /// The ratio has no price in it: a contributor brings a refill share whatever
    /// it burned, so an account pinned at 100 with one 99 in it is a full
    /// contributor with a burn of zero, and refusing it takes a whole account's
    /// week out of the *denominator*. The cost is therefore visible in the
    /// direction that matters — the figure goes **up** when the account is
    /// smoothed away, from 87.5% to 175%, which is the reading of a fleet that
    /// has one exhausted account read as the reading of a fleet that does not.
    func testTheFigureIsBuiltFromRawPointsRatherThanSmoothedOnes() async throws {
        // The shape the filter destroys: a lone reading one point under a ceiling
        // it is otherwise pinned to. That one 99 is the only evidence the account
        // was measured at all rather than merely watched.
        let pinned = Self.historySeries(label: "acc2", readings: [100, 99, 100, 100, 100])
        let series = try UsageFixtures.decode(pinned, as: HistorySeries.self)
        XCTAssertEqual(UsageHistoryModel.withoutSourceLag(series.points).map(\.sevenDay),
                       [100, 100, 100, 100, 100],
                       "the fixture is not a series the filter changes, so it proves nothing")

        // It takes two accounts to see the cost. On its own the pinned account is
        // the whole fleet, and a fleet of one refused account has no figure
        // either way — `nil` against `nil` says nothing about the filter. Beside
        // an account that does burn, the refusal is a number: acc3's 1.0417 pp/h
        // against one week's refill instead of two.
        let burning = Self.historySeries(label: "acc3", readings: [0, 25, 50])
        let both = [pinned, burning]
        let smoothed = [Self.historySeries(label: "acc2", readings: [100, 100, 100, 100, 100]), burning]
        func figure(_ bodies: [String]) throws -> FleetCapacity.FleetBurn? {
            let accounts = try UsageFixtures.decode(UsageFixtures.usageTwoAccounts,
                                                    as: UsageReport.self).accounts
            var byLabel: [String: HistorySeries] = [:]
            for body in bodies {
                let series = try UsageFixtures.decode(body, as: HistorySeries.self)
                byLabel[series.label] = series
            }
            return FleetCapacity.burnAgainstRefill(histories: byLabel, accounts: accounts)
        }
        let raw = try XCTUnwrap(try figure(both))
        let filtered = try XCTUnwrap(try figure(smoothed))
        XCTAssertEqual(raw.accounts, 2)
        XCTAssertEqual(raw.percent, 87.5, accuracy: 0.01)
        XCTAssertTrue(raw.isLowerBound, "acc2 sat at its ceiling for four of five samples")
        XCTAssertEqual(filtered.accounts, 1,
                       "smoothed, the pinned account has no reading below its ceiling left and is "
                       + "refused — which is the whole cost being avoided")
        XCTAssertEqual(filtered.percent, 175, accuracy: 0.01,
                       "an account's whole week of refill left the denominator")
        XCTAssertFalse(filtered.isLowerBound, "and the `≥` on a blocked fleet went with it")

        // And the pass hands over what the client returned. Two accounts, two
        // series, and the answer has to be the raw one.
        let snapshot = await UsageStore.poll(
            client: client(transport(usage: UsageFixtures.usageTwoAccounts,
                                     sessions: Self.spendingSessions,
                                     historyByLabel: ["acc2": pinned, "acc3": burning])),
            previous: .empty)
        let landed = try XCTUnwrap(snapshot.fleetBurn, """
            the pass answered nothing for a fleet with one account below its ceiling on one sample: \
            the points were smoothed on the way in and that account went out of the fraction \
            with its refill
            """)
        XCTAssertEqual(landed.accounts, 2)
        XCTAssertEqual(landed.percent, 87.5, accuracy: 0.01)
        XCTAssertTrue(landed.isLowerBound, "it sat at 100 for four of five samples")
    }

    /// A history that does not answer is ordinary, and it is one half of three.
    /// The previous figure stays where it was **and so does its age** — that
    /// stamp is what the popover's footer dates the screen by, and moving it
    /// along with a failed attempt is how a frozen figure gets called fresh. The
    /// blame names its own endpoint without touching the two that answered.
    func testAFailedHistoryHalfKeepsThePreviousFigureAndBlamesItsOwnEndpoint() async {
        let earlier = Date(timeIntervalSince1970: 1_786_700_000)
        var previous = UsageSnapshot.empty
        // The rates are the expressions production computes for three
        // contributors, not a pair copied off a probe: `0.6714 / 0.5952` stood
        // here and is the *per-account* form — 0.5952 is `100 / 168`, one
        // account's share — so with `accounts: 3` it was an object
        // `burnAgainstRefill` cannot produce. Same defect as the one fixed in
        // `testTheLeadLineNamesTheRatioItsDepthAndBothSidesOfTheDivision`.
        previous.fleetBurn = FleetCapacity.FleetBurn(
            percent: 112.8, burnRate: 112.8 / 100 * 3 * 100.0 / 168,
            refillRate: 3 * 100.0 / 168, accounts: 3,
            measuredHours: 48, isLowerBound: true)
        previous.historiesFetchedAt = earlier
        previous.historiesCheckedAt = earlier

        let now = Date()
        let snapshot = await UsageStore.poll(client: client(transport(history: nil)),
                                             previous: previous, now: now)
        XCTAssertEqual(snapshot.fleetBurn, previous.fleetBurn, "the figure blinked to blank")
        XCTAssertEqual(snapshot.historiesFetchedAt, earlier,
                       "the age of the figure moved to an attempt that brought nothing back")
        XCTAssertEqual(snapshot.historiesFailure?.contains("history"), true)
        XCTAssertNil(snapshot.quotaFailure, "the quota endpoint answered and is blamed anyway")
        XCTAssertNil(snapshot.sessionsFailure)
        XCTAssertEqual(snapshot.quotaFetchedAt, now)
    }

    /// And the attempt is stamped anyway, so the half that keeps failing keeps
    /// failing on its own ten-minute cadence rather than on the once-a-minute
    /// one of the rest of the pass.
    ///
    /// The cost of the other behaviour is measured rather than feared: one round
    /// over the live fleet is 481 KB (2026-08-18, three accounts, a 48 h
    /// window), which is 2.9 MB/h at ten minutes — and every minute, carrying
    /// every account but the one that failed, some 19 MB/h, the figure
    /// `historyIntervalSeconds` exists to avoid.
    /// Affordable now because the screen says so: the figure keeps the age it
    /// arrived under and the footer prints both that and the reason.
    ///
    /// Driven to the state where the skip could fail to happen: the failing pass
    /// has to *make* its request first, or "no second request" would be true of
    /// a pass that never asked at all.
    func testAFailedHistoryHalfWaitsOutItsOwnIntervalBeforeRetrying() async {
        let log = RequestLog()
        let start = Date(timeIntervalSince1970: 1_786_800_000)
        let broken = client(transport(history: nil, log: log))

        let failed = await UsageStore.poll(client: broken, previous: .empty, now: start)
        XCTAssertEqual(log.historyRequests, 1, "the failing pass never asked, so it skipped nothing")
        XCTAssertNotNil(failed.historiesFailure)
        XCTAssertNil(failed.historiesFetchedAt, "nothing arrived, so nothing may carry an age")

        let minuteLater = await UsageStore.poll(client: broken, previous: failed,
                                                now: start.addingTimeInterval(60))
        XCTAssertEqual(log.historyRequests, 1,
                       "a failed round was retried a minute later, which is the 19 MB/h on a "
                       + "tether that the ten-minute cadence exists to avoid")

        let interval = UsageStore.historyIntervalSeconds
        _ = await UsageStore.poll(client: broken, previous: minuteLater,
                                  now: start.addingTimeInterval(interval))
        XCTAssertEqual(log.historyRequests, 2, "the interval came round and the retry never happened")
    }

    /// The histories are not asked for at all when the quota half did not
    /// answer, and that is not thrift: the fleet's membership and each account's
    /// window boundary both come from that answer, and `FleetCapacity` reads a
    /// history only under a label the fleet has.
    ///
    /// The previous snapshot has to carry accounts, or this cannot come out
    /// wrong. Started from `.empty` the labels are an empty list whatever the
    /// guard does, so no request is made for want of anything to request —
    /// checked by removing the guard, where the test stayed green. With a
    /// remembered account in hand the ungated pass fetches its history, which is
    /// the mistake being described: measuring a fleet against a membership the
    /// gateway has stopped confirming.
    func testNoHistoryIsFetchedWhenTheQuotaHalfDidNotAnswer() async throws {
        var previous = UsageSnapshot.empty
        previous.accounts = try UsageFixtures.decode(UsageFixtures.usage, as: UsageReport.self).accounts
        XCTAssertFalse(previous.accounts.isEmpty, "the fixture remembers no account to be tempted by")

        let log = RequestLog()
        let snapshot = await UsageStore.poll(client: client(transport(usage: nil, log: log)),
                                             previous: previous)
        XCTAssertEqual(log.historyRequests, 0,
                       "a history was fetched for a fleet whose membership nobody just confirmed")
        XCTAssertNil(snapshot.fleetBurn)
        XCTAssertNil(snapshot.historiesFailure, "the history half is blamed for the quota half's failure")
    }

    /// A `nil` from `FleetCapacity` is an arrival, not a failure: it is the
    /// answer "this fleet supports no figure", which happens when no account has
    /// `minimumMeasuredHours` of history and when every one of them is pinned at
    /// its ceiling. So it is stamped, it clears the blame, and it replaces
    /// whatever was there — holding the previous number over it would state a
    /// ratio for a fleet that stopped supporting one.
    func testAFleetThatSupportsNoFigureReplacesTheOneBeforeIt() async {
        var previous = UsageSnapshot.empty
        // Producible rates, for the reason given at the fixture above.
        previous.fleetBurn = FleetCapacity.FleetBurn(
            percent: 112.8, burnRate: 112.8 / 100 * 3 * 100.0 / 168,
            refillRate: 3 * 100.0 / 168, accounts: 3,
            measuredHours: 48, isLowerBound: false)
        previous.historiesFetchedAt = Date(timeIntervalSince1970: 1_786_700_000)

        let now = Date()
        // Four hours of history, under `FleetCapacity.minimumMeasuredHours`.
        let brief = Self.historySeries(readings: [0, 50], overHours: 4)
        let snapshot = await UsageStore.poll(client: client(transport(history: brief)),
                                             previous: previous, now: now)
        XCTAssertNil(snapshot.fleetBurn, "a figure nobody can measure was kept from the pass before")
        XCTAssertEqual(snapshot.historiesFetchedAt, now)
        XCTAssertNil(snapshot.historiesFailure, "nothing failed: the gateway answered and said so")
    }
}

/// What a transport was asked for, across the threads a pass runs on.
///
/// `@unchecked Sendable`: every access is under the lock.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URL] = []

    func record(_ url: URL?) {
        guard let url else { return }
        lock.lock()
        requests.append(url)
        lock.unlock()
    }

    private var all: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var historyRequests: Int { all.filter { $0.path.hasSuffix("/history") }.count }

    /// The `since` every request to one endpoint asked for, oldest first — which
    /// is what says whether two halves of one figure were measured over the same
    /// window.
    func windows(of endpoint: String) -> [Double] {
        all.filter { $0.path.hasSuffix(endpoint) }.compactMap { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "since" }?.value.flatMap(Double.init)
        }
    }
}

/// Carries one pass's answer out of a detached task to the test that waited on
/// it. `@unchecked Sendable` on the same terms as `UsageStore.PollResult`:
/// written once inside the task and read only after the semaphore was signalled.
private final class PollAnswer: @unchecked Sendable {
    var value: UsageSnapshot = .empty
}

/// The one new setting.
final class UsageConfigTests: XCTestCase {

    func testTheDefaultAddressIsTheLocalRelayAndItParses() {
        XCTAssertEqual(Config.default.usageBaseURL, "http://127.0.0.1:8788")
        XCTAssertEqual(Config.default.resolvedUsageBaseURL.absoluteString, "http://127.0.0.1:8788")
    }

    func testAConfiguredAddressIsTaken() throws {
        let config = try load(["usageBaseURL": "http://10.0.0.1:8787"])
        XCTAssertEqual(config.resolvedUsageBaseURL.absoluteString, "http://10.0.0.1:8787")
    }

    /// `URL(string:)` accepts far more than it looks like it does — `not a url
    /// at all` parses into a relative URL on macOS 14, which is why the check is
    /// for a scheme and a host rather than for a successful parse.
    func testAnAddressWithNothingToConnectToFallsBackToTheDefault() throws {
        XCTAssertEqual(try load(["usageBaseURL": ""]).usageBaseURL, Config.default.usageBaseURL)
        XCTAssertEqual(try load(["usageBaseURL": "not a url at all"]).usageBaseURL,
                       Config.default.usageBaseURL)
        XCTAssertEqual(try load(["usageBaseURL": "127.0.0.1:8788"]).usageBaseURL,
                       Config.default.usageBaseURL, "no scheme")
        XCTAssertEqual(try load(["usageBaseURL": "http:///gw"]).usageBaseURL,
                       Config.default.usageBaseURL, "no host")
        XCTAssertEqual(try load(["usageBaseURL": 8788]).usageBaseURL, Config.default.usageBaseURL)
    }

    /// Having a scheme is not the same as having one this client can speak.
    /// `ftp://host/x` and `file://localhost/tmp` both parse, both have a host,
    /// and both are exactly the permanent failure the check exists to keep out —
    /// one would answer "unsupported URL" every minute, the other would hand the
    /// decoder the contents of a directory.
    func testASchemeThatIsNotHTTPIsRejected() throws {
        XCTAssertEqual(try load(["usageBaseURL": "ftp://host/x"]).usageBaseURL,
                       Config.default.usageBaseURL, "ftp")
        XCTAssertEqual(try load(["usageBaseURL": "file://localhost/tmp"]).usageBaseURL,
                       Config.default.usageBaseURL, "file")
    }

    /// HTTPS is not the gateway's own address today, but it is what a reverse
    /// proxy in front of it would be, and rejecting it would be a surprise.
    func testHTTPSIsAccepted() throws {
        XCTAssertEqual(try load(["usageBaseURL": "https://gw.example.org:8787"]).usageBaseURL,
                       "https://gw.example.org:8787")
    }

    private func load(_ values: [String: Any]) throws -> Config {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-config-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: values).write(to: url)
        return Config.load(from: url)
    }
}
