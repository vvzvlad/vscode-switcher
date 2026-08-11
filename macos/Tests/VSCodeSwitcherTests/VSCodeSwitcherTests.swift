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

    /// The setting is an alias, not an id, and the CLI accepts the marker on
    /// every one of them. Matching known strings instead of the marker would
    /// have recognised `claude-opus-5[1m]` and missed the `opus[1m]` the user
    /// actually has in their settings.
    func testEveryAcceptedFormOfTheMarkerIsRecognised() {
        let extended = ["opus[1m]", "sonnet[1m]", "opusplan[1m]", "fable[1m]",
                        "claude-opus-5[1m]", "claude-opus-4-5[1m]",
                        "claude-sonnet-4-5-20250929[1m]", "sonnet-4-6[1m]"]
        for identifier in extended {
            XCTAssertTrue(ClaudeSessions.isExtendedContextModel([identifier]), identifier)
        }
        // Aliases without a suffix are the common case and must not be read as
        // extended, and neither must a bare id that merely mentions a `1`.
        let plain = ["opus", "sonnet", "haiku", "default", "claude-opus-5",
                     "claude-haiku-4-5-20251001", "claude-sonnet-4-1", ""]
        for identifier in plain {
            XCTAssertFalse(ClaudeSessions.isExtendedContextModel([identifier]), identifier)
        }
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

    /// The numbers as they really arrive: `used_percentage` is a whole number,
    /// so the quotient is off by thousands. The old test used 20 000 at 10%,
    /// which divides exactly and hid that entirely.
    func testPercentageFillsInAMissingWindowSize() {
        var metrics = ClaudeSessions.MetricsStatus()
        metrics.usedTokens = 93_953
        metrics.usedPercentage = 46

        // The raw quotient here is 204 245.
        let usage = ClaudeSessions.contextUsage(transcript: ClaudeSessions.TranscriptSummary(), metrics: metrics)
        XCTAssertEqual(usage.used, 93_953)
        XCTAssertEqual(usage.limit, 200_000)
    }

    func testPercentageRecognisesTheLargeWindowToo() {
        XCTAssertEqual(ClaudeSessions.limitFromPercentage(usedTokens: 463_000, percentage: 46), 1_000_000)
        XCTAssertEqual(ClaudeSessions.limitFromPercentage(usedTokens: 20_000, percentage: 10), 200_000)
    }

    /// A window size nobody offers still comes back round rather than as a
    /// quotient with five significant digits.
    func testPercentageOfAnUnknownWindowIsRounded() {
        // 300k at 33% divides to 909 090, which is neither window size.
        XCTAssertEqual(ClaudeSessions.limitFromPercentage(usedTokens: 300_000, percentage: 33), 910_000)
    }

    func testZeroPercentageIsNotDividedBy() {
        XCTAssertNil(ClaudeSessions.limitFromPercentage(usedTokens: 100, percentage: 0))
        XCTAssertNil(ClaudeSessions.limitFromPercentage(usedTokens: 100, percentage: nil))
    }

    /// `.metrics.json` lives until `SessionEnd` and is never rewritten once
    /// statusLine stops working — a replaced status line, `jq` gone from PATH,
    /// hooks uninstalled. Its numbers then stayed authoritative forever and a
    /// session at 46% of its window rendered as a confident 1%.
    func testStaleMetricsLoseToATranscriptThatKeptMoving() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.contextUsedTokens = 460_494
        transcript.lastActivity = now

        var metrics = ClaudeSessions.MetricsStatus()
        metrics.usedTokens = 5_000
        metrics.contextWindowSize = 200_000
        metrics.timestamp = now.addingTimeInterval(-3 * 3600)

        let usage = ClaudeSessions.contextUsage(transcript: transcript, metrics: metrics)
        XCTAssertEqual(usage.used, 460_494)
        XCTAssertEqual(usage.limit, 1_000_000)
    }

    func testFreshMetricsStillWinOverTheTranscript() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.contextUsedTokens = 460_494
        transcript.lastActivity = now

        var metrics = ClaudeSessions.MetricsStatus()
        metrics.usedTokens = 32_679
        metrics.contextWindowSize = 200_000
        metrics.timestamp = now.addingTimeInterval(-5)

        let usage = ClaudeSessions.contextUsage(transcript: transcript, metrics: metrics)
        XCTAssertEqual(usage.used, 32_679)
        XCTAssertEqual(usage.limit, 200_000)
    }

    /// Nothing to fall back to: the transcript has no count of its own, so even
    /// ancient metrics are the only numbers there are.
    func testStaleMetricsAreKeptWhenTheTranscriptHasNoCount() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.lastActivity = now

        var metrics = ClaudeSessions.MetricsStatus()
        metrics.usedTokens = 5_000
        metrics.contextWindowSize = 200_000
        metrics.timestamp = now.addingTimeInterval(-3 * 3600)

        let usage = ClaudeSessions.contextUsage(transcript: transcript, metrics: metrics)
        XCTAssertEqual(usage.used, 5_000)
        XCTAssertEqual(usage.limit, 200_000)
    }

    /// The metrics branch must not read the transcript at all — it claims to be
    /// one source sampled at one moment.
    func testMetricsBranchIgnoresTheTranscriptModel() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        // A transcript never carries the `[1m]` suffix; this is what the branch
        // used to consult anyway.
        transcript.model = "claude-opus-5[1m]"
        transcript.lastActivity = now

        var metrics = ClaudeSessions.MetricsStatus()
        metrics.modelId = "claude-opus-5"
        metrics.usedTokens = 100_000
        metrics.timestamp = now

        XCTAssertNil(ClaudeSessions.contextUsage(transcript: transcript, metrics: metrics).limit)
    }

    /// The case the whole configuration source exists for: `.metrics.json`
    /// covers one session in six, so almost every session used to show a bare
    /// token count. The user's `~/.claude/settings.json` says `opus[1m]`, which
    /// is Claude Code's own way of asking for the large window.
    func testConfiguredModelSuppliesTheLimitWhenNothingElseCan() {
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.model = "claude-opus-5"
        transcript.contextUsedTokens = 186_000

        XCTAssertNil(ClaudeSessions.contextUsage(transcript: transcript, metrics: nil).limit)

        let usage = ClaudeSessions.contextUsage(transcript: transcript,
                                                metrics: nil,
                                                configuredModel: "opus[1m]")
        XCTAssertEqual(usage.used, 186_000)
        XCTAssertEqual(usage.limit, 1_000_000)
    }

    /// A configured model without the marker adds nothing: the default window is
    /// 200k, but substituting it is the guess that produced `194k (97%)`.
    func testConfiguredModelWithoutTheMarkerLeavesTheLimitUnknown() {
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.contextUsedTokens = 186_000

        XCTAssertNil(ClaudeSessions.contextUsage(transcript: transcript,
                                                 metrics: nil,
                                                 configuredModel: "opus").limit)
        XCTAssertNil(ClaudeSessions.contextUsage(transcript: transcript,
                                                 metrics: nil,
                                                 configuredModel: nil).limit)
    }

    /// `contextWindowSize` is the only source that measured the session itself.
    /// The setting decides what a *new* session starts on, so a session moved to
    /// another model with `/model` would be misreported if it could override.
    func testFreshMetricsOutrankTheConfiguredModel() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.contextUsedTokens = 100_000
        transcript.lastActivity = now

        var metrics = ClaudeSessions.MetricsStatus()
        metrics.modelId = "claude-haiku-4-5-20251001"
        metrics.usedTokens = 32_679
        metrics.contextWindowSize = 200_000
        metrics.timestamp = now

        let usage = ClaudeSessions.contextUsage(transcript: transcript,
                                                metrics: metrics,
                                                configuredModel: "opus[1m]")
        XCTAssertEqual(usage.used, 32_679)
        XCTAssertEqual(usage.limit, 200_000)
    }

    /// The same, one rung down: a payload without `contextWindowSize` still
    /// measured its own window through `usedPercentage`.
    func testPercentageDerivedLimitOutranksTheConfiguredModel() {
        let now = Date()
        var metrics = ClaudeSessions.MetricsStatus()
        metrics.usedTokens = 93_953
        metrics.usedPercentage = 46
        metrics.timestamp = now

        let usage = ClaudeSessions.contextUsage(transcript: ClaudeSessions.TranscriptSummary(),
                                                metrics: metrics,
                                                configuredModel: "opus[1m]")
        XCTAssertEqual(usage.limit, 200_000)
    }

    /// Metrics that say nothing about the window are not a reason to say nothing
    /// either: the configured model is still the last rung above `nil`.
    func testConfiguredModelStillAppliesWhenMetricsCarryNoWindow() {
        let now = Date()
        var metrics = ClaudeSessions.MetricsStatus()
        metrics.modelId = "claude-opus-5"
        metrics.usedTokens = 74_000
        metrics.timestamp = now

        let transcript = ClaudeSessions.TranscriptSummary()
        XCTAssertNil(ClaudeSessions.contextUsage(transcript: transcript, metrics: metrics).limit)
        XCTAssertEqual(ClaudeSessions.contextUsage(transcript: transcript,
                                                   metrics: metrics,
                                                   configuredModel: "opus[1m]").limit,
                       1_000_000)
    }

    /// Stale metrics still lose to a transcript that kept moving, and the
    /// configured model must not smuggle their window back in.
    func testStaleMetricsStillLoseWithAConfiguredModelPresent() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.contextUsedTokens = 186_000
        transcript.lastActivity = now

        var metrics = ClaudeSessions.MetricsStatus()
        metrics.usedTokens = 5_000
        metrics.contextWindowSize = 200_000
        metrics.timestamp = now.addingTimeInterval(-3 * 3600)

        let usage = ClaudeSessions.contextUsage(transcript: transcript,
                                                metrics: metrics,
                                                configuredModel: "opus[1m]")
        XCTAssertEqual(usage.used, 186_000)
        XCTAssertEqual(usage.limit, 1_000_000)
    }

    /// A session with no numbers at all stays without numbers; a configured
    /// model is a denominator, not a numerator.
    func testConfiguredModelDoesNotInventAUsedCount() {
        let usage = ClaudeSessions.contextUsage(transcript: ClaudeSessions.TranscriptSummary(),
                                                metrics: nil,
                                                configuredModel: "opus[1m]")
        XCTAssertNil(usage.used)
        XCTAssertNil(usage.limit)
    }
}

/// Claude Code's own settings say which model a session in a given directory
/// starts on, and `[1m]` in that alias is a request for the 1M window. This is
/// the only source that covers the sessions `.metrics.json` never reaches — one
/// in six of them has that file.
final class ConfiguredModelTests: XCTestCase {

    func testUserSettingsApplyWhenTheProjectSaysNothing() throws {
        let home = try makeTemporaryDirectory()
        let project = try makeTemporaryDirectory()
        try write(##"{"model": "opus[1m]", "permissions": {"allow": []}}"##,
                  to: home.appendingPathComponent("settings.json"))

        XCTAssertEqual(ClaudeSessions.configuredModelIdentifier(cwd: project.path,
                                                                claudeHome: home,
                                                                environmentModel: nil),
                       "opus[1m]")
    }

    /// Sessions live in different directories and a project may pin its own
    /// model, so the answer has to be per-`cwd`: a project on plain `sonnet`
    /// must not inherit the user's 1M default.
    func testProjectSettingsOverrideTheUserDefault() throws {
        let home = try makeTemporaryDirectory()
        let project = try makeTemporaryDirectory()
        try write(##"{"model": "opus[1m]"}"##, to: home.appendingPathComponent("settings.json"))
        try write(##"{"model": "sonnet"}"##, to: try claudeDirectory(in: project)
            .appendingPathComponent("settings.json"))

        XCTAssertEqual(ClaudeSessions.configuredModelIdentifier(cwd: project.path,
                                                                claudeHome: home,
                                                                environmentModel: nil),
                       "sonnet")
        XCTAssertFalse(ClaudeSessions.isExtendedContextModel([
            ClaudeSessions.configuredModelIdentifier(cwd: project.path,
                                                     claudeHome: home,
                                                     environmentModel: nil)
        ]))
    }

    func testLocalProjectSettingsOverrideTheSharedProjectFile() throws {
        let home = try makeTemporaryDirectory()
        let project = try makeTemporaryDirectory()
        let claude = try claudeDirectory(in: project)
        try write(##"{"model": "haiku"}"##, to: home.appendingPathComponent("settings.json"))
        try write(##"{"model": "sonnet"}"##, to: claude.appendingPathComponent("settings.json"))
        try write(##"{"model": "opus[1m]"}"##, to: claude.appendingPathComponent("settings.local.json"))

        XCTAssertEqual(ClaudeSessions.configuredModelIdentifier(cwd: project.path,
                                                                claudeHome: home,
                                                                environmentModel: nil),
                       "opus[1m]")
    }

    /// The inherited environment is the most global signal of the four, and a
    /// menu bar agent started by launchd may not have it at all, so it only
    /// answers when no file did.
    func testEnvironmentIsTheLastResort() throws {
        let home = try makeTemporaryDirectory()
        let project = try makeTemporaryDirectory()

        XCTAssertEqual(ClaudeSessions.configuredModelIdentifier(cwd: project.path,
                                                                claudeHome: home,
                                                                environmentModel: "sonnet[1m]"),
                       "sonnet[1m]")

        try write(##"{"model": "haiku"}"##, to: home.appendingPathComponent("settings.json"))
        XCTAssertEqual(ClaudeSessions.configuredModelIdentifier(cwd: project.path,
                                                                claudeHome: home,
                                                                environmentModel: "sonnet[1m]"),
                       "haiku")
    }

    func testNothingConfiguredAnywhereIsNil() throws {
        let home = try makeTemporaryDirectory()
        let project = try makeTemporaryDirectory()
        XCTAssertNil(ClaudeSessions.configuredModelIdentifier(cwd: project.path,
                                                              claudeHome: home,
                                                              environmentModel: nil))
    }

    /// A settings file that pins nothing must not stop the chain: the user
    /// default still applies to a project that only lists permissions, which is
    /// what every `.claude/settings.local.json` on the machine actually holds.
    func testASettingsFileWithoutAModelDoesNotShadowTheUserDefault() throws {
        let home = try makeTemporaryDirectory()
        let project = try makeTemporaryDirectory()
        try write(##"{"model": "opus[1m]"}"##, to: home.appendingPathComponent("settings.json"))
        try write(##"{"permissions": {"allow": ["Bash(ls:*)"]}}"##,
                  to: try claudeDirectory(in: project).appendingPathComponent("settings.local.json"))

        XCTAssertEqual(ClaudeSessions.configuredModelIdentifier(cwd: project.path,
                                                                claudeHome: home,
                                                                environmentModel: nil),
                       "opus[1m]")
    }

    /// Settings files are hand-edited, so half of them are mid-write or broken
    /// at any moment. A refresh must not care.
    func testUnreadableSettingsAreIgnoredRatherThanFatal() throws {
        let home = try makeTemporaryDirectory()
        let project = try makeTemporaryDirectory()
        try write("{ not json at all", to: try claudeDirectory(in: project)
            .appendingPathComponent("settings.json"))
        try write(##"{"model": "opus[1m]"}"##, to: home.appendingPathComponent("settings.json"))

        XCTAssertEqual(ClaudeSessions.configuredModelIdentifier(cwd: project.path,
                                                                claudeHome: home,
                                                                environmentModel: nil),
                       "opus[1m]")
    }

    /// `.claude/settings.json` is written by hand and by tooling, so it carries
    /// comments and trailing commas as often as the VSCode files do.
    func testSettingsAreReadAsJSONC() {
        let dict = try? JSONC.parse(##"""
        {
          // pinned globally
          "model": "opus[1m]",
        }
        """##) as? [String: Any]
        XCTAssertEqual(ClaudeSessions.modelSetting(in: dict ?? [:]), "opus[1m]")
    }

    func testEnvBlockPinsTheModelAndLosesToAnExplicitOne() {
        XCTAssertEqual(ClaudeSessions.modelSetting(in: ["env": ["ANTHROPIC_MODEL": "sonnet[1m]"]]),
                       "sonnet[1m]")
        XCTAssertEqual(ClaudeSessions.modelSetting(in: ["model": "haiku",
                                                        "env": ["ANTHROPIC_MODEL": "sonnet[1m]"]]),
                       "haiku")
        // The user's own file has an empty `env` and a `model`; an empty string
        // is not a pin either.
        XCTAssertNil(ClaudeSessions.modelSetting(in: ["env": [:]]))
        XCTAssertNil(ClaudeSessions.modelSetting(in: ["model": "   "]))
        XCTAssertNil(ClaudeSessions.modelSetting(in: [:]))
    }

    /// Settings are re-read for every session on every snapshot — once a second
    /// while the panel is open — so the value has to survive as long as the file
    /// does and follow it when it changes.
    func testTheParsedSettingIsCachedUntilTheFileChanges() throws {
        let home = try makeTemporaryDirectory()
        let file = home.appendingPathComponent("settings.json")
        try write(##"{"model": "opus[1m]"}"##, to: file)
        XCTAssertEqual(ClaudeSessions.modelSetting(atPath: file.path), "opus[1m]")

        try write(##"{"model": "sonnet"}"##, to: file)
        // Same path, different bytes and mtime: the cache key covers both.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: file.path)
        XCTAssertEqual(ClaudeSessions.modelSetting(atPath: file.path), "sonnet")
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func claudeDirectory(in project: URL) throws -> URL {
        let url = project.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
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

    /// The gap the test above walked around by aging the transcript too: a
    /// transcript touched a second ago is proof the agent is alive, and it is
    /// available even when the tail yielded no state at all.
    ///
    /// `fallbackState == nil` next to a live transcript is not hypothetical —
    /// a `stop_reason` outside the three known values (39 records in 11 114 on
    /// real data), or a single assistant record larger than the whole 512 KiB
    /// tail window (93 transcripts on this machine hold records over 200 KiB,
    /// the largest 2.0 MB).
    func testFreshTranscriptKeepsAStaleWorkingHookAliveWithoutAFallbackState() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = nil
        transcript.lastActivity = now.addingTimeInterval(-1)

        let hook = ClaudeSessions.HookStatus(state: .working,
                                             event: "UserPromptSubmit",
                                             timestamp: now.addingTimeInterval(-301))
        XCTAssertEqual(ClaudeSessions.resolveState(hook: hook, transcript: transcript, now: now).state, .working)
    }

    func testStaleWorkingHookWithAStaleTranscriptStillDegrades() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.lastActivity = now.addingTimeInterval(-ClaudeSessions.transcriptLivenessSeconds - 1)

        let hook = ClaudeSessions.HookStatus(state: .working,
                                             event: "UserPromptSubmit",
                                             timestamp: now.addingTimeInterval(-301))
        XCTAssertEqual(ClaudeSessions.resolveState(hook: hook, transcript: transcript, now: now).state, .idle)
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

    /// A permission dialog is invisible to the transcript: the last assistant
    /// record still says `tool_use`, and the file goes on being touched. Every
    /// such touch used to overrule the hook and turn the orange indicator off
    /// while the dialog was still on screen.
    func testATouchedTranscriptDoesNotClearAPermissionWait() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .working
        transcript.lastActivity = now.addingTimeInterval(-1)

        for state in [AgentState.permission, .waiting] {
            let hook = ClaudeSessions.HookStatus(state: state,
                                                 event: "Notification",
                                                 timestamp: now.addingTimeInterval(-3 * 3600))
            let resolved = ClaudeSessions.resolveState(hook: hook, transcript: transcript, now: now)
            XCTAssertEqual(resolved.state, state)
            XCTAssertEqual(resolved.source, .hook)
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

    /// Six agents started in the same directory outside every scan root used to
    /// produce six identical rows, while the same six inside a project were
    /// aggregated into one.
    func testOrphanSessionsFromOneDirectoryBecomeASingleRow() throws {
        let sessions = [makeSession(id: "s1", cwd: "/elsewhere/tool", state: .working),
                        makeSession(id: "s2", cwd: "/elsewhere/tool", state: .permission),
                        makeSession(id: "s3", cwd: "/elsewhere/tool", state: .working),
                        makeSession(id: "s4", cwd: "/elsewhere/other", state: .idle)]

        let snapshot = DataSource.assemble(projects: [],
                                           windows: [],
                                           sessions: sessions,
                                           accessibilityTrusted: false)

        XCTAssertEqual(snapshot.projects.count, 2)
        let row = try XCTUnwrap(snapshot.projects.first { $0.displayName == "tool" })
        XCTAssertEqual(row.sessions.map(\.sessionId), ["s1", "s2", "s3"])
        XCTAssertEqual(row.state, .permission)
        XCTAssertEqual(row.stateCount, 1)
        XCTAssertEqual(Set(snapshot.rows.map(\.id)).count, snapshot.rows.count)
        XCTAssertEqual(snapshot.rows.flatMap(\.sessions).count, 4)
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
        TestFixtures.window(index: index, title: title)
    }

    private func makeSession(id: String, cwd: String, state: AgentState) -> ClaudeSessionInfo {
        TestFixtures.session(id: id, cwd: cwd, state: state)
    }
}

/// Fixtures shared by the assembly, identity and distribution suites.
enum TestFixtures {
    static func project(path: String, rootName: String) -> ProjectInfo {
        ProjectInfo(path: path,
                    displayName: (path as NSString).lastPathComponent,
                    rootName: rootName,
                    colorHex: "#123456",
                    workspaceFile: nil,
                    mtime: Date(timeIntervalSince1970: 1_700_000_000))
    }

    static func window(index: Int,
                       title: String,
                       pid: Int32 = 1,
                       windowNumber: CGWindowID? = nil) -> VSCodeWindowInfo {
        let parsed = VSCodeWindows.parseTitle(title)
        return VSCodeWindowInfo(pid: pid,
                                windowIndex: index,
                                windowNumber: windowNumber,
                                title: title,
                                rootName: parsed.rootName,
                                chatTopicPrefix: parsed.chatTopic,
                                isWorkspace: parsed.isWorkspace,
                                isMinimized: false)
    }

    static func session(id: String,
                        cwd: String,
                        state: AgentState,
                        topic: String? = nil,
                        lastActivity: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> ClaudeSessionInfo {
        ClaudeSessionInfo(sessionId: id,
                          pid: 100,
                          cwd: cwd,
                          name: nil,
                          aiTitle: topic ?? "topic \(id)",
                          lastPrompt: nil,
                          state: state,
                          stateSource: .hook,
                          model: "claude-opus-5",
                          contextUsedTokens: 1000,
                          contextLimitTokens: nil,
                          activeSubagents: 0,
                          subagents: [],
                          lastActivity: lastActivity)
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

    /// The whole scan rests on this: the root is descended into whatever it
    /// looks like. A `~/Data/Projects` that is itself a git checkout would
    /// otherwise become one row and hide every project under it.
    func testTheRootItselfIsNeverAProjectAndIsAlwaysDescendedInto() throws {
        let root = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        try "{}".write(to: root.appendingPathComponent("all.code-workspace"), atomically: true, encoding: .utf8)
        try makeProjectDirectory(root.appendingPathComponent("inner"))

        let paths = scan(root: root, depth: 2).map(\.path)
        XCTAssertEqual(paths, [root.appendingPathComponent("inner").path])
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

/// Spreading a project's sessions over the windows that show it.
final class DistributeTests: XCTestCase {

    func testASingleWindowTakesTheWholePool() {
        let window = TestFixtures.window(index: 0, title: "тема \u{2014} proj (Workspace)", windowNumber: 10)
        let sessions = [TestFixtures.session(id: "s1", cwd: "/p", state: .working),
                        TestFixtures.session(id: "s2", cwd: "/p", state: .idle)]

        let assigned = DataSource.distribute(sessions: sessions, over: [window])
        XCTAssertEqual(assigned.map(\.0), [window.id])
        XCTAssertEqual(assigned.first?.1.map(\.sessionId), ["s1", "s2"])
    }

    /// The window title carries the active chat topic, ellipsised, so each
    /// window claims the session whose topic it is showing.
    func testEachWindowClaimsTheChatItIsShowing() throws {
        let first = TestFixtures.window(index: 0,
                                        title: "Вторая тема сме\u{2026} \u{2014} proj (Workspace)",
                                        windowNumber: 10)
        let second = TestFixtures.window(index: 1,
                                         title: "Первая тема жиз\u{2026} \u{2014} proj (Workspace)",
                                         windowNumber: 11)
        let sessions = [TestFixtures.session(id: "s1", cwd: "/p", state: .working, topic: "Первая тема жизни"),
                        TestFixtures.session(id: "s2", cwd: "/p", state: .waiting, topic: "Вторая тема смерти")]

        let assigned = Dictionary(uniqueKeysWithValues:
            DataSource.distribute(sessions: sessions, over: [first, second]))
        XCTAssertEqual(assigned[first.id]?.map(\.sessionId), ["s2"])
        XCTAssertEqual(assigned[second.id]?.map(\.sessionId), ["s1"])
    }

    /// Whatever nobody claimed goes to the frontmost window rather than
    /// disappearing.
    func testUnclaimedSessionsGoToTheFrontmostWindow() {
        let first = TestFixtures.window(index: 0,
                                        title: "Первая тема жиз\u{2026} \u{2014} proj (Workspace)",
                                        windowNumber: 10)
        let second = TestFixtures.window(index: 1, title: "proj (Workspace)", windowNumber: 11)
        let sessions = [TestFixtures.session(id: "s1", cwd: "/p", state: .working, topic: "Первая тема жизни"),
                        TestFixtures.session(id: "s2", cwd: "/p", state: .waiting, topic: "Нечто иное"),
                        TestFixtures.session(id: "s3", cwd: "/p", state: .idle, topic: "И ещё")]

        let assigned = Dictionary(uniqueKeysWithValues:
            DataSource.distribute(sessions: sessions, over: [first, second]))
        XCTAssertEqual(assigned[first.id]?.map(\.sessionId), ["s1", "s2", "s3"])
        XCTAssertEqual(assigned[second.id]?.count, 0)
    }

    func testNoWindowsMeansNoAssignments() {
        XCTAssertTrue(DataSource.distribute(sessions: [TestFixtures.session(id: "s1", cwd: "/p", state: .idle)],
                                            over: []).isEmpty)
    }
}

/// Identifying a window in a way that survives raising another one.
final class WindowIdentityTests: XCTestCase {

    /// The private call is what makes any of this work; without it every window
    /// falls back to being identified by its place in the z-order.
    func testTheWindowNumberCallIsAvailable() {
        XCTAssertTrue(VSCodeWindows.isWindowNumberAvailable)
    }

    func testIdentityIgnoresTheZOrder() {
        let front = TestFixtures.window(index: 0, title: "a \u{2014} p", windowNumber: 25_990)
        let back = TestFixtures.window(index: 3, title: "a \u{2014} p", windowNumber: 25_990)
        XCTAssertEqual(front.id, back.id)

        let other = TestFixtures.window(index: 0, title: "a \u{2014} p", windowNumber: 25_991)
        XCTAssertNotEqual(front.id, other.id)
    }

    func testIdentityFallsBackToTheIndexWithoutAWindowNumber() {
        let window = TestFixtures.window(index: 2, title: "a \u{2014} p", pid: 7, windowNumber: nil)
        XCTAssertEqual(window.id, "7:2")
    }

    /// The user-visible defect: clicking a row raised its window, which
    /// renumbered every row, which reset the selection, the hover highlight and
    /// the scroll position of the whole list.
    func testRowIdentityIsUnchangedAfterARaiseReordersTheList() {
        let projects = [TestFixtures.project(path: "/p/a", rootName: "a"),
                        TestFixtures.project(path: "/p/b", rootName: "b")]
        let alpha = TestFixtures.window(index: 0, title: "topic \u{2014} a", windowNumber: 100)
        let beta = TestFixtures.window(index: 1, title: "topic \u{2014} b", windowNumber: 200)

        let before = DataSource.assemble(projects: projects,
                                         windows: [alpha, beta],
                                         sessions: [],
                                         accessibilityTrusted: true)
        // The click raised `beta`: same two windows, new z-order, new indices.
        let raisedBeta = TestFixtures.window(index: 0, title: "topic \u{2014} b", windowNumber: 200)
        let loweredAlpha = TestFixtures.window(index: 1, title: "topic \u{2014} a", windowNumber: 100)
        let after = DataSource.assemble(projects: projects,
                                        windows: [raisedBeta, loweredAlpha],
                                        sessions: [],
                                        accessibilityTrusted: true)

        XCTAssertEqual(Set(before.openWindows.map(\.id)), Set(after.openWindows.map(\.id)))
        XCTAssertEqual(before.openWindows.first { $0.displayName == "a" }?.id,
                       after.openWindows.first { $0.displayName == "a" }?.id)
    }

    // MARK: - Matching for `raise`

    func testMatchIndexFindsTheWindowWhereverItMoved() {
        let window = TestFixtures.window(index: 0, title: "a \u{2014} p", windowNumber: 200)
        // The list as it is now: the recorded window sank to the back.
        XCTAssertEqual(VSCodeWindows.matchIndex(for: window, in: [100, 300, 200]), 2)
    }

    /// Falling back to the recorded index is exactly how clicking row 2 raised
    /// window 4: the index had been renumbered by the previous click.
    func testMatchIndexRefusesToGuessWhenTheWindowIsGone() {
        let window = TestFixtures.window(index: 1, title: "a \u{2014} p", windowNumber: 200)
        XCTAssertNil(VSCodeWindows.matchIndex(for: window, in: [100, 300, 400]))
    }

    func testMatchIndexUsesTheIndexOnlyWithoutAWindowNumber() {
        let window = TestFixtures.window(index: 1, title: "a \u{2014} p", windowNumber: nil)
        XCTAssertEqual(VSCodeWindows.matchIndex(for: window, in: [nil, nil, nil]), 1)
        XCTAssertNil(VSCodeWindows.matchIndex(for: window, in: [nil]))
    }

    /// The Accessibility half of a click is safe to call on any queue and
    /// simply fails when the process is gone — it never activates anything.
    func testRaisingAWindowOfADeadProcessFails() {
        let window = TestFixtures.window(index: 0, title: "a \u{2014} p", pid: 0x7FFF_FFFF, windowNumber: 1)
        XCTAssertFalse(VSCodeWindows.raise(window))
    }

    /// The timeout has to be set on the system-wide element to apply to the
    /// window elements, which is where every expensive read happens.
    func testMessagingTimeoutIsInstalledProcessWide() {
        XCTAssertTrue(VSCodeWindows.installMessagingTimeout())
        // Idempotent: the work happens once and the result is reused.
        XCTAssertTrue(VSCodeWindows.installMessagingTimeout())
    }

    /// The list and the highlight are keyed on `SwitcherRow.id`, so two windows
    /// of one project must not share one. The hand-rolled key the UI used before
    /// was built from the project path and collided for exactly this case.
    func testTwoWindowsOfOneProjectGetDistinctRowIdentities() {
        let projects = [TestFixtures.project(path: "/p/a", rootName: "a")]
        let first = TestFixtures.window(index: 0, title: "topic one \u{2014} a", windowNumber: 100)
        let second = TestFixtures.window(index: 1, title: "topic two \u{2014} a", windowNumber: 200)

        let snapshot = DataSource.assemble(projects: projects,
                                           windows: [first, second],
                                           sessions: [],
                                           accessibilityTrusted: true)
        XCTAssertEqual(Set(snapshot.openWindows.map(\.id)).count, 2)
    }
}

/// The panel's highlight of the window that is currently in front.
@MainActor
final class FrontmostHighlightTests: XCTestCase {

    private func snapshot(_ windows: [VSCodeWindowInfo]) -> SwitcherSnapshot {
        DataSource.assemble(projects: [TestFixtures.project(path: "/p/a", rootName: "a"),
                                       TestFixtures.project(path: "/p/b", rootName: "b")],
                            windows: windows,
                            sessions: [],
                            accessibilityTrusted: true)
    }

    /// The one remaining z-order consumer in the UI: index 0 of the active
    /// process is what "in front" means, and the new identity scheme leaves it
    /// working.
    func testHighlightsIndexZeroOfTheActiveProcess() {
        let alpha = TestFixtures.window(index: 0, title: "t \u{2014} a", pid: 7, windowNumber: 100)
        let beta = TestFixtures.window(index: 1, title: "t \u{2014} b", pid: 7, windowNumber: 200)
        let id = SwitcherViewModel.frontmostWindowID(in: snapshot([alpha, beta]), frontmostPID: 7)
        XCTAssertEqual(id, "window:7:w100")
    }

    /// After a click the raised window is index 0 and the highlight moves with
    /// it — to the row whose identity never changed.
    func testHighlightFollowsTheRaisedWindow() {
        let raisedBeta = TestFixtures.window(index: 0, title: "t \u{2014} b", pid: 7, windowNumber: 200)
        let loweredAlpha = TestFixtures.window(index: 1, title: "t \u{2014} a", pid: 7, windowNumber: 100)
        let id = SwitcherViewModel.frontmostWindowID(in: snapshot([raisedBeta, loweredAlpha]),
                                                     frontmostPID: 7)
        XCTAssertEqual(id, "window:7:w200")
    }

    /// Index 0 repeats in every editor process, so it only means "in front" for
    /// the process that is actually active.
    func testIgnoresIndexZeroOfAnInactiveProcess() {
        let other = TestFixtures.window(index: 0, title: "t \u{2014} a", pid: 7, windowNumber: 100)
        XCTAssertNil(SwitcherViewModel.frontmostWindowID(in: snapshot([other]), frontmostPID: 9))
        // Nothing is active at all: the previous highlight is kept, not guessed.
        XCTAssertNil(SwitcherViewModel.frontmostWindowID(in: snapshot([other]), frontmostPID: nil))
    }

    /// Without the private window-number call the identity falls back to the
    /// index. The highlight must still resolve rather than crash or go blank.
    func testWorksWithoutWindowNumbers() {
        let alpha = TestFixtures.window(index: 0, title: "t \u{2014} a", pid: 7, windowNumber: nil)
        let beta = TestFixtures.window(index: 1, title: "t \u{2014} b", pid: 7, windowNumber: nil)
        let id = SwitcherViewModel.frontmostWindowID(in: snapshot([alpha, beta]), frontmostPID: 7)
        XCTAssertEqual(id, "window:7:0")
    }
}

/// Concurrent callers of `DataSource.snapshot()`.
final class SnapshotCoalescingTests: XCTestCase {

    private final class BuildCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// Builds are numbered, and the number is the snapshot's timestamp, so
    /// "which build produced this" is an equality check rather than a race with
    /// the clock: two snapshots built a microsecond apart used to be told apart
    /// by their wall-clock stamps alone.
    private func makeSource(counter: BuildCounter, duration: TimeInterval = 0) -> DataSource {
        DataSource(config: .default) {
            counter.increment()
            if duration > 0 { Thread.sleep(forTimeInterval: duration) }
            return SwitcherSnapshot(openWindows: [],
                                    projects: [],
                                    accessibilityTrusted: false,
                                    generatedAt: Date(timeIntervalSince1970: Double(counter.value)))
        }
    }

    /// The point of the coalescing: whoever queued up behind a build in flight
    /// gets its result instead of rescanning the same disk.
    ///
    /// Every caller arrives at the same pinned instant, from before the build
    /// started, so the assertion holds however the four threads are scheduled —
    /// including the loaded machine where `concurrentPerform` runs them one
    /// after another and the later arrivals really did arrive after the build.
    func testCallersThatWaitedShareOneBuild() {
        let counter = BuildCounter()
        let source = makeSource(counter: counter, duration: 0.05)
        let arrivedAt = Date()

        let results = ResultBox()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            results.add(source.snapshot(requestedAt: arrivedAt))
        }
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(Set(results.values.map(\.generatedAt)).count, 1)
    }

    /// And the defect: a fixed window after a build finished also served the
    /// cache to callers that arrived *after* it. `SnapshotStore` fires exactly
    /// such a call — a watcher event during a build is replayed the moment it
    /// ends — and got back the very snapshot that had asked it to retry, so a
    /// hook state change waited for the next timer tick.
    func testACallerArrivingAfterTheBuildGetsAFreshOne() {
        let counter = BuildCounter()
        let source = makeSource(counter: counter)
        let arrivedAt = Date()

        let first = source.snapshot(requestedAt: arrivedAt)
        // Unambiguously later than the moment the first build finished.
        let second = source.snapshot(requestedAt: arrivedAt.addingTimeInterval(60))
        XCTAssertEqual(counter.value, 2)
        XCTAssertNotEqual(first.generatedAt, second.generatedAt)
    }

    /// The no-argument `snapshot()` is the one the app actually calls, and every
    /// other test here goes through the `requestedAt` seam instead — a mistake
    /// in that single line, a pinned or stale `Date`, would have served the very
    /// first build to every caller forever with nothing to catch it.
    ///
    func testTwoSequentialSnapshotsAreTwoBuilds() {
        let counter = BuildCounter()
        let source = makeSource(counter: counter)

        let first = source.snapshot()
        // `Date` is a `Double` of seconds since 2001, so around now it resolves
        // to a quarter of a microsecond — coarser than the gap between two calls
        // made back to back, which the `>=` would then read as "arrived before
        // the build finished". The app's own calls are a second apart.
        Thread.sleep(forTimeInterval: 0.001)
        let second = source.snapshot()
        XCTAssertEqual(counter.value, 2)
        XCTAssertNotEqual(first.generatedAt, second.generatedAt)
    }

    /// The cache is served to an earlier arrival however long ago the build ran,
    /// so a caller that never gets scheduled cannot force a second pass.
    func testAnEarlierArrivalIsStillServedTheCache() {
        let counter = BuildCounter()
        let source = makeSource(counter: counter)
        let arrivedAt = Date()

        _ = source.snapshot(requestedAt: arrivedAt)
        let late = source.snapshot(requestedAt: arrivedAt.addingTimeInterval(-60))
        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(late.generatedAt, Date(timeIntervalSince1970: 1))
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SwitcherSnapshot] = []
        func add(_ value: SwitcherSnapshot) { lock.lock(); storage.append(value); lock.unlock() }
        var values: [SwitcherSnapshot] { lock.lock(); defer { lock.unlock() }; return storage }
    }
}

/// The cache every transcript read goes through.
final class FileDerivedCacheTests: XCTestCase {

    func testAnUnchangedFileIsComputedOnce() throws {
        let url = try makeTemporaryFile()
        try "one".write(to: url, atomically: true, encoding: .utf8)
        let cache = FileDerivedCache<Int>()
        var computations = 0

        XCTAssertEqual(cache.value(atPath: url.path) { computations += 1; return 1 }, 1)
        XCTAssertEqual(cache.value(atPath: url.path) { computations += 1; return 2 }, 1)
        XCTAssertEqual(computations, 1)
    }

    func testAChangedFileIsRecomputed() throws {
        let url = try makeTemporaryFile()
        try "one".write(to: url, atomically: true, encoding: .utf8)
        let cache = FileDerivedCache<Int>()
        var computations = 0

        XCTAssertEqual(cache.value(atPath: url.path) { computations += 1; return 1 }, 1)
        try "one and then some more".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(cache.value(atPath: url.path) { computations += 1; return 2 }, 2)
        XCTAssertEqual(computations, 2)
    }

    /// The tail size is part of the key: the same transcript summarised with a
    /// different window is a different value.
    func testVariantsOfOneFileDoNotCollide() throws {
        let url = try makeTemporaryFile()
        try "one".write(to: url, atomically: true, encoding: .utf8)
        let cache = FileDerivedCache<Int>()

        XCTAssertEqual(cache.value(atPath: url.path, variant: "small") { 1 }, 1)
        XCTAssertEqual(cache.value(atPath: url.path, variant: "large") { 2 }, 2)
        XCTAssertEqual(cache.value(atPath: url.path, variant: "small") { 3 }, 1)
    }

    /// A file that does not exist is never cached: most sessions have no
    /// subagents directory, and it appears the moment the first one starts.
    func testAMissingFileIsNeverCached() {
        let cache = FileDerivedCache<Int>()
        var computations = 0
        let path = NSTemporaryDirectory() + "/vscode-switcher-missing-\(UUID().uuidString)"

        for _ in 0..<3 { _ = cache.value(atPath: path) { computations += 1; return 0 } }
        XCTAssertEqual(computations, 3)
    }

    /// Subagents go through the same cache now, keyed on their directory: the
    /// listing and every `.meta.json` parse used to be redone on every snapshot.
    func testSubagentEntriesAreReadFromTheDirectory() throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "{}\n".write(to: directory.appendingPathComponent("agent-abc.jsonl"),
                         atomically: true,
                         encoding: .utf8)
        try ##"{"agentType": "general-purpose", "description": "Round 6 residual gate fixes"}"##
            .write(to: directory.appendingPathComponent("agent-abc.meta.json"),
                   atomically: true,
                   encoding: .utf8)

        let entries = ClaudeSessions.subagentEntries(in: directory)
        XCTAssertEqual(entries.map(\.id), ["abc"])
        XCTAssertEqual(entries.first?.agentType, "general-purpose")
        XCTAssertEqual(entries.first?.description, "Round 6 residual gate fixes")
        XCTAssertTrue(ClaudeSessions.subagentEntries(in: directory.appendingPathComponent("nope")).isEmpty)
    }

    private func makeTemporaryFile() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-cache-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-subagents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// Session files stay on disk after the process dies, and pids are reused.
final class SessionLivenessTests: XCTestCase {

    func testOurOwnProcessIsAlive() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let start = try XCTUnwrap(ClaudeSessions.processStartTime(pid))
        XCTAssertTrue(ClaudeSessions.isProcessAlive(pid))
        // The session file is written a few seconds after the process started.
        XCTAssertTrue(ClaudeSessions.isSessionProcessAlive(pid: pid, startedAt: start.addingTimeInterval(3)))
    }

    /// The reason `startedAt` is checked at all: a stranger's process that
    /// inherited the pid started long after the session file was written.
    func testARecycledPidDoesNotResurrectAnOldSession() {
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertFalse(ClaudeSessions.isSessionProcessAlive(pid: pid,
                                                            startedAt: Date(timeIntervalSince1970: 1_600_000_000)))
    }

    /// Session files without `startedAt` keep the old, weaker behaviour.
    func testWithoutAStartTimeLivenessAloneDecides() {
        XCTAssertTrue(ClaudeSessions.isSessionProcessAlive(pid: ProcessInfo.processInfo.processIdentifier,
                                                           startedAt: nil))
    }

    func testAFinishedProcessIsNotAlive() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/echo")
        process.arguments = ["-n"]
        try process.run()
        process.waitUntilExit()

        XCTAssertFalse(ClaudeSessions.isProcessAlive(process.processIdentifier))
        XCTAssertFalse(ClaudeSessions.isSessionProcessAlive(pid: process.processIdentifier, startedAt: Date()))
    }

    func testNonPositivePidsAreNeverAlive() {
        XCTAssertFalse(ClaudeSessions.isProcessAlive(0))
        XCTAssertFalse(ClaudeSessions.isProcessAlive(-1))
        XCTAssertFalse(ClaudeSessions.isSessionProcessAlive(pid: 0, startedAt: nil))
    }
}
/// `hooks/claude-window-status.sh`, run for real against a temporary state
/// directory.
final class HookScriptTests: XCTestCase {

    private let sessionID = "11111111-2222-3333-4444-555555555555"

    /// A `Notification` must never take a permission wait off, and the guard
    /// cannot depend on `notification_type` being present: that field was
    /// confirmed for exactly one value on one CLI version, and without it the
    /// text heuristic classified "Claude is waiting for your input" as
    /// `waiting` and wrote it straight over `permission`.
    func testATypelessNotificationDoesNotDowngradePermission() throws {
        let directory = try makeStatusDirectory()
        try run(["hook_event_name": "Notification",
                 "notification_type": "permission_prompt",
                 "message": "Claude needs your permission to run Bash"],
                in: directory)
        XCTAssertEqual(try state(in: directory), "permission")

        try run(["hook_event_name": "Notification",
                 "message": "Claude is waiting for your input"],
                in: directory)
        XCTAssertEqual(try state(in: directory), "permission")
    }

    func testIdlePromptDoesNotDowngradePermissionEither() throws {
        let directory = try makeStatusDirectory()
        try run(["hook_event_name": "Notification",
                 "notification_type": "elicitation_dialog",
                 "message": "Claude Code needs your input"],
                in: directory)
        XCTAssertEqual(try state(in: directory), "permission")

        try run(["hook_event_name": "Notification",
                 "notification_type": "idle_prompt",
                 "message": "Claude is waiting for your input"],
                in: directory)
        XCTAssertEqual(try state(in: directory), "permission")
    }

    /// Only these two clear it.
    func testStopAndUserPromptSubmitDoClearPermission() throws {
        for (event, expected) in [("Stop", "waiting"), ("UserPromptSubmit", "working")] {
            let directory = try makeStatusDirectory()
            try run(["hook_event_name": "Notification",
                     "notification_type": "permission_prompt",
                     "message": "Claude needs your permission to run Bash"],
                    in: directory)
            XCTAssertEqual(try state(in: directory), "permission")

            try run(["hook_event_name": event, "cwd": "/tmp"], in: directory)
            XCTAssertEqual(try state(in: directory), expected, "after \(event)")
        }
    }

    /// In jq every number sorts before every string, so a `ts` that is not a
    /// number made "the record on disk is newer" true forever and no state
    /// could ever be written again.
    func testANonNumericTimestampOnDiskDoesNotWedgeTheFile() throws {
        let directory = try makeStatusDirectory()
        try write(##"{"state": "waiting", "ts": "abc"}"##, to: directory)

        try run(["hook_event_name": "UserPromptSubmit", "cwd": "/tmp"], in: directory)
        XCTAssertEqual(try state(in: directory), "working")
    }

    /// And a state file that is not an object at all used to kill the jq
    /// program outright, with the same result.
    func testANonObjectStateFileDoesNotWedgeTheFileEither() throws {
        let directory = try makeStatusDirectory()
        try write("[1,2]", to: directory)

        try run(["hook_event_name": "UserPromptSubmit", "cwd": "/tmp"], in: directory)
        XCTAssertEqual(try state(in: directory), "working")
    }

    /// A `Notification` whose type says nothing about the agent leaves the file
    /// alone rather than writing a state of its own.
    func testUnrelatedNotificationsLeaveTheStateAlone() throws {
        let directory = try makeStatusDirectory()
        try run(["hook_event_name": "Stop"], in: directory)
        try run(["hook_event_name": "Notification",
                 "notification_type": "auth_success",
                 "message": "Logged in"],
                in: directory)
        XCTAssertEqual(try state(in: directory), "waiting")
    }

    /// A `cwd` the hook cannot see must not blank out the one a previous event
    /// recorded, and a backslash in it has to survive intact.
    func testAPathWithABackslashSurvivesAndIsNotBlankedOut() throws {
        let directory = try makeStatusDirectory()
        try run(["hook_event_name": "UserPromptSubmit", "cwd": #"/a\b"#], in: directory)
        try run(["hook_event_name": "Notification",
                 "notification_type": "permission_prompt",
                 "message": "needs your permission"],
                in: directory)

        let record = try XCTUnwrap(JSONC.object(atPath: statusFile(in: directory).path))
        XCTAssertEqual(record["cwd"] as? String, #"/a\b"#)
        XCTAssertEqual(record["state"] as? String, "permission")
    }

    // MARK: - Harness

    private func run(_ fields: [String: String], in directory: URL) throws {
        let script = Self.repositoryRoot.appendingPathComponent("hooks/claude-window-status.sh")
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            throw XCTSkip("hook script not found at \(script.path)")
        }
        guard Self.hasJQ else { throw XCTSkip("jq is not installed") }

        var payload = fields
        payload["session_id"] = sessionID
        let data = try JSONSerialization.data(withJSONObject: payload)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = ["VSCODE_SWITCHER_STATUS_DIR": directory.path,
                               "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(data)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        // A failing hook surfaces as an error inside the user's session.
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func statusFile(in directory: URL) -> URL {
        directory.appendingPathComponent("\(sessionID).json")
    }

    private func write(_ contents: String, to directory: URL) throws {
        try contents.write(to: statusFile(in: directory), atomically: true, encoding: .utf8)
    }

    private func state(in directory: URL) throws -> String? {
        let path = statusFile(in: directory).path
        let object = try XCTUnwrap(JSONC.object(atPath: path), "no state file at \(path)")
        return object["state"] as? String
    }

    private func makeStatusDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// `<repo>/macos/Tests/VSCodeSwitcherTests/<this file>`.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let hasJQ: Bool = ["/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/usr/bin/jq"]
        .contains { FileManager.default.isExecutableFile(atPath: $0) }
}
