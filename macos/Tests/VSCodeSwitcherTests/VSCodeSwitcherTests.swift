import XCTest
@testable import VSCodeSwitcher

/// Transcript directory names. Replacing only `/` loses every project whose
/// name contains an underscore or a dot, which is a third of the real ones.
final class SlugTests: XCTestCase {
    func testSlugMatchesRealTranscriptDirectories() {
        let cases = [
            "/Users/vvzvlad/Data/Projects/home-network": "-Users-vvzvlad-Data-Projects-home-network",
            "/Users/vvzvlad/Data/Projects/ukuetis_panel_fw": "-Users-vvzvlad-Data-Projects-ukuetis-panel-fw",
            "/Users/vvzvlad/Data/Projects/glazy_solver": "-Users-vvzvlad-Data-Projects-glazy-solver",
            "/Users/vvzvlad/Data/Projects/wirenboard/wb-mge": "-Users-vvzvlad-Data-Projects-wirenboard-wb-mge"
        ]
        for (path, expected) in cases {
            XCTAssertEqual(ClaudeSessions.slug(forPath: path), expected, "slug for \(path)")
        }
    }

    func testSlugReplacesDotsAndOtherPunctuation() {
        XCTAssertEqual(ClaudeSessions.slug(forPath: "/tmp/a.b c+d"), "-tmp-a-b-c-d")
        XCTAssertEqual(ClaudeSessions.slug(forPath: "/Users/x/.claude/projects"),
                       "-Users-x--claude-projects")
    }

    func testSlugKeepsDigitsAndHyphens() {
        XCTAssertEqual(ClaudeSessions.slug(forPath: "/a-1/b2"), "-a-1-b2")
    }
}

/// Window titles look like `<chat topic, ellipsised> — <rootName> (Workspace)`.
final class WindowTitleTests: XCTestCase {
    func testEmDashWithWorkspaceSuffix() {
        let parsed = VSCodeWindows.parseTitle("Критические баги и оптим\u{2026} \u{2014} arcextension (Workspace)")
        XCTAssertEqual(parsed.rootName, "arcextension")
        XCTAssertEqual(parsed.chatTopic, "Критические баги и оптим\u{2026}")
        XCTAssertTrue(parsed.isWorkspace)
    }

    func testFolderWindowHasNoWorkspaceSuffix() {
        let parsed = VSCodeWindows.parseTitle("остановись пока \u{2014} glazy_solver")
        XCTAssertEqual(parsed.rootName, "glazy_solver")
        XCTAssertEqual(parsed.chatTopic, "остановись пока")
        XCTAssertFalse(parsed.isWorkspace)
    }

    func testSplitsOnTheLastSeparatorWhenTopicContainsOne() {
        let parsed = VSCodeWindows.parseTitle("a \u{2014} b \u{2014} c \u{2014} home-network (Workspace)")
        XCTAssertEqual(parsed.rootName, "home-network")
        XCTAssertEqual(parsed.chatTopic, "a \u{2014} b \u{2014} c")
    }

    func testPlainHyphenSeparatorIsAccepted() {
        let parsed = VSCodeWindows.parseTitle("some file.ts - research-mcp (Workspace)")
        XCTAssertEqual(parsed.rootName, "research-mcp")
        XCTAssertEqual(parsed.chatTopic, "some file.ts")
    }

    func testEmDashWinsOverHyphenInsideTheTopic() {
        let parsed = VSCodeWindows.parseTitle("fix a-b thing \u{2014} wb-mge (Workspace)")
        XCTAssertEqual(parsed.rootName, "wb-mge")
        XCTAssertEqual(parsed.chatTopic, "fix a-b thing")
    }

    func testTitleWithoutSeparatorIsAllRootName() {
        let parsed = VSCodeWindows.parseTitle("home-network (Workspace)")
        XCTAssertEqual(parsed.rootName, "home-network")
        XCTAssertNil(parsed.chatTopic)
        XCTAssertTrue(parsed.isWorkspace)
    }

    func testEmptyTitle() {
        let parsed = VSCodeWindows.parseTitle("   ")
        XCTAssertNil(parsed.rootName)
        XCTAssertNil(parsed.chatTopic)
    }
}

/// `.code-workspace` and `.vscode/settings.json` are JSONC.
final class JSONCTests: XCTestCase {
    func testSlashesInsideAStringAreNotAComment() throws {
        let text = """
        {
          "url": "https://example.com/path", // trailing comment
          "note": "block /* not */ a comment"
        }
        """
        let object = try XCTUnwrap(try JSONC.parse(text) as? [String: Any])
        XCTAssertEqual(object["url"] as? String, "https://example.com/path")
        XCTAssertEqual(object["note"] as? String, "block /* not */ a comment")
    }

    func testEscapedQuoteDoesNotEndTheString() throws {
        let text = #"{"a": "quote \" then // not a comment", "b": 1}"#
        let object = try XCTUnwrap(try JSONC.parse(text) as? [String: Any])
        XCTAssertEqual(object["a"] as? String, #"quote " then // not a comment"#)
        XCTAssertEqual(object["b"] as? Int, 1)
    }

    func testCommentsAndTrailingCommas() throws {
        let text = """
        // leading comment
        {
          /* block
             comment */
          "peacock.color": "#e2681c",
          "escaped": "a\\\\",
          "list": [1, 2, 3,],
        }
        """
        let object = try XCTUnwrap(try JSONC.parse(text) as? [String: Any])
        XCTAssertEqual(object["peacock.color"] as? String, "#e2681c")
        // A string ending in an escaped backslash must not swallow the closing
        // quote and turn the rest of the file into string content.
        XCTAssertEqual(object["escaped"] as? String, "a\\")
        XCTAssertEqual(object["list"] as? [Int], [1, 2, 3])
    }

    func testUnterminatedBlockCommentDoesNotHang() {
        XCTAssertNoThrow(JSONC.stripped("{\"a\": 1} /* never closed"))
    }
}

final class ColorTests: XCTestCase {
    func testHexNormalization() {
        XCTAssertEqual(WorkspaceIndex.normalizeHex("#E2681C"), "#e2681c")
        XCTAssertEqual(WorkspaceIndex.normalizeHex("e2681c"), "#e2681c")
        XCTAssertEqual(WorkspaceIndex.normalizeHex("#abc"), "#aabbcc")
        XCTAssertEqual(WorkspaceIndex.normalizeHex("#15202b99"), "#15202b")
        XCTAssertNil(WorkspaceIndex.normalizeHex("not-a-color"))
        XCTAssertNil(WorkspaceIndex.normalizeHex(nil))
    }

    func testFallbackColorIsStableAndWellFormed() {
        let first = WorkspaceIndex.fallbackColor(for: "some-project")
        XCTAssertEqual(first, WorkspaceIndex.fallbackColor(for: "some-project"))
        XCTAssertNotEqual(first, WorkspaceIndex.fallbackColor(for: "other-project"))
        XCTAssertEqual(first.count, 7)
        XCTAssertTrue(first.hasPrefix("#"))
    }

    func testWorkspaceColorWinsOverSettingsFile() throws {
        let directory = try makeTemporaryDirectory()
        let workspace = directory.appendingPathComponent("demo.code-workspace")
        // Doubled delimiters: the payload contains `"#`, which would close a
        // single-hash raw string.
        try ##"{"settings": {"peacock.color": "#a43683"}}"##
            .write(to: workspace, atomically: true, encoding: .utf8)
        let settings = directory.appendingPathComponent("settings.json")
        try ##"{"peacock.color": "#000000"}"##.write(to: settings, atomically: true, encoding: .utf8)

        XCTAssertEqual(WorkspaceIndex.resolveColor(workspaceFile: workspace.path,
                                                   settingsFile: settings.path,
                                                   rootName: "demo"),
                       "#a43683")
    }

    func testFallsBackToTitleBarCustomization() throws {
        let directory = try makeTemporaryDirectory()
        let settings = directory.appendingPathComponent("settings.json")
        try ##"{"workbench.colorCustomizations": {"titleBar.activeBackground": "#1857a4"}}"##
            .write(to: settings, atomically: true, encoding: .utf8)

        XCTAssertEqual(WorkspaceIndex.resolveColor(workspaceFile: nil,
                                                   settingsFile: settings.path,
                                                   rootName: "demo"),
                       "#1857a4")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

final class AgentStateTests: XCTestCase {
    func testAggregationPriority() {
        let states: [AgentState] = [.idle, .working, .waiting]
        XCTAssertEqual(states.max(), .waiting)
        XCTAssertEqual([AgentState.waiting, .permission, .working].max(), .permission)
        XCTAssertEqual([AgentState.idle].max(), .idle)
    }

}

/// The window limit decides every percentage the panel shows, and it used to be
/// guessed from whichever numbers happened to be around.
final class ContextWindowTests: XCTestCase {

    func testUnknownLimitStaysUnknownBelowTwoHundredK() {
        // The 200k default is a guess, and guessing it turned a 1M session at
        // 19% into "194k (97%)". No denominator is better than a wrong one.
        XCTAssertNil(ClaudeSessions.contextLimitTokens(isExtendedContext: false, usedTokens: 194_000))
        XCTAssertNil(ClaudeSessions.contextLimitTokens(isExtendedContext: false, usedTokens: 10_000))
    }

    func testCountAboveTwoHundredKProvesTheLargeWindow() {
        XCTAssertEqual(ClaudeSessions.contextLimitTokens(isExtendedContext: false, usedTokens: 460_494),
                       1_000_000)
    }

    func testExtendedContextModelIsRecognisedOnEitherIdentifier() {
        // The transcript never carries the suffix, only statusLine's `model.id`
        // does — so checking the transcript alone found it nowhere.
        XCTAssertTrue(ClaudeSessions.isExtendedContextModel(["claude-opus-5[1m]", "claude-opus-5"]))
        XCTAssertTrue(ClaudeSessions.isExtendedContextModel([nil, "claude-opus-5[1m]"]))
        XCTAssertFalse(ClaudeSessions.isExtendedContextModel(["claude-opus-5", nil]))
        XCTAssertFalse(ClaudeSessions.isExtendedContextModel([nil, nil]))
    }

    func testExtendedModelGivesOneMillionWellBelowTwoHundredK() {
        XCTAssertEqual(ClaudeSessions.contextLimitTokens(isExtendedContext: true, usedTokens: 194_000),
                       1_000_000)
    }

    /// The reproduced defect, end to end: a 1M session at 19% used to render as
    /// `194k (97%)` because the transcript numerator met a made-up denominator.
    func testOneMillionSessionBelowTwoHundredKIsNotReportedAsNearlyFull() {
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.model = "claude-opus-5"
        transcript.contextUsedTokens = 194_000

        let withoutMetrics = ClaudeSessions.contextUsage(transcript: transcript, metrics: nil)
        XCTAssertEqual(withoutMetrics.used, 194_000)
        XCTAssertNil(withoutMetrics.limit)

        var metrics = ClaudeSessions.MetricsStatus()
        metrics.modelId = "claude-opus-5[1m]"
        let withModelId = ClaudeSessions.contextUsage(transcript: transcript, metrics: metrics)
        XCTAssertEqual(withModelId.limit, 1_000_000)
    }

    func testMetricsSupplyBothNumbersOrNeither() {
        // statusLine and the transcript are sampled at different moments; taking
        // the numerator from one and the denominator from the other is how the
        // percentages went wrong in the first place.
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.contextUsedTokens = 460_000

        var metrics = ClaudeSessions.MetricsStatus()
        metrics.usedTokens = 32_679
        metrics.contextWindowSize = 200_000

        let usage = ClaudeSessions.contextUsage(transcript: transcript, metrics: metrics)
        XCTAssertEqual(usage.used, 32_679)
        XCTAssertEqual(usage.limit, 200_000)
    }

    func testPercentageFillsInAMissingWindowSize() {
        var metrics = ClaudeSessions.MetricsStatus()
        metrics.usedTokens = 20_000
        metrics.usedPercentage = 10

        let usage = ClaudeSessions.contextUsage(transcript: ClaudeSessions.TranscriptSummary(), metrics: metrics)
        XCTAssertEqual(usage.used, 20_000)
        XCTAssertEqual(usage.limit, 200_000)
    }

    func testZeroPercentageIsNotDividedBy() {
        XCTAssertNil(ClaudeSessions.limitFromPercentage(usedTokens: 100, percentage: 0))
        XCTAssertNil(ClaudeSessions.limitFromPercentage(usedTokens: 100, percentage: nil))
    }
}

/// The hook file is a level, not an event stream: whatever the last delivered
/// hook wrote stays there until the next one arrives.
final class SessionStateTests: XCTestCase {

    func testHookWinsWhileItIsFresh() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .waiting
        transcript.lastActivity = now.addingTimeInterval(-30)

        let hook = ClaudeSessions.HookStatus(state: .working, event: "UserPromptSubmit", timestamp: now)
        let resolved = ClaudeSessions.resolveState(hook: hook, transcript: transcript, now: now)
        XCTAssertEqual(resolved.state, .working)
        XCTAssertEqual(resolved.source, .hook)
    }

    func testTranscriptWinsWhenItIsClearlyNewerThanTheHook() {
        // A `Stop` that never arrived leaves `working` on disk forever; the
        // transcript kept moving, which proves the hook is behind.
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .waiting
        transcript.lastActivity = now.addingTimeInterval(-10)

        let hook = ClaudeSessions.HookStatus(state: .working,
                                             event: "UserPromptSubmit",
                                             timestamp: now.addingTimeInterval(-40 * 60))
        let resolved = ClaudeSessions.resolveState(hook: hook, transcript: transcript, now: now)
        XCTAssertEqual(resolved.state, .waiting)
        XCTAssertEqual(resolved.source, .transcript)
    }

    /// The real session behind the defect report: hook `working` from 39 minutes
    /// ago, transcript touched 12 seconds ago — and the agent really is working.
    func testStillWorkingSessionStaysWorking() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .working
        transcript.lastActivity = now.addingTimeInterval(-12)

        let hook = ClaudeSessions.HookStatus(state: .working,
                                             event: "UserPromptSubmit",
                                             timestamp: now.addingTimeInterval(-39.6 * 60))
        XCTAssertEqual(ClaudeSessions.resolveState(hook: hook, transcript: transcript, now: now).state, .working)
    }

    func testStaleWorkingHookWithNoOtherEvidenceDegradesToIdle() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.lastActivity = now.addingTimeInterval(-40 * 60)

        let hook = ClaudeSessions.HookStatus(state: .working,
                                             event: "UserPromptSubmit",
                                             timestamp: now.addingTimeInterval(-40 * 60))
        let resolved = ClaudeSessions.resolveState(hook: hook, transcript: transcript, now: now)
        XCTAssertEqual(resolved.state, .idle)
        XCTAssertEqual(resolved.source, .unknown)
    }

    func testWaitingAndPermissionAreNeverAgedOut() {
        // Both describe a condition that lasts until the user acts, so an old
        // timestamp says nothing against them.
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.lastActivity = now.addingTimeInterval(-3 * 3600)

        for state in [AgentState.waiting, .permission] {
            let hook = ClaudeSessions.HookStatus(state: state,
                                                 event: "Notification",
                                                 timestamp: now.addingTimeInterval(-3 * 3600))
            XCTAssertEqual(ClaudeSessions.resolveState(hook: hook, transcript: transcript, now: now).state, state)
        }
    }

    func testWithoutAHookTheTranscriptIsUsed() {
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .waiting
        let resolved = ClaudeSessions.resolveState(hook: nil, transcript: transcript)
        XCTAssertEqual(resolved.state, .waiting)
        XCTAssertEqual(resolved.source, .transcript)
    }

    func testWithNoSourceAtAllTheSessionIsIdle() {
        let resolved = ClaudeSessions.resolveState(hook: nil, transcript: ClaudeSessions.TranscriptSummary())
        XCTAssertEqual(resolved.state, .idle)
        XCTAssertEqual(resolved.source, .unknown)
    }
}

/// Joining windows, projects and sessions into rows.
final class SnapshotAssemblyTests: XCTestCase {

    /// The state the user actually sees before granting Accessibility: sessions
    /// read from disk, no windows at all. They used to be reachable only through
    /// the window list, so all of them disappeared.
    func testSessionsSurviveAnEmptyWindowList() throws {
        let project = makeProject(path: "/p/home-network", rootName: "home-network")
        let session = makeSession(id: "s1", cwd: "/p/home-network", state: .working)

        let snapshot = DataSource.assemble(projects: [project],
                                           windows: [],
                                           sessions: [session],
                                           accessibilityTrusted: false)

        XCTAssertTrue(snapshot.openWindows.isEmpty)
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == project.path })
        XCTAssertEqual(row.sessions.map(\.sessionId), ["s1"])
        XCTAssertEqual(row.state, .working)
        XCTAssertEqual(row.stateCount, 1)
        XCTAssertEqual(snapshot.rows.flatMap(\.sessions).count, 1)
    }

    func testEverySessionAppearsExactlyOnceWithoutWindows() {
        let projects = [makeProject(path: "/p/a", rootName: "a"), makeProject(path: "/p/b", rootName: "b")]
        let sessions = [makeSession(id: "s1", cwd: "/p/a", state: .working),
                        makeSession(id: "s2", cwd: "/p/a", state: .waiting),
                        makeSession(id: "s3", cwd: "/p/b", state: .permission),
                        makeSession(id: "s4", cwd: "/elsewhere/tool", state: .idle)]

        let snapshot = DataSource.assemble(projects: projects,
                                           windows: [],
                                           sessions: sessions,
                                           accessibilityTrusted: false)

        XCTAssertEqual(Set(snapshot.rows.flatMap(\.sessions).map(\.sessionId)), ["s1", "s2", "s3", "s4"])
        XCTAssertEqual(snapshot.rows.flatMap(\.sessions).count, 4)
        // The row shows the highest state of the sessions it holds.
        XCTAssertEqual(snapshot.projects.first { $0.project?.path == "/p/a" }?.state, .waiting)
        XCTAssertEqual(snapshot.projects.first { $0.project?.path == "/p/a" }?.stateCount, 1)
    }

    func testAWindowStillTakesItsProjectsSessions() {
        let project = makeProject(path: "/p/home-network", rootName: "home-network")
        let window = makeWindow(index: 0, title: "topic \u{2014} home-network (Workspace)")
        let session = makeSession(id: "s1", cwd: "/p/home-network", state: .working)

        let snapshot = DataSource.assemble(projects: [project],
                                           windows: [window],
                                           sessions: [session],
                                           accessibilityTrusted: true)

        XCTAssertEqual(snapshot.openWindows.first?.sessions.map(\.sessionId), ["s1"])
        // And it is not counted a second time on a project row.
        XCTAssertEqual(snapshot.rows.flatMap(\.sessions).count, 1)
    }

    // MARK: - Fixtures

    private func makeProject(path: String, rootName: String) -> ProjectInfo {
        ProjectInfo(path: path,
                    displayName: (path as NSString).lastPathComponent,
                    rootName: rootName,
                    colorHex: "#123456",
                    workspaceFile: nil,
                    mtime: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func makeWindow(index: Int, title: String) -> VSCodeWindowInfo {
        let parsed = VSCodeWindows.parseTitle(title)
        return VSCodeWindowInfo(pid: 1,
                                windowIndex: index,
                                title: title,
                                rootName: parsed.rootName,
                                chatTopicPrefix: parsed.chatTopic,
                                isWorkspace: parsed.isWorkspace,
                                isMinimized: false)
    }

    private func makeSession(id: String, cwd: String, state: AgentState) -> ClaudeSessionInfo {
        ClaudeSessionInfo(sessionId: id,
                          pid: 100,
                          cwd: cwd,
                          name: nil,
                          aiTitle: "topic \(id)",
                          lastPrompt: nil,
                          state: state,
                          stateSource: .hook,
                          model: "claude-opus-5",
                          contextUsedTokens: 1000,
                          contextLimitTokens: nil,
                          activeSubagents: 0,
                          subagents: [],
                          lastActivity: Date(timeIntervalSince1970: 1_700_000_000))
    }
}

/// Scanning the project roots.
final class WorkspaceScanTests: XCTestCase {

    /// `smarthome_ng/` is a project and holds ten repositories of its own; they
    /// used to become rows, and the nested `mqtt2influx` then fought the real
    /// top-level one for the same `rootName`.
    func testScanDoesNotDescendIntoADirectoryThatIsItselfAProject() throws {
        let root = try makeTemporaryDirectory()
        try makeProjectDirectory(root.appendingPathComponent("smarthome_ng"))
        try makeProjectDirectory(root.appendingPathComponent("smarthome_ng/mqtt2influx"))
        try makeProjectDirectory(root.appendingPathComponent("mqtt2influx"))

        let paths = scan(root: root, depth: 2).map(\.path)
        XCTAssertTrue(paths.contains(root.appendingPathComponent("smarthome_ng").path))
        XCTAssertTrue(paths.contains(root.appendingPathComponent("mqtt2influx").path))
        XCTAssertFalse(paths.contains(root.appendingPathComponent("smarthome_ng/mqtt2influx").path))
    }

    /// The grouping directories the depth exists for hold no `.git` and no
    /// workspace file, so their children are still found.
    func testScanStillReachesProjectsInsideAGroupingDirectory() throws {
        let root = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("wirenboard"),
                                                withIntermediateDirectories: true)
        try makeProjectDirectory(root.appendingPathComponent("wirenboard/wb-mge"))

        let projects = scan(root: root, depth: 2)
        XCTAssertEqual(projects.map(\.path), [root.appendingPathComponent("wirenboard/wb-mge").path])
        XCTAssertEqual(projects.first?.displayName, "wirenboard/wb-mge")
    }

    func testRootNameKeepsTheWholeWorkspaceFileName() throws {
        let root = try makeTemporaryDirectory()
        let directory = root.appendingPathComponent("demo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A substring replacement of ".code-workspace" would leave "my-legacy".
        try "{}".write(to: directory.appendingPathComponent("my.code-workspace.code-workspace"),
                       atomically: true,
                       encoding: .utf8)

        XCTAssertEqual(scan(root: root, depth: 1).first?.rootName, "my.code-workspace")
    }

    private func scan(root: URL, depth: Int) -> [ProjectInfo] {
        var config = Config.default
        config.projectRoots = [root.path]
        config.scanDepth = depth
        return WorkspaceIndex().projects(config: config)
    }

    private func makeProjectDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.standardizedFileURL
    }
}

/// Reading transcript tails.
final class TailLinesTests: XCTestCase {

    /// `split(separator: "\n")` compares graphemes and CRLF is one grapheme, so
    /// a CRLF transcript came back as a single line and its whole summary was
    /// silently lost.
    func testCRLFTranscriptStillSplitsIntoLines() throws {
        let url = try makeTemporaryFile()
        try "{\"a\":1}\r\n{\"a\":2}\r\n".write(to: url, atomically: true, encoding: .utf8)

        let lines = ClaudeSessions.tailLines(atPath: url.path, maxBytes: 64 * 1024)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try XCTUnwrap(try JSONC.parse(lines[1]) as? [String: Any])["a"] as? Int, 2)
    }

    func testFirstPartialLineIsDroppedOnlyWhenTheFileWasTruncated() throws {
        let url = try makeTemporaryFile()
        try "one\ntwo\nthree\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(ClaudeSessions.tailLines(atPath: url.path, maxBytes: 64 * 1024), ["one", "two", "three"])
        // A window of 9 bytes starts inside "two", so that partial line goes.
        XCTAssertEqual(ClaudeSessions.tailLines(atPath: url.path, maxBytes: 9), ["three"])
    }

    private func makeTemporaryFile() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-tail-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

final class ConfigTests: XCTestCase {
    func testMissingFileYieldsDefaults() {
        let missing = URL(fileURLWithPath: "/nonexistent/vscode-switcher/config.json")
        XCTAssertEqual(Config.load(from: missing), Config.default)
    }

    func testPartialFileOverridesOnlyTheKeysItHas() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-config-\(UUID().uuidString).json")
        try #"{"scanDepth": 3, "panelWidth": 420, "editorBundleID": ""}"#
            .write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let config = Config.load(from: url)
        XCTAssertEqual(config.scanDepth, 3)
        XCTAssertEqual(config.panelWidth, 420)
        XCTAssertEqual(config.editorBundleID, Config.default.editorBundleID)
        XCTAssertEqual(config.projectRoots, Config.default.projectRoots)
    }

    func testTildeExpansion() {
        var config = Config.default
        config.projectRoots = ["~/Data/Projects", "~/Data/Projects"]
        XCTAssertEqual(config.resolvedProjectRoots.count, 1)
        XCTAssertFalse(config.resolvedProjectRoots[0].path.contains("~"))
    }
}
