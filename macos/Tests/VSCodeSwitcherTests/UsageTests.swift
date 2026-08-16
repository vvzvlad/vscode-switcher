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

    /// The `since` that comes back is the one the gateway *applied* after
    /// clamping to its retention, which is the number to show — never the one
    /// that was asked for.
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

/// Finding out where a session ran, from what Claude Code left on disk.
final class UsageIndexTests: XCTestCase {

    private func makeProjectsDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
    }

    /// The slug replaces `_` and `.` with `-` and cannot be turned back into a
    /// path, so the working directory has to come out of the file itself.
    func testTheWorkingDirectoryComesFromTheTranscriptAndNotFromTheSlug() throws {
        let root = try makeProjectsDirectory()
        let cwd = "/Users/x/Data/Projects/my_project.v2"
        let sessionId = UUID().uuidString
        let directory = root.appendingPathComponent(ClaudeSessions.slug(forPath: cwd))
        try write(["{\"type\":\"summary\",\"summary\":\"no cwd on this one\"}",
                   "{\"type\":\"user\",\"cwd\":\"\(cwd)\",\"sessionId\":\"\(sessionId)\"}"],
                  to: directory.appendingPathComponent("\(sessionId).jsonl"))

        XCTAssertEqual(directory.lastPathComponent, "-Users-x-Data-Projects-my-project-v2")
        let found = UsageIndex.cwdBySessionId(for: [sessionId], projectsDirectory: root)
        XCTAssertEqual(found[sessionId], cwd, "the underscore and the dot survive only in the file")
    }

    /// Subagent transcripts live one level down, in `<sessionId>/subagents/`, and
    /// are not sessions the gateway ever reports.
    func testSubagentTranscriptsAreNotListed() throws {
        let root = try makeProjectsDirectory()
        let sessionId = UUID().uuidString
        let directory = root.appendingPathComponent("-Users-x-project")
        try write(["{\"cwd\":\"/Users/x/project\"}"],
                  to: directory.appendingPathComponent("\(sessionId).jsonl"))
        try write(["{\"cwd\":\"/Users/x/project\"}"],
                  to: directory.appendingPathComponent(sessionId)
                      .appendingPathComponent("subagents")
                      .appendingPathComponent("agent-deadbeef.jsonl"))

        let found = UsageIndex.cwdBySessionId(for: [sessionId, "agent-deadbeef"], projectsDirectory: root)
        XCTAssertEqual(found[sessionId], "/Users/x/project")
        XCTAssertNil(found["agent-deadbeef"], "a subagent is not a session")
    }

    /// A session running on another machine reports to the same gateway and has
    /// no transcript here. Ordinary, not an error.
    func testASessionWithNoTranscriptIsSimplyAbsent() throws {
        let root = try makeProjectsDirectory()
        XCTAssertTrue(UsageIndex.cwdBySessionId(for: ["nowhere-\(UUID().uuidString)"],
                                                projectsDirectory: root).isEmpty)
    }

    func testAskingForNothingReadsNothing() throws {
        let root = try makeProjectsDirectory()
        XCTAssertTrue(UsageIndex.cwdBySessionId(for: [], projectsDirectory: root).isEmpty)
    }

    func testATranscriptWithoutACwdYieldsNothing() throws {
        let root = try makeProjectsDirectory()
        let sessionId = UUID().uuidString
        try write(["{\"type\":\"summary\"}", "{\"type\":\"user\"}"],
                  to: root.appendingPathComponent("-Users-x-project")
                      .appendingPathComponent("\(sessionId).jsonl"))
        XCTAssertNil(UsageIndex.cwdBySessionId(for: [sessionId], projectsDirectory: root)[sessionId])
    }

    // MARK: - The head window

    private func makeTranscript(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-head-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Only the head of a transcript is read. Transcripts reach tens of
    /// megabytes and this runs over every session the gateway reports, so a
    /// `cwd` past the window is not found — and must not be, because the only
    /// way to find it is to read the whole file.
    ///
    /// Nothing tested this: every other transcript here fits inside the window
    /// whole, so `read(upToCount:)` could be swapped for reading the file
    /// entire and the suite would not notice. The second half of the assertion
    /// is the control — the same file, a window that reaches the record.
    func testOnlyTheHeadOfATranscriptIsRead() throws {
        // 19 bytes each, so three of them fit in a 64-byte window and the fourth
        // line is cut by it. The record is followed by two more so that it is
        // not the last line of the file: the last line inside the window is
        // dropped, and a whole-file read would have that rule cover for it.
        let filler = String(repeating: "{\"type\":\"summary\"}\n", count: 10)
        let url = try makeTranscript(filler + "{\"cwd\":\"/tmp/past-the-window\"}\n"
                                     + "{\"type\":\"summary\"}\n{\"type\":\"summary\"}\n")

        XCTAssertNil(UsageIndex.cwd(fromTranscriptAtPath: url.path, headBytes: 64),
                     "the record sits 190 bytes in, outside a 64-byte window")
        XCTAssertEqual(UsageIndex.cwd(fromTranscriptAtPath: url.path, headBytes: 4096),
                       "/tmp/past-the-window",
                       "the same file, with a window that reaches it")
    }

    /// The last line inside the window is dropped whether the window cut it in
    /// half or it happened to end exactly there. From inside the window the two
    /// are indistinguishable — there is no byte that says "and the file goes on"
    /// — and half a record can only yield a path that was never anybody's
    /// working directory.
    func testTheLastLineInsideTheWindowIsDropped() throws {
        let head = "{\"type\":\"summary\"}\n"
        let record = "{\"cwd\":\"/tmp/x\"}"
        let url = try makeTranscript(head + record + "\n{\"cwd\":\"/tmp/later\"}\n")

        XCTAssertNil(UsageIndex.cwd(fromTranscriptAtPath: url.path,
                                    headBytes: head.utf8.count + record.utf8.count),
                     "a record ending exactly on the boundary is dropped like a cut one")
        XCTAssertNil(UsageIndex.cwd(fromTranscriptAtPath: url.path, headBytes: head.utf8.count + 8),
                     "and a record the boundary cuts is never parsed")
    }

    /// A first line longer than the whole window leaves no complete record to
    /// read, so the session has no working directory and its spend goes to
    /// `unmatched` — spend with no owner on this machine, which is a state the
    /// app already shows. The alternative would be attributing it to whatever
    /// path a truncated record left behind.
    func testASessionWhoseFirstLineExceedsTheWindowGoesToUnmatched() throws {
        let root = try makeProjectsDirectory()
        let sessionId = UUID().uuidString
        let padding = String(repeating: "x", count: UsageIndex.headBytes)
        try write(["{\"cwd\":\"/Users/x/project\",\"toolResult\":\"\(padding)\"}",
                   "{\"cwd\":\"/Users/x/project\"}"],
                  to: root.appendingPathComponent("-Users-x-project")
                      .appendingPathComponent("\(sessionId).jsonl"))

        let found = UsageIndex.cwdBySessionId(for: [sessionId], projectsDirectory: root)
        XCTAssertTrue(found.isEmpty, "no complete record inside the window, so no directory")

        let session = try UsageFixtures.decode("""
        {"session_id": "\(sessionId)", "input_tokens": 7, "output_tokens": 0,
         "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
        """, as: GatewaySession.self)
        let folded = UsageIndex.fold(sessions: [session], cwdBySessionId: found)
        XCTAssertTrue(folded.tokensByCwd.isEmpty)
        XCTAssertEqual(folded.unmatchedSessions, 1)
        XCTAssertEqual(folded.unmatched.input, 7, "counted, and counted as nobody's")
    }

    /// Several chats of the same project are several sessions in one directory,
    /// which is the ordinary case rather than a collision.
    func testSeveralSessionsOfOneDirectoryAreAllFound() throws {
        let root = try makeProjectsDirectory()
        let cwd = "/Users/x/project"
        let directory = root.appendingPathComponent(ClaudeSessions.slug(forPath: cwd))
        let identifiers = [UUID().uuidString, UUID().uuidString]
        for sessionId in identifiers {
            try write(["{\"cwd\":\"\(cwd)\"}"], to: directory.appendingPathComponent("\(sessionId).jsonl"))
        }

        let found = UsageIndex.cwdBySessionId(for: Set(identifiers), projectsDirectory: root)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.values), [cwd])
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
                                     cwdBySessionId: ["a": "/Users/x/project", "b": "/Users/x/project"])
        XCTAssertEqual(folded.tokensByCwd["/Users/x/project"]?.input, 15)
        XCTAssertEqual(folded.unmatchedSessions, 0)
        XCTAssertEqual(folded.unmatched, .zero)
    }

    func testASessionWithNoLocalTranscriptIsUnmatchedRatherThanDropped() throws {
        let folded = UsageIndex.fold(sessions: [try session("a", input: 10), try session("node", input: 7)],
                                     cwdBySessionId: ["a": "/Users/x/project"])
        XCTAssertEqual(folded.tokensByCwd.count, 1)
        XCTAssertEqual(folded.unmatchedSessions, 1)
        XCTAssertEqual(folded.unmatched.input, 7)
    }

    func testAnUnnamedCounterSurvivesTheFold() throws {
        let partial = try UsageFixtures.decode("""
        {"session_id": "p", "input_tokens": 10, "output_tokens": null}
        """, as: GatewaySession.self)
        let folded = UsageIndex.fold(sessions: [try session("a", input: 1), partial],
                                     cwdBySessionId: ["a": "/x", "p": "/x"])
        XCTAssertEqual(folded.tokensByCwd["/x"]?.input, 11)
        XCTAssertEqual(folded.tokensByCwd["/x"]?.isComplete, false)
    }

    // MARK: - Attribution to rows

    private let projectPath = "/Users/x/Data/Projects/switcher"

    private func tokens(_ input: Int) -> TokenCounts {
        TokenCounts(input: input, output: 0, cacheCreation: 0, cacheRead: 0)
    }

    private func assemble(tokensByCwd: [String: TokenCounts],
                          sessions: [ClaudeSessionInfo] = [],
                          windows: [VSCodeWindowInfo] = []) -> SwitcherSnapshot {
        DataSource.assemble(projects: [TestFixtures.project(path: projectPath, rootName: "switcher")],
                            windows: windows,
                            sessions: sessions,
                            tokensByCwd: tokensByCwd,
                            accessibilityTrusted: true)
    }

    func testSpendInTheProjectDirectoryLandsOnItsRow() {
        let snapshot = assemble(tokensByCwd: [projectPath: tokens(10)])
        let row = snapshot.projects.first { $0.project?.path == projectPath }
        XCTAssertEqual(row?.usage?.input, 10)
        XCTAssertEqual(row?.usageInputEquivalent, 10)
    }

    /// The case this rule exists for: an agent working in a worktree of the
    /// project spends the project's tokens. Keyed by its own directory it would
    /// vanish — nothing opens a window on `.claude/worktrees/<name>`.
    func testSpendInAWorktreeCountsAsTheProjects() {
        let worktree = projectPath + "/.claude/worktrees/usage-stats"
        let snapshot = assemble(tokensByCwd: [worktree: tokens(7)])
        let row = snapshot.projects.first { $0.project?.path == projectPath }
        XCTAssertEqual(row?.usage?.input, 7)
    }

    func testTheProjectAndItsWorktreesAddUp() {
        let snapshot = assemble(tokensByCwd: [projectPath: tokens(10),
                                              projectPath + "/.claude/worktrees/one": tokens(7),
                                              projectPath + "/macos": tokens(3)])
        let row = snapshot.projects.first { $0.project?.path == projectPath }
        XCTAssertEqual(row?.usage?.input, 20)
    }

    func testAWindowRowCarriesItsProjectsSpend() {
        let window = TestFixtures.window(index: 0, title: "topic \u{2014} switcher (Workspace)")
        let snapshot = assemble(tokensByCwd: [projectPath: tokens(10)], windows: [window])
        XCTAssertEqual(snapshot.openWindows.first?.usage?.input, 10)
        XCTAssertTrue(snapshot.projects.isEmpty, "the project has a window, so it has no second row")
    }

    /// A directory outside every scan root has a row of its own as soon as an
    /// agent runs there, and that row keeps its own spend.
    func testAnOrphanRowKeepsItsOwnSpend() {
        let snapshot = assemble(tokensByCwd: [projectPath: tokens(10), "/tmp/scratch": tokens(4)],
                                sessions: [TestFixtures.session(id: "s1", cwd: "/tmp/scratch", state: .working)])
        let orphan = snapshot.projects.first { $0.id == "cwd:/tmp/scratch" }
        XCTAssertEqual(orphan?.usage?.input, 4)
        XCTAssertEqual(snapshot.projects.first { $0.project?.path == projectPath }?.usage?.input, 10)
    }

    func testARowWithNoSpendCarriesNoNumberRatherThanZero() {
        let snapshot = assemble(tokensByCwd: [:])
        let row = snapshot.projects.first { $0.project?.path == projectPath }
        XCTAssertNil(row?.usage)
        XCTAssertNil(row?.usageInputEquivalent, "no figure at all is not a figure of zero")
    }

    /// Spend the gateway reports for a directory nobody has a row for is not
    /// invented into one: it stays in the snapshot's totals.
    func testSpendOutsideEveryRowDoesNotCreateARow() {
        let snapshot = assemble(tokensByCwd: ["/tmp/finished-last-week": tokens(4)])
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
        let snapshot = assemble(tokensByCwd: [projectPath: tokens(10)], windows: [first, second])

        XCTAssertEqual(snapshot.openWindows.count, 2)
        XCTAssertEqual(snapshot.openWindows.map { $0.usage?.input }, [10, 10],
                       "the project's spend, whole, on each of its windows")
        XCTAssertEqual(snapshot.openWindows.compactMap(\.usageInputEquivalent), [10, 10])
    }

    // MARK: - What is known, and what is only a lower bound

    /// The gateway named none of the four counters. `weighted()` folds every
    /// unnamed counter in as zero and so answers 0 — which is the sum of nothing
    /// known, not a spend of zero — and the flag that says so, `isComplete`, is
    /// gone the moment the number is taken out on its own. So the accessor the
    /// UI reads answers `nil` and the dump prints a dash.
    func testARowThatKnowsNothingShowsNoNumberRatherThanAConfidentZero() throws {
        let unnamed = TokenCounts(input: nil, output: nil, cacheCreation: nil, cacheRead: nil)
        let snapshot = assemble(tokensByCwd: [projectPath: unnamed])
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
        let snapshot = assemble(tokensByCwd: [projectPath: partial])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })

        XCTAssertEqual(row.usageInputEquivalent, 1000)
        XCTAssertTrue(row.usageIsLowerBound)
        XCTAssertEqual(ConsoleDump.usageCell(for: row), ">=1k")
    }

    func testACompletelyKnownRowIsANumberWithoutTheMark() throws {
        let snapshot = assemble(tokensByCwd: [projectPath: tokens(1000)])
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

        let withWindow = assemble(tokensByCwd: [projectPath: partial], windows: [window])
        let windowRow = try XCTUnwrap(withWindow.openWindows.first)
        XCTAssertTrue(ConsoleDump.formatTokens(try XCTUnwrap(windowRow.usage)).hasPrefix(">="),
                      "windows section")

        let withoutWindow = assemble(tokensByCwd: [projectPath: partial])
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
/// `prefixes(of:)` is entirely made of left all 308 tests green.
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
    /// Checked by deleting the `+ "/"`: this test fails and the other 310 pass.
    /// Note which assertions do the work — the two with both projects in the
    /// list are green either way, because the deeper prefix wins the sibling
    /// back. The separator only shows up when the sibling is not in the list.
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
    /// this test fails and the other 310 pass — and only the `shallow first`
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
        polled.checkedAt = Date()
        polled.tokensByCwd = [project.path: TokenCounts(input: 10, output: 2,
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

    /// Answers `/gw/usage` and `/gw/sessions` from the fixtures, or fails both.
    private func transport(usage: String? = UsageFixtures.usage,
                           sessions: String? = "{\"since\": 1786761516, \"sessions\": []}",
                           status: Int = 200) -> UsageClient.Transport {
        { request in
            let path = request.url?.path ?? ""
            let body = path.hasSuffix("/sessions") ? sessions : usage
            guard let body else { throw UsageError.unreachable("nothing listening") }
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            guard let response = HTTPURLResponse(url: url, statusCode: status,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(body.utf8), response)
        }
    }

    private func client(_ transport: @escaping UsageClient.Transport) -> UsageClient {
        UsageClient(baseURL: Config.default.resolvedUsageBaseURL, transport: transport)
    }

    func testAGoodPassFillsInEverythingAndReportsNoFailure() async {
        let now = Date()
        let snapshot = await UsageStore.poll(client: client(transport()), previous: .empty, now: now)
        XCTAssertNil(snapshot.failureText)
        XCTAssertEqual(snapshot.since, Date(timeIntervalSince1970: 1_786_761_516))
        XCTAssertEqual(snapshot.fleetSevenDayMean, 58.667)
        XCTAssertEqual(snapshot.accounts.map(\.label), ["acc2"])
        XCTAssertEqual(snapshot.checkedAt, now)
        XCTAssertEqual(snapshot.quotaFetchedAt, now)
    }

    /// A gateway that is not there is ordinary: the numbers from the pass before
    /// stay put and only the blame changes. Blinking to blank would be worse.
    ///
    /// And the stamp stays with the numbers it belongs to. Moving it along with
    /// the attempt is what had the popover describing hour-old figures as
    /// fetched a moment ago, with the reason they were not standing right
    /// underneath.
    func testAFailedPassKeepsThePreviousNumbersAndTheirStamps() async {
        let earlier = Date(timeIntervalSince1970: 1_786_700_000)
        var previous = UsageSnapshot.empty
        previous.tokensByCwd = ["/x": TokenCounts(input: 1, output: 2, cacheCreation: 3, cacheRead: 4)]
        previous.fleetSevenDayMean = 42
        previous.quotaFetchedAt = earlier

        let now = Date()
        let snapshot = await UsageStore.poll(client: client(transport(usage: nil, sessions: nil)),
                                             previous: previous,
                                             now: now)
        XCTAssertEqual(snapshot.tokensByCwd, previous.tokensByCwd)
        XCTAssertEqual(snapshot.fleetSevenDayMean, 42)
        XCTAssertEqual(snapshot.quotaFailure?.contains("/gw/usage"), true)
        XCTAssertEqual(snapshot.sessionsFailure?.contains("/gw/sessions"), true)
        XCTAssertEqual(snapshot.checkedAt, now, "the attempt is what just happened")
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
        XCTAssertTrue(failure.contains("/gw/sessions: unreachable"), "got \(failure)")
        XCTAssertLessThan(elapsed, 5,
                          "a refused connection is immediate; this waited like a pass that hung")
        XCTAssertTrue(snapshot.tokensByCwd.isEmpty)
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
}

/// The one new setting.
final class UsageConfigTests: XCTestCase {

    func testTheDefaultAddressIsTheLocalRelayAndItParses() {
        XCTAssertEqual(Config.default.usageBaseURL, "http://127.0.0.1:8788")
        XCTAssertEqual(Config.default.resolvedUsageBaseURL.absoluteString, "http://127.0.0.1:8788")
    }

    func testAConfiguredAddressIsTaken() throws {
        let config = try load(["usageBaseURL": "http://10.20.30.1:8787"])
        XCTAssertEqual(config.resolvedUsageBaseURL.absoluteString, "http://10.20.30.1:8787")
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
