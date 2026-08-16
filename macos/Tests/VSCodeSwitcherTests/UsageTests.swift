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
    private func file(_ sessionId: String, startedIn directory: String) throws {
        let slug = transcripts.appendingPathComponent(ClaudeSessions.slug(forPath: directory))
        try FileManager.default.createDirectory(at: slug, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: slug.appendingPathComponent("\(sessionId).jsonl"))
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
        let snapshot = DataSource.assemble(projects: projects,
                                           windows: [],
                                           sessions: [],
                                           tokensBySlug: folded.tokensBySlug,
                                           contested: folded.contested,
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
    func testTheDumpNamesTheAmbiguousBucketAndCountsIt() throws {
        let first = try makeProject("switcher")
        let second = try makeProject("home-network")
        try file("s1", startedIn: first.path)
        try file("s1", startedIn: second.path)

        let result = attribute([try session("s1", input: 12)], projects: [first, second])
        XCTAssertEqual(ConsoleDump.ambiguousLine(sessions: result.snapshot.ambiguousUsageSessions,
                                                 tokens: result.snapshot.ambiguousUsage),
                       "ambiguous:        1 sessions, 12 ie (in 12, out 0, cw 0, cr 0)")
        XCTAssertEqual(ConsoleDump.ambiguousLine(sessions: 0, tokens: .zero),
                       "ambiguous:        0 sessions, -",
                       "and it is printed when the bucket is empty, which is most weeks")
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
        XCTAssertEqual(folded.contested, [ContestedSpend(slugs: ["-x-one", "-x-two"],
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
                          sessions: [ClaudeSessionInfo] = [],
                          windows: [VSCodeWindowInfo] = [],
                          worktrees: [String] = []) -> SwitcherSnapshot {
        DataSource.assemble(projects: [TestFixtures.project(path: projectPath, rootName: "switcher")],
                            windows: windows,
                            sessions: sessions,
                            tokensBySlug: Dictionary(uniqueKeysWithValues: spend.map {
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
        XCTAssertTrue(snapshot.tokensBySlug.isEmpty)
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
