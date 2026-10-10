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

    /// A question outranks a permission wait: both stop the agent dead, but the
    /// question is the one the user cannot even guess the answer to from the
    /// row, so it is the one worth surfacing first.
    func testAQuestionOutranksEverything() {
        XCTAssertEqual([AgentState.permission, .question].max(), .question)
        XCTAssertEqual([AgentState.question, .working, .waiting, .idle].max(), .question)
    }

    func testTheOrderIsTotalAndInTheDocumentedSequence() {
        XCTAssertEqual(AgentState.allCases.sorted(),
                       [.idle, .working, .waiting, .permission, .question])
        XCTAssertEqual(Set(AgentState.allCases.map(\.priority)).count, AgentState.allCases.count)
    }
}

/// `AskUserQuestion` and `ExitPlanMode` are the two tool calls that mean the
/// agent stopped and is waiting for a human. Everything else under
/// `stop_reason: tool_use` is work in progress.
final class QuestionDetectionTests: XCTestCase {
    private func message(toolNames: [String], stopReason: String = "tool_use") -> [String: Any] {
        ["stop_reason": stopReason,
         "content": [["type": "text", "text": "hi"]]
             + toolNames.enumerated().map { ["type": "tool_use", "name": $1, "id": "toolu_\($0)"] }]
    }

    private func asks(_ message: [String: Any], answered: Set<String> = []) -> Bool {
        ClaudeSessions.unansweredQuestion(message: message, answered: answered)
    }

    func testAskUserQuestionIsAQuestion() {
        XCTAssertTrue(asks(message(toolNames: ["AskUserQuestion"])))
    }

    /// A finished plan waiting for approval is the same thing: the agent has
    /// stopped and only a human moves it on.
    func testExitPlanModeIsAQuestionToo() {
        XCTAssertTrue(asks(message(toolNames: ["ExitPlanMode"])))
    }

    func testAnOrdinaryToolCallIsNot() {
        XCTAssertFalse(asks(message(toolNames: ["Bash", "Read"])))
    }

    func testTheQuestionCountsEvenNextToOtherCalls() {
        XCTAssertTrue(asks(message(toolNames: ["Read", "AskUserQuestion"])))
    }

    func testAMessageWithoutContentIsNot() {
        XCTAssertFalse(asks(["stop_reason": "tool_use"]))
        XCTAssertFalse(asks(["content": "not an array"]))
    }

    /// A text block that merely mentions the name is not a call.
    func testTheNameHasToBeOnAToolUseBlock() {
        let message: [String: Any] = ["content": [["type": "text", "name": "AskUserQuestion"]]]
        XCTAssertFalse(asks(message))
    }

    /// The answer arrives as a `tool_result` carrying the question's own id.
    func testAnAnsweredQuestionIsNotAQuestionAnyMore() {
        XCTAssertFalse(asks(message(toolNames: ["AskUserQuestion"]), answered: ["toolu_0"]))
    }

    /// Someone else's result must not close it: with two tools in flight, the
    /// unrelated one finishing first would put the chat back to `working` while
    /// the dialog is still on screen.
    func testAnUnrelatedResultLeavesTheQuestionOpen() {
        XCTAssertTrue(asks(message(toolNames: ["AskUserQuestion"]), answered: ["toolu_other"]))
    }

    /// Two questions in one message, one answered: the other still waits.
    func testOnlyTheAnsweredOneIsClosed() {
        let both = message(toolNames: ["AskUserQuestion", "ExitPlanMode"])
        XCTAssertTrue(asks(both, answered: ["toolu_0"]))
        XCTAssertTrue(asks(both, answered: ["toolu_1"]))
        XCTAssertFalse(asks(both, answered: ["toolu_0", "toolu_1"]))
    }

    /// Nothing to match on means the state is kept, not dropped.
    func testAQuestionWithoutAnIdStaysAQuestion() {
        let message: [String: Any] = ["content": [["type": "tool_use", "name": "AskUserQuestion"]]]
        XCTAssertTrue(asks(message, answered: ["toolu_1"]))
    }

    func testResultsAreCollectedFromUserRecords() {
        var answered: Set<String> = []
        let record: [String: Any] = ["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "toolu_1"],
            ["type": "text", "text": "hi"],
            ["type": "tool_result", "tool_use_id": "toolu_2"],
        ]]]
        ClaudeSessions.collectAnswers(record: record, into: &answered)
        XCTAssertEqual(answered, ["toolu_1", "toolu_2"])

        // A record with nothing usable in it must not throw anything off.
        ClaudeSessions.collectAnswers(record: ["type": "user"], into: &answered)
        ClaudeSessions.collectAnswers(record: ["type": "user", "message": ["content": "text"]], into: &answered)
        XCTAssertEqual(answered, ["toolu_1", "toolu_2"])
    }
}

/// The same signal read off a real transcript tail.
final class TranscriptQuestionTests: XCTestCase {
    private func record(toolName: String, isSidechain: Bool = false, id: String = "toolu_1") -> String {
        let content = "[{\"type\":\"tool_use\",\"name\":\"\(toolName)\",\"id\":\"\(id)\"}]"
        return "{\"type\":\"assistant\",\"isSidechain\":\(isSidechain),"
            + "\"message\":{\"model\":\"claude-opus-5\",\"stop_reason\":\"tool_use\","
            + "\"content\":\(content)}}"
    }

    /// What the answer looks like on disk: the user record that follows the
    /// question and quotes its id.
    private func answer(to id: String) -> String {
        "{\"type\":\"user\",\"isSidechain\":false,\"message\":{\"role\":\"user\","
            + "\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"\(id)\"}]}}"
    }

    func testAQuestionInTheTailBecomesTheQuestionState() throws {
        let url = try temporaryFile()
        try (record(toolName: "AskUserQuestion") + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeSessions.transcriptSummary(atPath: url.path, tailBytes: 64 * 1024).fallbackState,
                       .question)
    }

    func testAPlainToolCallStaysWorking() throws {
        let url = try temporaryFile()
        try (record(toolName: "Bash") + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeSessions.transcriptSummary(atPath: url.path, tailBytes: 64 * 1024).fallbackState,
                       .working)
    }

    /// A subagent asking its parent something says nothing about the chat the
    /// row is showing, and sidechain records were already skipped for the model
    /// and the token count for exactly this reason.
    func testASubagentsQuestionIsIgnored() throws {
        let url = try temporaryFile()
        let text = record(toolName: "Bash") + "\n" + record(toolName: "AskUserQuestion", isSidechain: true) + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeSessions.transcriptSummary(atPath: url.path, tailBytes: 64 * 1024).fallbackState,
                       .working)
    }

    /// The shape caught on a real transcript: `AskUserQuestion` on one line, the
    /// `tool_result` that answered it on the next, and the chat carried on. The
    /// question is over, but the panel kept showing the yellow "asked a
    /// question" chip because the scan stopped at the assistant record and never
    /// looked at what came after it.
    func testAnAnsweredQuestionIsBackToWorking() throws {
        let url = try temporaryFile()
        let text = record(toolName: "AskUserQuestion") + "\n" + answer(to: "toolu_1") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeSessions.transcriptSummary(atPath: url.path, tailBytes: 64 * 1024).fallbackState,
                       .working)
    }

    /// The result of some other tool running in parallel is not an answer.
    func testSomebodyElsesResultDoesNotCloseTheQuestion() throws {
        let url = try temporaryFile()
        let text = record(toolName: "AskUserQuestion", id: "toolu_ask") + "\n" + answer(to: "toolu_bash") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeSessions.transcriptSummary(atPath: url.path, tailBytes: 64 * 1024).fallbackState,
                       .question)
    }

    private func temporaryFile() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-question-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// A `tool_use` tail says a turn was started, not that it is still running, and
/// until this was added nothing ever took a transcript-sourced `working` back.
/// The reproducer is session `3fc12f86-…` of home-network: its last assistant
/// record is from 2026-08-05, the user interrupted the `Artifact` call it had
/// started three days later, and reopened the chat on 2026-08-16 — eleven days
/// after that record — without typing anything. The row spun for a turn that
/// had been cancelled.
final class TranscriptInterruptTests: XCTestCase {

    /// The assistant record the fallback state comes from, in the shape the real
    /// file has: `timestamp` at the record level, never inside `message`.
    private func assistant(toolName: String = "Artifact",
                           id: String = "toolu_01UWEyrHaGuNMkhfrzUbpAew",
                           timestamp: String = "2026-08-05T13:27:47.970Z") -> String {
        "{\"type\":\"assistant\",\"isSidechain\":false,\"timestamp\":\"\(timestamp)\","
            + "\"message\":{\"model\":\"claude-opus-5\",\"stop_reason\":\"tool_use\","
            + "\"content\":[{\"type\":\"tool_use\",\"name\":\"\(toolName)\",\"id\":\"\(id)\"}]}}"
    }

    /// A finished turn: the agent answered and is waiting to be read.
    private func finishedTurn() -> String {
        "{\"type\":\"assistant\",\"isSidechain\":false,\"timestamp\":\"2026-08-05T13:27:47.970Z\","
            + "\"message\":{\"model\":\"claude-opus-5\",\"stop_reason\":\"end_turn\","
            + "\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}"
    }

    /// One of the two shapes a typed prompt arrives in: block content with a
    /// `text` block — the same shape as the marker, which is why the two are
    /// told apart by the text and not by the record.
    private func prompt(_ text: String = "и ещё вот это поправь",
                        isSidechain: Bool = false) -> String {
        "{\"type\":\"user\",\"isSidechain\":\(isSidechain),\"timestamp\":\"2026-08-08T14:25:31.100Z\","
            + "\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}}"
    }

    /// The other shape, and the one that was being read as silence: `content`
    /// is a plain string. 4110 user records in the §2.4 census look like this —
    /// dragged-in paths, slash commands, messages from other sessions — and not
    /// one of its 789 markers ever did.
    private func stringPrompt(_ text: String = "/Users/vvzvlad/Data/Projects/fusion") -> String {
        "{\"type\":\"user\",\"isSidechain\":false,\"timestamp\":\"2026-08-08T14:25:31.100Z\","
            + "\"message\":{\"role\":\"user\",\"content\":\"\(text)\"}}"
    }

    /// A prompt that is nothing but a pasted image: eight user records in the
    /// §2.4 census have exactly this shape, and each one started a turn.
    private func imagePrompt() -> String {
        "{\"type\":\"user\",\"isSidechain\":false,\"timestamp\":\"2026-08-08T14:25:31.100Z\","
            + "\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"image\","
            + "\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"iVBOR\"}}]}}"
    }

    /// The aborted call still gets an answer — an `is_error` result — which is
    /// why "was the last `tool_use` answered" cannot be the signal on its own:
    /// six of the seven tails that go on reading `working` have theirs answered
    /// too, and so does a session that is genuinely thinking after a result.
    private func result(to id: String, timestamp: String = "2026-08-08T14:25:22.670Z") -> String {
        "{\"type\":\"user\",\"isSidechain\":false,\"timestamp\":\"\(timestamp)\","
            + "\"message\":{\"role\":\"user\",\"content\":"
            + "[{\"type\":\"tool_result\",\"tool_use_id\":\"\(id)\",\"is_error\":true}]}}"
    }

    /// The marker in the shape it usually has: block-shaped `content` with a
    /// `text` block — 786 of the 789 markers in the §2.4 census.
    private func interrupt(_ text: String = "[Request interrupted by user]",
                           isSidechain: Bool = false) -> String {
        "{\"type\":\"user\",\"isSidechain\":\(isSidechain),\"timestamp\":\"2026-08-08T14:25:24.390Z\","
            + "\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}}"
    }

    /// The marker in its other shape: the *content* of a `tool_result` block,
    /// with no text block anywhere in the record. Three records in the census,
    /// and it is written when the interrupted turn was inside a tool call.
    private func interruptAsResult(to id: String,
                                   timestamp: String = "2026-08-08T14:25:24.390Z") -> String {
        "{\"type\":\"user\",\"isSidechain\":false,\"timestamp\":\"\(timestamp)\","
            + "\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\","
            + "\"tool_use_id\":\"\(id)\",\"is_error\":true,"
            + "\"content\":\"[Request interrupted by user for tool use]\"}]}}"
    }

    /// What resuming a chat appends before it replays anything: records with no
    /// `timestamp` field at all. Ten types of them in the §2.4 census, and the
    /// reason the replay window exists — none of them moves `newestRecordAt`,
    /// so between the resume and the result the newest stamp in the file is
    /// still the pre-resume one.
    private func resumeNoise() -> [String] {
        ["{\"type\":\"last-prompt\",\"lastPrompt\":\"собери панель\"}",
         "{\"type\":\"agent-setting\",\"value\":\"default\"}",
         "{\"type\":\"mode\",\"mode\":\"default\",\"sessionId\":\"s\"}"]
    }

    /// What the machine says when a dialog is answered: a `tool_result` whose
    /// `content` is a string too — 771 of 771 answers to
    /// `AskUserQuestion`/`ExitPlanMode` in the §2.4 census have this shape. Only the marker prefix
    /// tells the two apart.
    private func dialogAnswer(to id: String) -> String {
        "{\"type\":\"user\",\"isSidechain\":false,\"timestamp\":\"2026-08-08T14:25:24.390Z\","
            + "\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\","
            + "\"tool_use_id\":\"\(id)\","
            + "\"content\":\"Your questions have been answered: ok\"}]}}"
    }

    private func summary(_ lines: [String]) throws -> ClaudeSessions.TranscriptSummary {
        let url = try temporaryFile()
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return ClaudeSessions.transcriptSummary(atPath: url.path, tailBytes: 64 * 1024)
    }

    private func fallbackState(_ lines: [String]) throws -> AgentState? {
        try summary(lines).fallbackState
    }

    /// Both halves of §2.4 over a real-shaped tail: the scan reads the state and
    /// the newest stamp, and `resolveState` decides whether the process that is
    /// running now could have started that turn.
    private func resolved(_ lines: [String],
                          startedAt: String) throws -> (state: AgentState, source: AgentStateSource) {
        ClaudeSessions.resolveState(hook: nil,
                                    transcript: try summary(lines),
                                    sessionStartedAt: try stamp(startedAt),
                                    now: try stamp(startedAt).addingTimeInterval(60))
    }

    private func stamp(_ text: String) throws -> Date {
        try Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// The reproducer's own shape: the call, its aborted result, and the marker
    /// the user's Escape left behind.
    func testAnInterruptedToolCallIsNotWork() throws {
        let id = "toolu_01UWEyrHaGuNMkhfrzUbpAew"
        XCTAssertEqual(try fallbackState([assistant(id: id), result(to: id), interrupt()]), .idle)
    }

    /// The other marker text Claude Code writes: 248 records in the §2.4 census
    /// against 541 of the plain one, 789 together, and the prefix
    /// `[Request interrupted` is what covers both.
    func testTheToolUseVariantOfTheMarkerCountsToo() throws {
        XCTAssertEqual(try fallbackState([assistant(), interrupt("[Request interrupted by user for tool use]")]),
                       .idle)
    }

    /// And the other *shape*: the interruption written as the content of the
    /// `tool_result` itself, with no text block in the record at all. Three
    /// records in the census have it — `9b8601b5` line 248, `758a45e9` line 124,
    /// `aceb7b4f` line 579 — and until this was read the rule saw them as "the
    /// user said nothing". Two are followed by an ordinary marker seconds later
    /// and cost nothing; `9b8601b5` has no other marker at all, and its next
    /// speech is a prompt 39.7 s later — 40 seconds of spinner over a turn the
    /// user had cancelled.
    func testTheMarkerInsideAToolResultCountsToo() throws {
        let id = "toolu_01UWEyrHaGuNMkhfrzUbpAew"
        XCTAssertEqual(ClaudeSessions.interruptVerdict(
            record: try XCTUnwrap(try JSONC.parse(interruptAsResult(to: id)) as? [String: Any])), true)
        XCTAssertEqual(try fallbackState([assistant(toolName: "Agent", id: id), interruptAsResult(to: id)]),
                       .idle)
    }

    /// The narrowness that makes the shape above safe to read. The answer to a
    /// dialog is a string-shaped `tool_result` as well, and it must go on saying
    /// nothing: it is the machine handing the agent what the user picked, the
    /// turn carries straight on, and a `true` here would stop the spinner over
    /// it. Only the marker prefix separates the two.
    func testAnAnsweredDialogInsideAToolResultIsStillSilence() throws {
        let id = "toolu_ask"
        XCTAssertNil(ClaudeSessions.interruptVerdict(
            record: try XCTUnwrap(try JSONC.parse(dialogAnswer(to: id)) as? [String: Any])))
        XCTAssertEqual(try fallbackState([assistant(toolName: "AskUserQuestion", id: id), dialogAnswer(to: id)]),
                       .working)
    }

    /// The window the marker rule must not misjudge: the user pressed Escape and
    /// immediately retyped, and the agent is working on the new prompt with no
    /// assistant record of its own yet. Caught on live data — a marker at
    /// 14:18:58.819 and the prompt that replaced it 36 ms later.
    ///
    /// This is why the *newest* thing the user said decides, and not "a marker
    /// was seen somewhere above": the marker is still there, and reading it as
    /// the last word would stop the spinner over a running turn. With no hooks
    /// installed nothing else would notice, and §2.4 promises this source works
    /// without them.
    func testAPromptAfterTheMarkerIsANewTurn() throws {
        let id = "toolu_01UWEyrHaGuNMkhfrzUbpAew"
        XCTAssertEqual(try fallbackState([assistant(id: id), result(to: id), interrupt(), prompt()]), .working)
        // The same tail with the prompt taken off is the reproducer again.
        XCTAssertEqual(try fallbackState([assistant(id: id), result(to: id), interrupt()]), .idle)
    }

    /// The same window, with the prompt in its other shape. This is the one the
    /// first version got wrong: a plain-string `content` was read as "nothing
    /// was said", the backwards scan walked straight past it and stopped at the
    /// marker underneath, and the row went dark over an agent that was working.
    ///
    /// Not a hypothetical shape: 42 distinct events in the §2.4 census have a
    /// string-shaped record immediately after a marker, six of them the
    /// user's own words. In `150c56e0-…` the marker landed at 16:10:35.461, the
    /// string-shaped prompt 6 ms later, and the turn's first assistant record
    /// at 16:10:39.606 — 4.1 s of a wrongly darkened row, against a median of
    /// 17 s and a p90 of 68 s for prompt → first record.
    func testAStringShapedPromptAfterTheMarkerIsANewTurnToo() throws {
        let id = "toolu_01UWEyrHaGuNMkhfrzUbpAew"
        XCTAssertEqual(try fallbackState([assistant(id: id), result(to: id), interrupt(), stringPrompt()]),
                       .working)
    }

    /// And with the prompt that is only a pasted image. Words are not the only
    /// way to start a turn, and the census's eight image-only records each did.
    func testAPastedImageAfterTheMarkerIsANewTurnToo() throws {
        XCTAssertEqual(try fallbackState([assistant(), interrupt(), imagePrompt()]), .working)
    }

    /// The other half of that: a `tool_result` is not the user saying anything.
    /// It is the machine answering the agent, it arrives in the middle of a
    /// running turn, and if it counted as speech the marker right under it
    /// would never be reached — the reproducer has exactly this shape.
    func testAToolResultIsNotTheUserSpeaking() throws {
        let id = "toolu_01UWEyrHaGuNMkhfrzUbpAew"
        XCTAssertNil(ClaudeSessions.interruptVerdict(
            record: try XCTUnwrap(try JSONC.parse(result(to: id)) as? [String: Any])))
        XCTAssertEqual(try fallbackState([assistant(id: id), interrupt(), result(to: id)]), .idle)
    }

    /// A marker below the last assistant record belongs to an earlier turn: the
    /// user interrupted, then sent a new prompt and the agent started working
    /// again. Only a marker *newer* than that record ends the turn it began.
    ///
    /// Nothing in the scan tests this explicitly — it falls out of the verdict
    /// being read exactly once, at the assistant record, with only newer records
    /// scanned by then. That is the invariant this pins, so that a later change
    /// to where the state is computed cannot quietly break it — including the
    /// `needsAssistant` early-out on the user branch, which is there for the
    /// cost of the casts and must stay behaviour-neutral.
    func testAMarkerOlderThanTheLastTurnChangesNothing() throws {
        XCTAssertEqual(try fallbackState([interrupt(), assistant()]), .working)
    }

    /// The marker rule stops at `question` on purpose: a wrongly cleared
    /// question never comes back on its own (§2.6.3), and an agent that asked
    /// and was interrupted still has its dialog on screen. Moving the marker
    /// check above the question check has to break this.
    func testAMarkerDoesNotTakeAwayAnUnansweredQuestion() throws {
        XCTAssertEqual(try fallbackState([assistant(toolName: "AskUserQuestion", id: "toolu_ask"), interrupt()]),
                       .question)
    }

    /// And it stops at `waiting` as well: the turn ended by itself, the answer
    /// is on screen to be read, and a marker after it belongs to whatever the
    /// user did next. Only `working` is a claim about right now.
    func testAMarkerDoesNotTakeAwayAFinishedTurn() throws {
        XCTAssertEqual(try fallbackState([finishedTurn(), interrupt()]), .waiting)
    }

    /// Symmetry with the assistant branch, which skips sidechain records for the
    /// same reason: another branch of the conversation says nothing about the
    /// chat the row shows. Not a scenario anybody has met — subagents write into
    /// their own session file (§2.6.3), and there is no record with
    /// `isSidechain: true` anywhere in the 425 parent transcripts of the §2.4
    /// control run. What this pins is the shape, so that the two branches
    /// cannot drift apart if such a record ever does turn up.
    func testASubagentsInterruptIsIgnored() throws {
        XCTAssertEqual(try fallbackState([assistant(), interrupt(isSidechain: true)]), .working)
    }

    /// The case that must not be broken by any of this: a `tool_use` with no
    /// marker after it is a long `Bash`, and a working agent must never silently
    /// vanish from the list. Seven stale tails in the §2.4 census keep reading
    /// `working` on purpose (96–741 hours idle; six have no marker after their
    /// last assistant record, the seventh has one a newer prompt supersedes),
    /// because nothing tells them apart from a command running for an hour.
    func testAPlainToolCallStillReadsWorking() throws {
        XCTAssertEqual(try fallbackState([assistant(toolName: "Bash"), result(to: "toolu_01UWEyrHaGuNMkhfrzUbpAew")]),
                       .working)
    }

    /// The stamp Rule 2 compares against the process start, read off the record
    /// level and keeping its fractional seconds. It is the newest record of
    /// *any* type, not the newest assistant record: here the answer to the call
    /// is the newest thing in the tail, and it is the answer's stamp that must
    /// come out.
    func testTheNewestRecordStampIsParsedWhateverTheRecordIs() throws {
        let id = "toolu_01UWEyrHaGuNMkhfrzUbpAew"
        let parsed = try XCTUnwrap(try summary([assistant(id: id), result(to: id)]).newestRecordAt)
        XCTAssertEqual(parsed.timeIntervalSince1970,
                       try stamp("2026-08-08T14:25:22.670Z").timeIntervalSince1970,
                       accuracy: 0.001)

        // Resuming a chat writes records that carry no `timestamp` at all, and
        // the scan has to walk past them rather than give up on the first one.
        let resumeNoise = "{\"type\":\"mode\",\"mode\":\"default\",\"sessionId\":\"s\"}"
        let afterNoise = try XCTUnwrap(try summary([assistant(id: id), result(to: id),
                                                    resumeNoise]).newestRecordAt)
        XCTAssertEqual(afterNoise.timeIntervalSince1970, parsed.timeIntervalSince1970, accuracy: 0.001)
    }

    /// A stamp that does not parse must stop the search, not hand it on to the
    /// record below. Missing and unreadable are different questions: no
    /// `timestamp` field means "keep looking" — that is the ordinary
    /// untimestamped metadata — while a field that will not parse still belongs
    /// to the newest record, and taking the next, older stamp instead would
    /// demote a session that has just written into its own file.
    ///
    /// Here the newest record is the answer to the call, stamped 48 s after the
    /// process started but without fractional seconds; the assistant record
    /// under it is eleven days old. Read the older stamp and this live session
    /// goes dark. §2.4 leans on this: it is what lets the parse be attempted
    /// once, with no fraction-less second try.
    func testAStampThatDoesNotParseStopsTheSearch() throws {
        let id = "toolu_01UWEyrHaGuNMkhfrzUbpAew"
        let tail = [assistant(toolName: "Bash", id: id, timestamp: "2026-08-05T13:27:47.970Z"),
                    result(to: id, timestamp: "2026-08-16T02:31:02Z")]
        XCTAssertNil(try summary(tail).newestRecordAt)

        let state = try resolved(tail, startedAt: "2026-08-16T02:30:14.000Z")
        XCTAssertEqual(state.state, .working)
        XCTAssertEqual(state.source, .transcript)
    }

    /// The reproducer, end to end: a `tool_use` tail whose every record predates
    /// the process reading it. `3fc12f86-…` was resumed at 2026-08-16T02:30:14Z
    /// with nothing newer than the marker of 2026-08-08T14:25:24.390Z in it.
    ///
    /// The second half is the one that pins Rule 2 on its own. The full tail is
    /// already `idle` from Rule 1, so neutering the stamp comparison would not
    /// show there; strip the marker and only the stamps are left to notice that
    /// the turn belongs to a previous life of the file.
    func testATailEntirelyOlderThanTheProcessIsNotRunningNow() throws {
        let id = "toolu_01UWEyrHaGuNMkhfrzUbpAew"
        let started = "2026-08-16T02:30:14.000Z"
        let full = try resolved([assistant(id: id), result(to: id), interrupt()], startedAt: started)
        XCTAssertEqual(full.state, .idle)
        XCTAssertEqual(full.source, .transcript)

        let noMarker = try resolved([assistant(toolName: "Bash", id: id), result(to: id)],
                                    startedAt: started)
        XCTAssertEqual(noMarker.state, .idle)
        XCTAssertEqual(noMarker.source, .transcript)
    }

    /// An answered question, which is the shape that made the last assistant
    /// record the wrong thing to compare against. The answer to a dialog arrives
    /// as a bare `tool_result` — 771 of 771 `AskUserQuestion`/`ExitPlanMode`
    /// answers in the §2.4 census, and an approved permission dialog too — so a
    /// question asked before the process started and answered after it leaves
    /// the last assistant record in the past while the agent is thinking about
    /// what it was just told. Live instance: `79583d9f-…` of home-network, asked
    /// 2026-08-13T20:50:28.699Z, answered 2026-08-15T01:44:22.150Z, 28.9 hours
    /// later, with the next assistant record 45 s after that.
    func testAQuestionAnsweredAfterTheProcessStartedIsWork() throws {
        let asked = assistant(toolName: "AskUserQuestion", id: "toolu_ask",
                              timestamp: "2026-08-13T20:50:28.699Z")
        let answer = result(to: "toolu_ask", timestamp: "2026-08-15T01:44:22.150Z")
        // The scan reads `working`, not `question`: the answer is in the tail.
        XCTAssertEqual(try fallbackState([asked, answer]), .working)

        let state = try resolved([asked, answer], startedAt: "2026-08-15T01:30:00.000Z")
        XCTAssertEqual(state.state, .working)
        XCTAssertEqual(state.source, .transcript)
    }

    /// The same trap without a dialog: a tool call left hanging when the window
    /// was closed is replayed on resume, and its result lands under the new
    /// process while the assistant record that asked for it stays weeks old.
    /// Live instance: `3c820b4c-…`, where the resume noise is followed by the
    /// answer to a `Bash` call from 9.7 hours earlier and no prompt at all.
    ///
    /// This is the state *after* the result lands — 48 s past the process start
    /// here. The window before it is `testACallStillInFlightStandsRuleTwoDown`.
    func testAToolCallReplayedAfterTheProcessStartedIsWork() throws {
        let id = "toolu_01UWEyrHaGuNMkhfrzUbpAew"
        let state = try resolved([assistant(toolName: "Bash", id: id, timestamp: "2026-08-05T13:27:47.970Z"),
                                  result(to: id, timestamp: "2026-08-16T02:31:02.100Z")],
                                 startedAt: "2026-08-16T02:30:14.000Z")
        XCTAssertEqual(state.state, .working)
        XCTAssertEqual(state.source, .transcript)
    }

    /// The same replay while it is still running, which is the shape Rule 2 is
    /// not allowed to judge. The resume records carry no stamp, so the newest
    /// one in the file is the eleven-day-old `tool_use` itself, and the stamps
    /// alone would call this `idle` over a command that is executing right now.
    /// The window is the call's own run time and has no ceiling: 63 442
    /// call → result pairs on this machine give a median of 0.1 s, a p90 of
    /// 8.3 s and a p99 of 606 s.
    ///
    /// Nothing new is needed to see it. §2.4 already refuses to judge an
    /// unanswered `tool_use` with no marker after it — it cannot be told apart
    /// from a `Bash` that has been running for an hour — and a replay has
    /// exactly that shape until its result lands. Rule 2 was reaching into that
    /// exception; this is it put back.
    func testACallStillInFlightStandsRuleTwoDown() throws {
        let id = "toolu_01UWEyrHaGuNMkhfrzUbpAew"
        let replaying = [assistant(toolName: "Bash", id: id, timestamp: "2026-08-05T13:27:47.970Z")]
            + resumeNoise()
        let scanned = try summary(replaying)
        XCTAssertTrue(scanned.lastTurnAwaitingToolResult)
        // The stamps really are the pre-resume ones — otherwise this would pass
        // for the wrong reason.
        XCTAssertEqual(try XCTUnwrap(scanned.newestRecordAt).timeIntervalSince1970,
                       try stamp("2026-08-05T13:27:47.970Z").timeIntervalSince1970,
                       accuracy: 0.001)

        let state = try resolved(replaying, startedAt: "2026-08-16T02:30:14.000Z")
        XCTAssertEqual(state.state, .working)
        XCTAssertEqual(state.source, .transcript)

        // And the boundary: the same tail with the call answered is the shape
        // Rule 2 exists for, and it is demoted exactly as before. Six of the
        // seven stale `working` tails on disk have their call answered like
        // this, so the refinement costs Rule 2 one of the seven.
        let answered = try resolved([assistant(toolName: "Bash", id: id, timestamp: "2026-08-05T13:27:47.970Z"),
                                     result(to: id)],
                                    startedAt: "2026-08-16T02:30:14.000Z")
        XCTAssertEqual(answered.state, .idle)
        XCTAssertEqual(answered.source, .transcript)
    }

    /// The control that the refinement left `question` where it was. A dialog
    /// waiting for an answer is a turn awaiting a tool result too — the same
    /// `tool_use` block, unanswered — but the two questions stay apart:
    /// `unansweredQuestion` looks only at the two user-facing tools and still
    /// decides the state, and Rule 2 never touched `question` in the first
    /// place. A `Bash` is the mirror image: in flight, but no question.
    func testAnUnansweredDialogIsStillAQuestion() throws {
        let asked = assistant(toolName: "AskUserQuestion", id: "toolu_ask")
        let scanned = try summary([asked])
        XCTAssertEqual(scanned.fallbackState, .question)
        XCTAssertTrue(scanned.lastTurnAwaitingToolResult)

        let state = try resolved([asked], startedAt: "2026-08-16T02:30:14.000Z")
        XCTAssertEqual(state.state, .question)
        XCTAssertEqual(state.source, .transcript)

        // The two predicates asked of the same message, so that a later merge
        // of the two has to break something.
        let message = try XCTUnwrap(
            try XCTUnwrap(try JSONC.parse(assistant(toolName: "Bash")) as? [String: Any])["message"]
                as? [String: Any])
        XCTAssertTrue(ClaudeSessions.awaitingToolResult(message: message, answered: []))
        XCTAssertFalse(ClaudeSessions.unansweredQuestion(message: message, answered: []))

        // The id-less block, which the two also answer the same way and for the
        // same reason: nothing can match it, so the safe direction is the one
        // that keeps the row alive. `unansweredQuestion` has that branch pinned
        // by `testAQuestionWithoutAnIdStaysAQuestion`; this is its half. No such
        // block exists on this machine (0 of 63 855 `tool_use` blocks), so the
        // claim is what is being held here, not a case from live data.
        let idless: [String: Any] = ["content": [["type": "tool_use", "name": "Bash"]]]
        XCTAssertTrue(ClaudeSessions.awaitingToolResult(message: idless, answered: ["toolu_1"]))
    }

    private func temporaryFile() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-interrupt-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// A row shows one indicator for the whole window — I am blocking it, it has
/// something for me to read, something is moving, or it is all asleep — and one
/// number beside it. How many chats sit in which state is a question about the
/// chats, and it is answered in the tooltip.
final class RowStatusTests: XCTestCase {

    private func row(_ states: [AgentState], subagents: Int = 0) -> SwitcherRow {
        var sessions = states.enumerated().map { index, state in
            TestFixtures.session(id: "s\(index)", cwd: "/tmp/p", state: state)
        }
        // Subagents belong to a chat, so they are hung off the first one.
        if subagents > 0, !sessions.isEmpty { sessions[0].activeSubagents = subagents }
        let aggregate = DataSource.aggregate(sessions, cpu: [:], orphans: [:])
        return SwitcherRow(id: "project:/tmp/p",
                           kind: .project,
                           displayName: "p",
                           colorHex: "#000000",
                           project: nil,
                           window: nil,
                           sessions: sessions,
                           state: aggregate.state,
                           activeSubagents: aggregate.activeSubagents,
                           subagentDescriptions: aggregate.subagentDescriptions,
                           chatTopic: nil,
                           model: nil,
                           contextUsedTokens: nil,
                           contextLimitTokens: nil,
                           lastActivity: nil)
    }

    /// The two states where the agent stopped mid-task and cannot go on until a
    /// key is pressed. The user asked for these to be told apart from a
    /// finished turn: here the bottleneck is the human and the wait is pure
    /// idle time, there the work is done and the message keeps.
    func testAStuckChatIsItsOwnAnswer() {
        for state in [AgentState.question, .permission] {
            XCTAssertEqual(row([state]).status, .blocked, "\(state)")
        }
    }

    /// A finished turn nobody has read is not the same thing, and no longer
    /// wears the same icon.
    func testAFinishedTurnIsDoneNotBlocked() {
        XCTAssertEqual(row([.waiting]).status, .done)
    }

    /// Being stuck outranks having finished: a window holding both is the one
    /// to walk to first.
    func testBeingStuckOutranksHavingFinished() {
        XCTAssertEqual(row([.waiting, .question]).status, .blocked)
        XCTAssertEqual(row([.waiting, .permission, .idle]).status, .blocked)
    }

    /// And it outranks activity too: a chat waiting on a human is the one thing
    /// that does not keep, however much is running around it.
    func testBeingStuckOutranksActivity() {
        XCTAssertEqual(row([.working, .permission]).status, .blocked)
        XCTAssertEqual(row([.working, .question]).status, .blocked)
        XCTAssertEqual(row([.working, .permission, .idle]).status, .blocked)
        XCTAssertEqual(row([.idle, .question], subagents: 4).status, .blocked)
    }

    /// The mixed window, which is the case the fold exists for: one chat
    /// answered, another still working. "Done" is a claim about a turn that
    /// finished, "active" one about right now — and right now something is
    /// running, so the row says so. Saying "done" over a working window is the
    /// defect this replaced: the answer to "can I read this yet" was yes while
    /// the window went on typing.
    func testAWorkingChatOutranksAnAnsweredOne() {
        let mixed = row([.waiting, .working])
        XCTAssertEqual(mixed.status, .active)
        XCTAssertEqual(mixed.activeCount, 1)
    }

    /// Caught live, on this very project: the main chat had answered, a
    /// subagent went on working, and the row showed the green tick over a window
    /// that was visibly busy. A subagent is running work like any other.
    func testASubagentUnderAnAnsweredChatKeepsTheRowActive() {
        let row = row([.waiting], subagents: 1)
        XCTAssertEqual(row.status, .active)
        XCTAssertEqual(row.activeCount, 1)
    }

    func testAWorkingChatIsActivity() {
        XCTAssertEqual(row([.working]).status, .active)
        XCTAssertEqual(row([.working, .idle]).status, .active)
    }

    /// A subagent runs while every chat of the row sits in `idle` — that is
    /// what a background agent *is*, and it is still something moving.
    func testASubagentAloneIsActivity() {
        let row = row([.idle], subagents: 2)
        XCTAssertEqual(row.status, .active)
        XCTAssertEqual(row.activeCount, 2)
    }

    /// A window is "done" only once it has actually gone quiet: the tick means
    /// nothing is left but the reading. Three subagents grinding away under an
    /// answered chat is not that.
    func testTheTickWaitsUntilTheSubagentsAreDoneToo() {
        let row = row([.waiting], subagents: 3)
        XCTAssertEqual(row.status, .active)
        XCTAssertEqual(row.activeCount, 3)
    }

    /// Everything else is asleep — and "asleep" is a real outcome of four,
    /// reported about chats that exist and are doing nothing.
    func testEverythingElseIsAsleep() {
        XCTAssertEqual(row([.idle]).status, .asleep)
        XCTAssertEqual(row([.idle, .idle]).status, .asleep)
        XCTAssertEqual(row([.idle]).activeCount, 0)
    }

    /// A row with no chat and no subagent draws no indicator at all. Its slot
    /// stays empty: there is nothing there to be asleep, and an icon saying so
    /// would be the same mark on ninety-odd project rows that have never seen
    /// an agent — noise along the longest stretch of the list. The fixed slot
    /// is what the user asked for, not a mandatory icon.
    func testARowWithNothingToReportDrawsNoIndicator() {
        XCTAssertNil(row([]).status)
        XCTAssertEqual(row([]).activeCount, 0)
    }

    /// And "no session" is the whole test, because a subagent cannot exist
    /// without one: the aggregate sums them over the sessions, so an empty pool
    /// can only ever produce a zero. The `guard` used to check both halves, and
    /// the second half could not fire — this pins the invariant that makes it
    /// redundant, instead of the dead branch that hid behind it.
    func testASubagentCannotOutliveTheChatItRunsUnder() {
        XCTAssertEqual(DataSource.aggregate([], cpu: [:], orphans: [:]).activeSubagents, 0)
        XCTAssertNil(DataSource.aggregate([], cpu: [:], orphans: [:]).state)
    }

    /// Half the invariant lives in `aggregate`, the other half in the promise
    /// that every row's number comes *from* `aggregate` over that row's own
    /// sessions — and that half used to hold only because all three row
    /// constructors happen to be written that way. Nothing checked it, and with
    /// the `guard` gone nothing would notice a fourth constructor filling the
    /// field from somewhere else. So check it on the assembled snapshot, over
    /// every row of every kind at once: window rows, project rows and the
    /// orphan `cwd:` rows.
    func testEveryAssembledRowTakesItsSubagentsFromItsOwnChats() throws {
        var busy = TestFixtures.session(id: "s1", cwd: "/p/open", state: .working)
        busy.activeSubagents = 3
        // Two chats in one row, carrying different numbers, so that their sum is
        // neither the larger of them nor the first: 2 + 5 = 7 tells all three
        // apart. With one chat per row it told none of them apart — measured by
        // mutation, replacing the sum inside `aggregate` with a maximum passed
        // the entire suite.
        var headless = TestFixtures.session(id: "s2", cwd: "/p/headless", state: .idle)
        headless.activeSubagents = 2
        var headlessTwin = TestFixtures.session(id: "s4", cwd: "/p/headless", state: .idle)
        headlessTwin.activeSubagents = 5
        var orphan = TestFixtures.session(id: "s3", cwd: "/elsewhere/thing", state: .working)
        orphan.activeSubagents = 1

        let snapshot = DataSource.assemble(
            projects: [TestFixtures.project(path: "/p/open", rootName: "open"),
                       TestFixtures.project(path: "/p/quiet", rootName: "quiet"),
                       TestFixtures.project(path: "/p/headless", rootName: "headless")],
            // Two windows of one project, and only the second one's title names
            // the chat: the twin is left with no sessions at all, which is the
            // row this invariant is really about.
            windows: [TestFixtures.window(index: 0, title: "\u{0438}\u{043d}\u{0430}\u{044f} \u{0442}\u{0435}\u{043c}\u{0430} \u{2014} open (Workspace)"),
                      TestFixtures.window(index: 1, title: "topic s1 \u{2014} open (Workspace)")],
            sessions: [busy, headless, headlessTwin, orphan],
            accessibilityTrusted: true)

        // `rows` rather than the two lists by hand: a third list would then be
        // covered too instead of quietly skipped.
        let rows = snapshot.rows
        for row in rows {
            XCTAssertEqual(row.activeSubagents,
                           DataSource.aggregate(row.sessions, cpu: [:], orphans: [:]).activeSubagents,
                           "\(row.id)")
        }
        // Which for a row with no chats means zero, the case the dead `guard`
        // was reaching for.
        for row in rows where row.sessions.isEmpty {
            XCTAssertEqual(row.activeSubagents, 0, "\(row.id)")
            XCTAssertNil(row.status, "\(row.id)")
        }
        // And the fixture has to hold every row the loops above are for, or they
        // agree about nothing. The chat-less *window* is the fragile one: it
        // exists only because `distribute` leaves the twin empty, so if that
        // ever changes this should say so rather than quietly stop testing it.
        XCTAssertTrue(snapshot.openWindows.contains { $0.sessions.isEmpty }, "no chat-less window row")
        XCTAssertTrue(snapshot.projects.contains { $0.sessions.isEmpty }, "no chat-less project row")
        XCTAssertTrue(snapshot.projects.contains { $0.id.hasPrefix("cwd:") }, "no orphan row")
        XCTAssertTrue(rows.contains { $0.activeSubagents > 0 }, "no subagents in the snapshot")
        // And the row with two chats says 7, which is the sum and nothing else.
        // The loop above compares the row against `aggregate`, so it holds just
        // as well if both become a maximum; only a literal pins the addition —
        // and with the number now in the title line, next to the name, it is the
        // most visible thing on the row.
        let twoChats = try XCTUnwrap(snapshot.projects.first { $0.displayName == "headless" })
        XCTAssertEqual(twoChats.sessions.count, 2)
        XCTAssertEqual(twoChats.activeSubagents, 7)
        XCTAssertEqual(twoChats.activeCount, 7)
    }

    /// But a single idle chat is something to report, and it reports "asleep" —
    /// the criterion is "is there anything to say", not "which section is this".
    func testASingleIdleChatStillReportsAsleep() {
        XCTAssertEqual(row([.idle]).status, .asleep)
    }

    /// The rule as the panel meets it: an open window has chats and shows an
    /// indicator, a project nobody has worked in shows none, and a project with
    /// an agent but no window shows one.
    func testTheAssembledSnapshotDrawsIndicatorsOnlyWhereThereIsSomethingToSay() throws {
        let projects = [TestFixtures.project(path: "/p/open", rootName: "open"),
                        TestFixtures.project(path: "/p/quiet", rootName: "quiet"),
                        TestFixtures.project(path: "/p/headless", rootName: "headless")]
        let snapshot = DataSource.assemble(
            projects: projects,
            windows: [TestFixtures.window(index: 0, title: "topic \u{2014} open (Workspace)")],
            sessions: [TestFixtures.session(id: "s1", cwd: "/p/open", state: .idle),
                       TestFixtures.session(id: "s2", cwd: "/p/headless", state: .working)],
            accessibilityTrusted: true)

        XCTAssertEqual(try XCTUnwrap(snapshot.openWindows.first).status, .asleep)
        XCTAssertEqual(snapshot.projects.first { $0.displayName == "headless" }?.status, .active)
        XCTAssertNil(try XCTUnwrap(snapshot.projects.first { $0.displayName == "quiet" }).status)
    }

    /// The whole fold in one table, so no combination of the five states is
    /// left to chance. A lone chat folds the same way it always did — there is
    /// nothing beside it to outrank. The subagent column is where the priority
    /// shows: anything not blocked reads `active` while work is running under
    /// it, `waiting` included.
    func testEveryStateFoldsToItsOwnAnswer() {
        let alone: [AgentState: RowStatus] = [.question: .blocked,
                                              .permission: .blocked,
                                              .waiting: .done,
                                              .working: .active,
                                              .idle: .asleep]
        for state in AgentState.allCases {
            XCTAssertEqual(row([state]).status, alone[state], "\(state)")
            let withSubagent: RowStatus = alone[state] == .blocked ? .blocked : .active
            XCTAssertEqual(row([state], subagents: 1).status, withSubagent, "\(state) + subagent")
        }
    }

    /// The number counts chats taking a turn plus the subagents under them —
    /// one number for "how much is running here", which is what was asked for.
    func testTheCountIsWorkingChatsPlusSubagents() {
        XCTAssertEqual(row([.working, .working, .idle]).activeCount, 2)
        XCTAssertEqual(row([.working, .waiting], subagents: 2).activeCount, 3)
        XCTAssertEqual(row([.question, .permission]).activeCount, 0)
    }

    /// And it all has to reach the assembled row, not just the helper above.
    func testTheStatusIsOnTheAssembledRow() throws {
        let snapshot = DataSource.assemble(projects: [],
                                           windows: [],
                                           sessions: [TestFixtures.session(id: "a", cwd: "/tmp/p", state: .working),
                                                      TestFixtures.session(id: "b", cwd: "/tmp/p", state: .question)],
                                           accessibilityTrusted: false)
        let row = try XCTUnwrap(snapshot.projects.first)
        XCTAssertEqual(row.status, .blocked)
        XCTAssertEqual(row.activeCount, 1)
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
        let resolved = ClaudeSessions.resolveState(hook: hook, transcript: transcript,
                                                   sessionStartedAt: nil, now: now)
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
        let resolved = ClaudeSessions.resolveState(hook: hook, transcript: transcript,
                                                   sessionStartedAt: nil, now: now)
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
        XCTAssertEqual(ClaudeSessions.resolveState(hook: hook, transcript: transcript,
                                                   sessionStartedAt: nil, now: now).state, .working)
    }

    func testStaleWorkingHookWithNoOtherEvidenceDegradesToIdle() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.lastActivity = now.addingTimeInterval(-40 * 60)

        let hook = ClaudeSessions.HookStatus(state: .working,
                                             event: "UserPromptSubmit",
                                             timestamp: now.addingTimeInterval(-40 * 60))
        let resolved = ClaudeSessions.resolveState(hook: hook, transcript: transcript,
                                                   sessionStartedAt: nil, now: now)
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
        XCTAssertEqual(ClaudeSessions.resolveState(hook: hook, transcript: transcript,
                                                   sessionStartedAt: nil, now: now).state, .working)
    }

    func testStaleWorkingHookWithAStaleTranscriptStillDegrades() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.lastActivity = now.addingTimeInterval(-ClaudeSessions.transcriptLivenessSeconds - 1)

        let hook = ClaudeSessions.HookStatus(state: .working,
                                             event: "UserPromptSubmit",
                                             timestamp: now.addingTimeInterval(-301))
        XCTAssertEqual(ClaudeSessions.resolveState(hook: hook, transcript: transcript,
                                                   sessionStartedAt: nil, now: now).state, .idle)
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
            XCTAssertEqual(ClaudeSessions.resolveState(hook: hook, transcript: transcript,
                                                       sessionStartedAt: nil, now: now).state, state)
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
            let resolved = ClaudeSessions.resolveState(hook: hook, transcript: transcript,
                                                       sessionStartedAt: nil, now: now)
            XCTAssertEqual(resolved.state, state)
            XCTAssertEqual(resolved.source, .hook)
        }
    }

    /// `Stop` never fires for `AskUserQuestion` (verified on CLI 2.1.227), so
    /// nothing but a later hook can take this state off — and an old timestamp
    /// is exactly what a question that has been waiting for an hour looks like.
    func testAQuestionIsNeverAgedOutOrOverruledByTheTranscript() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .working
        transcript.lastActivity = now.addingTimeInterval(-1)

        let hook = ClaudeSessions.HookStatus(state: .question,
                                             event: "PermissionRequest",
                                             timestamp: now.addingTimeInterval(-3 * 3600))
        let resolved = ClaudeSessions.resolveState(hook: hook, transcript: transcript,
                                                   sessionStartedAt: nil, now: now)
        XCTAssertEqual(resolved.state, .question)
        XCTAssertEqual(resolved.source, .hook)
    }

    /// The other direction: the answer arrives, a hook writes over the question,
    /// and the state has to follow it down again.
    func testALaterHookTakesTheQuestionAway() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .working
        transcript.lastActivity = now.addingTimeInterval(-1)

        for (event, state) in [("PostToolUse", AgentState.working),
                               ("Stop", .waiting),
                               ("UserPromptSubmit", .working)] {
            let hook = ClaudeSessions.HookStatus(state: state, event: event, timestamp: now)
            XCTAssertEqual(ClaudeSessions.resolveState(hook: hook, transcript: transcript,
                                                       sessionStartedAt: nil, now: now).state,
                           state, "after \(event)")
        }
    }

    /// With no hooks installed at all the transcript is the only source, and it
    /// carries the question too.
    func testWithoutAHookAQuestionStillShows() {
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .question
        let resolved = ClaudeSessions.resolveState(hook: nil, transcript: transcript,
                                                   sessionStartedAt: nil)
        XCTAssertEqual(resolved.state, .question)
        XCTAssertEqual(resolved.source, .transcript)
    }

    func testWithoutAHookTheTranscriptIsUsed() {
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .waiting
        let resolved = ClaudeSessions.resolveState(hook: nil, transcript: transcript,
                                                   sessionStartedAt: nil)
        XCTAssertEqual(resolved.state, .waiting)
        XCTAssertEqual(resolved.source, .transcript)
    }

    func testWithNoSourceAtAllTheSessionIsIdle() {
        let resolved = ClaudeSessions.resolveState(hook: nil,
                                                   transcript: ClaudeSessions.TranscriptSummary(),
                                                   sessionStartedAt: nil)
        XCTAssertEqual(resolved.state, .idle)
        XCTAssertEqual(resolved.source, .unknown)
    }

    /// A resumed chat replays its last turn. Session `3fc12f86-…` of
    /// home-network was interrupted on 2026-08-08 and reopened on 2026-08-16
    /// without a single prompt typed into it: no hook file, a `tool_use` tail,
    /// and a spinner over a process that had never run a turn.
    func testATurnFromBeforeTheProcessStartedIsNotRunningNow() {
        let started = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .working
        transcript.newestRecordAt = started.addingTimeInterval(-8 * 86_400)

        let resolved = ClaudeSessions.resolveState(hook: nil,
                                                   transcript: transcript,
                                                   sessionStartedAt: started,
                                                   now: started.addingTimeInterval(60))
        XCTAssertEqual(resolved.state, .idle)
        XCTAssertEqual(resolved.source, .transcript)
    }

    /// The ordinary working session: something was written after the process
    /// that is reading it started, so the turn is this process's own.
    func testATurnStartedByTheLivingProcessStaysWorking() {
        let started = Date().addingTimeInterval(-3600)
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .working
        transcript.newestRecordAt = started.addingTimeInterval(30)

        XCTAssertEqual(ClaudeSessions.resolveState(hook: nil,
                                                   transcript: transcript,
                                                   sessionStartedAt: started).state,
                       .working)
    }

    /// Five of the thirteen live sessions in the §2.4 control run have written
    /// nothing since their own process started, and all five read `waiting`.
    /// "Answered
    /// before you resumed it" is a true statement about a resumed chat, and the
    /// green tick over it is the right thing to show.
    func testAResumedChatThatHadAnsweredKeepsWaiting() {
        let started = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .waiting
        transcript.newestRecordAt = started.addingTimeInterval(-8 * 86_400)

        let resolved = ClaudeSessions.resolveState(hook: nil,
                                                   transcript: transcript,
                                                   sessionStartedAt: started,
                                                   now: started.addingTimeInterval(60))
        XCTAssertEqual(resolved.state, .waiting)
        XCTAssertEqual(resolved.source, .transcript)
    }

    /// Neither half of the comparison may be guessed at: with no stamp, or with
    /// no `startedAt` in the session file, the state stays exactly as the
    /// transcript read it. This is the rule's own half of that — the two inputs
    /// handed to it directly. That an unreadable stamp *arrives here* as `nil`
    /// instead of as the older record's is the scanner's half, and it is pinned
    /// where the scanner is driven: `testAStampThatDoesNotParseStopsTheSearch`.
    func testAMissingStampNeverDemotesAnything() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .working

        XCTAssertEqual(ClaudeSessions.resolveState(hook: nil,
                                                   transcript: transcript,
                                                   sessionStartedAt: now,
                                                   now: now).state,
                       .working)

        transcript.newestRecordAt = now.addingTimeInterval(-8 * 86_400)
        XCTAssertEqual(ClaudeSessions.resolveState(hook: nil,
                                                   transcript: transcript,
                                                   sessionStartedAt: nil,
                                                   now: now).state,
                       .working)
    }

    /// The rule aims at the transcript fallback only. A hook that says `working`
    /// is a live event from this process, and an old tail next to it proves
    /// nothing — the turn it belongs to is not the one the hook reported.
    func testAHookWorkingSurvivesAStaleTranscriptStamp() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .working
        transcript.newestRecordAt = now.addingTimeInterval(-8 * 86_400)
        transcript.lastActivity = now.addingTimeInterval(-1)

        let hook = ClaudeSessions.HookStatus(state: .working, event: "PostToolUse", timestamp: now)
        let resolved = ClaudeSessions.resolveState(hook: hook,
                                                   transcript: transcript,
                                                   sessionStartedAt: now.addingTimeInterval(-60),
                                                   now: now)
        XCTAssertEqual(resolved.state, .working)
        XCTAssertEqual(resolved.source, .hook)
    }

    /// A fresh file mtime is not the signal, and this is the pair of cases that
    /// says why. Resuming a chat touches the transcript without appending a
    /// stamped record — the reproducer's mtime is two seconds *after* its
    /// process started — so writing alone proves somebody is alive, not that
    /// this process ever started a turn. Only a record stamp newer than the
    /// process stands the rule down, and once one exists the mtime is beside
    /// the point: an hour of silence after it changes nothing.
    func testTheFileStampIsNotTheRecordStamp() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .working
        transcript.newestRecordAt = now.addingTimeInterval(-8 * 86_400)
        transcript.lastActivity = now.addingTimeInterval(-1)

        XCTAssertEqual(ClaudeSessions.resolveState(hook: nil,
                                                   transcript: transcript,
                                                   sessionStartedAt: now.addingTimeInterval(-60),
                                                   now: now).state,
                       .idle)

        transcript.newestRecordAt = now.addingTimeInterval(-30)
        transcript.lastActivity = now.addingTimeInterval(-3600)
        XCTAssertEqual(ClaudeSessions.resolveState(hook: nil,
                                                   transcript: transcript,
                                                   sessionStartedAt: now.addingTimeInterval(-60),
                                                   now: now).state,
                       .working)
    }

    /// The hook is provably behind — the session kept writing 395 s after the
    /// last state it reported — so the transcript decides. What it must decide
    /// here is `working`: this process has written into the transcript, so the
    /// turn on screen is its own.
    func testTheOverruledHookHandsOverAStateTheStampDoesNotDemote() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .working
        transcript.newestRecordAt = now.addingTimeInterval(-5)
        transcript.lastActivity = now.addingTimeInterval(-5)

        let hook = ClaudeSessions.HookStatus(state: .idle, event: "Stop", timestamp: now.addingTimeInterval(-400))
        let resolved = ClaudeSessions.resolveState(hook: hook,
                                                   transcript: transcript,
                                                   sessionStartedAt: now.addingTimeInterval(-60),
                                                   now: now)
        XCTAssertEqual(resolved.state, .working)
        XCTAssertEqual(resolved.source, .transcript)
    }

    /// A `working` hook older than five minutes with a transcript touched five
    /// seconds ago: §2.4 promises the fresh mtime keeps the row alive, and the
    /// process-start rule must not undo that promise on the way out.
    ///
    /// It exits through the lag-overrule branch above, not through the ageing
    /// branch it is named for, and no input can make it do otherwise: liveness
    /// wants the transcript newer than `now - 120`, ageing wants the hook older
    /// than `now - 300`, and the two together always leave the transcript more
    /// than 90 s newer than the hook. So the ageing branch's own
    /// `fromTranscript ??` is unreachable with the current constants — removing
    /// it breaks no test, which was checked. The promise is what this pins.
    func testAStaleWorkingHookNextToAFreshTranscriptKeepsTheRowAlive() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        transcript.fallbackState = .working
        transcript.newestRecordAt = now.addingTimeInterval(-5)
        transcript.lastActivity = now.addingTimeInterval(-5)

        let hook = ClaudeSessions.HookStatus(state: .working,
                                             event: "UserPromptSubmit",
                                             timestamp: now.addingTimeInterval(-400))
        let resolved = ClaudeSessions.resolveState(hook: hook,
                                                   transcript: transcript,
                                                   sessionStartedAt: now.addingTimeInterval(-60),
                                                   now: now)
        XCTAssertEqual(resolved.state, .working)
        XCTAssertEqual(resolved.source, .transcript)
    }

    /// What an Escape looks like with hooks installed, and how long its `idle`
    /// waits for the hook to get out of the way. The marker moves the
    /// transcript's mtime to the moment of the Escape, so the lag-overrule
    /// branch compares the hook's age *at that moment* — and that decides
    /// between the two halves of §2.4's answer.
    ///
    /// Above the tolerance, the transcript wins at once. This is not an
    /// exotic case: 44 of the 786 markers in the §2.4 census (5.6%) were
    /// written more than 90 s after the last record that would have fired a
    /// hook, which is Escape during a long generation or a long tool call.
    /// Below it, the hook's `working` outlives the transcript's `idle` until
    /// the 300 s ageing — nothing else moves, because no hook event follows an
    /// Escape.
    func testAfterAnEscapeAStaleHookHandsOverAtOnce() {
        let now = Date()
        var transcript = ClaudeSessions.TranscriptSummary()
        // Rule 1 has read the marker; the marker itself is what touched the file.
        transcript.fallbackState = .idle
        transcript.newestRecordAt = now
        transcript.lastActivity = now
        let started = now.addingTimeInterval(-3600)

        let stale = ClaudeSessions.HookStatus(state: .working, event: "PostToolUse",
                                              timestamp: now.addingTimeInterval(-91))
        let overruled = ClaudeSessions.resolveState(hook: stale, transcript: transcript,
                                                    sessionStartedAt: started, now: now)
        XCTAssertEqual(overruled.state, .idle)
        XCTAssertEqual(overruled.source, .transcript)

        let hookTime = now.addingTimeInterval(-89)
        let recent = ClaudeSessions.HookStatus(state: .working, event: "PostToolUse", timestamp: hookTime)
        let held = ClaudeSessions.resolveState(hook: recent, transcript: transcript,
                                               sessionStartedAt: started, now: now)
        XCTAssertEqual(held.state, .working)
        XCTAssertEqual(held.source, .hook)

        // The mtime is frozen at the Escape, so the gap the branch above looks
        // at never grows: only the 300 s ageing ends this one.
        let aged = ClaudeSessions.resolveState(hook: recent, transcript: transcript,
                                               sessionStartedAt: started,
                                               now: hookTime.addingTimeInterval(301))
        XCTAssertEqual(aged.state, .idle)
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
        XCTAssertEqual(row.status, .active)
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
        XCTAssertEqual(snapshot.projects.first { $0.project?.path == "/p/a" }?.activeCount, 1)
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
        XCTAssertEqual(row.status, .blocked)
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

    /// An orphan `cwd:` row is a live agent running outside every scan root, so
    /// it goes ahead of the projects rather than after them — appended last it
    /// sat at position 93 of 93, four screens down. The ranking of the projects
    /// themselves is untouched.
    func testOrphanRowsComeAheadOfTheRankedProjects() {
        let projects = ["quiet", "busy"].map { makeProject(path: "/p/\($0)", rootName: $0) }
        let orphan = makeSession(id: "s1", cwd: "/somewhere/else", state: .working)

        let snapshot = DataSource.assemble(projects: projects,
                                           windows: [],
                                           sessions: [orphan],
                                           activity: ["/p/busy": ProjectActivity(recentSessions: 9,
                                                                                 lastSession: Date())],
                                           accessibilityTrusted: true)

        XCTAssertEqual(snapshot.projects.map(\.id),
                       ["cwd:/somewhere/else", "project:/p/busy", "project:/p/quiet"])
    }

    /// Removing the orphans must not disturb the projects: the same call without
    /// the outside session produces the project order the previous test saw
    /// below the orphan.
    func testTheProjectOrderIsTheSameWithAndWithoutOrphans() {
        let projects = ["quiet", "busy"].map { makeProject(path: "/p/\($0)", rootName: $0) }
        let activity = ["/p/busy": ProjectActivity(recentSessions: 9, lastSession: Date())]

        let withOrphan = DataSource.assemble(projects: projects,
                                             windows: [],
                                             sessions: [makeSession(id: "s1",
                                                                    cwd: "/somewhere/else",
                                                                    state: .working)],
                                             activity: activity,
                                             accessibilityTrusted: true)
        let without = DataSource.assemble(projects: projects,
                                          windows: [],
                                          sessions: [],
                                          activity: activity,
                                          accessibilityTrusted: true)

        XCTAssertEqual(withOrphan.projects.filter { $0.project != nil }.map(\.id),
                       without.projects.map(\.id))
    }

    /// Among themselves the orphans are ordered by how much they need looking
    /// at: the state first, the freshest activity next.
    func testOrphansAreOrderedByStateThenFreshness() {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let sessions = [
            TestFixtures.session(id: "s1", cwd: "/out/idle", state: .idle,
                                 lastActivity: old.addingTimeInterval(500)),
            TestFixtures.session(id: "s2", cwd: "/out/stale-work", state: .working, lastActivity: old),
            TestFixtures.session(id: "s3", cwd: "/out/blocked", state: .permission, lastActivity: old),
            TestFixtures.session(id: "s4", cwd: "/out/fresh-work", state: .working,
                                 lastActivity: old.addingTimeInterval(100))
        ]

        let snapshot = DataSource.assemble(projects: [],
                                           windows: [],
                                           sessions: sessions,
                                           accessibilityTrusted: true)

        XCTAssertEqual(snapshot.projects.map(\.id),
                       ["cwd:/out/blocked", "cwd:/out/fresh-work", "cwd:/out/stale-work", "cwd:/out/idle"])
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

/// The order of the "open windows" section: the last message written in each
/// window, newest first. The z-order the Accessibility API reports is the stack
/// of what was clicked, and a window untouched since morning sits on top of it
/// merely because it was focused last.
final class WindowOrderingTests: XCTestCase {

    private func minutesAgo(_ minutes: Double) -> Date {
        Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(-minutes * 60)
    }

    /// One window row holding a chat per stamp given, in the z-order position it
    /// is passed in.
    private func row(_ name: String, _ activity: [Date?], shown: Date? = nil) -> SwitcherRow {
        let sessions = activity.enumerated().map { offset, stamp -> ClaudeSessionInfo in
            var session = TestFixtures.session(id: "\(name)-\(offset)", cwd: "/p/\(name)", state: .idle)
            session.lastActivity = stamp
            return session
        }
        return SwitcherRow(id: "window:1:w-\(name)",
                           kind: .window,
                           displayName: name,
                           colorHex: "#000000",
                           project: nil,
                           window: nil,
                           sessions: sessions,
                           state: sessions.isEmpty ? nil : .idle,
                           activeSubagents: 0,
                           subagentDescriptions: [],
                           chatTopic: nil,
                           model: nil,
                           contextUsedTokens: nil,
                           contextLimitTokens: nil,
                           lastActivity: shown)
    }

    private func ordered(_ rows: [SwitcherRow]) -> [String] {
        DataSource.rankedWindows(rows).map(\.displayName)
    }

    func testTheWindowWithTheLastMessageComesFirst() {
        // Handed over in z-order, which says the opposite.
        XCTAssertEqual(ordered([row("stale", [minutesAgo(90)]),
                                row("fresh", [minutesAgo(1)]),
                                row("middling", [minutesAgo(10)])]),
                       ["fresh", "middling", "stale"])
    }

    /// The key is the newest chat of the row, not the one the row happens to
    /// show: a window whose visible chat has been idle for an hour can hold
    /// another that answered a second ago.
    func testTheKeyIsTheNewestChatNotTheShownOne() {
        let mixed = row("mixed", [minutesAgo(90), minutesAgo(1)], shown: minutesAgo(90))
        XCTAssertEqual(ordered([row("plain", [minutesAgo(10)]), mixed]), ["mixed", "plain"])
    }

    /// A window with no chat has no activity at all. It goes below every window
    /// that has one — the accepted price of ordering by activity: a window
    /// opened by hand, with no agent in it, sinks to the bottom.
    func testAWindowWithNoChatSinksBelowEveryWindowThatHasOne() {
        XCTAssertEqual(ordered([row("empty", []), row("ancient", [minutesAgo(10_000)])]),
                       ["ancient", "empty"])
    }

    /// And among themselves those keep the z-order they arrived in. `sorted` is
    /// not stable, so without the arrival index they were free to swap places
    /// between two snapshots a second apart.
    func testWindowsWithNoChatKeepTheirZOrder() {
        XCTAssertEqual(ordered([row("first", []), row("second", []), row("third", [])]),
                       ["first", "second", "third"])
    }

    func testEqualStampsKeepTheZOrder() {
        let same = minutesAgo(5)
        XCTAssertEqual(ordered([row("a", [same]), row("b", [same]), row("c", [same])]),
                       ["a", "b", "c"])
        // A chat with no stamp of its own does not drag its row down when
        // another chat in the same window has one.
        XCTAssertEqual(ordered([row("nostamp", [nil]), row("stamped", [same])]),
                       ["stamped", "nostamp"])
    }

    /// And the snapshot comes out ordered, not just the helper.
    func testTheAssembledSnapshotIsOrderedByActivity() {
        let projects = [TestFixtures.project(path: "/p/stale", rootName: "stale"),
                        TestFixtures.project(path: "/p/fresh", rootName: "fresh")]
        // z-order: the stale window is in front, because it was clicked last.
        let windows = [TestFixtures.window(index: 0, title: "topic \u{2014} stale (Workspace)", windowNumber: 1),
                       TestFixtures.window(index: 1, title: "topic \u{2014} fresh (Workspace)", windowNumber: 2)]
        let sessions = [TestFixtures.session(id: "s1", cwd: "/p/stale", state: .idle,
                                             lastActivity: minutesAgo(90)),
                        TestFixtures.session(id: "s2", cwd: "/p/fresh", state: .idle,
                                             lastActivity: minutesAgo(1))]

        let snapshot = DataSource.assemble(projects: projects,
                                           windows: windows,
                                           sessions: sessions,
                                           accessibilityTrusted: true)
        XCTAssertEqual(snapshot.openWindows.map(\.displayName), ["fresh", "stale"])
    }
}

/// The order of the "projects" section: when Claude Code work last happened in
/// each project, newest first. Directory mtime, which this used to be, does not
/// move when a file inside the project is edited, so the order it produced
/// looked arbitrary; the key is the mtime of the newest session transcript
/// instead. The count of sessions inside the window, which ordered this section
/// for a while in between, answers "how much" rather than "where" and no longer
/// takes part.
final class ProjectRankingTests: XCTestCase {

    private func daysAgo(_ days: Double) -> Date {
        Date().addingTimeInterval(-days * 86_400)
    }

    private func rows(_ names: [String]) -> [SwitcherRow] {
        names.map { name -> SwitcherRow in
            let project = TestFixtures.project(path: "/p/\(name)", rootName: name)
            return SwitcherRow(id: "project:\(project.path)",
                               kind: .project,
                               displayName: name,
                               colorHex: project.colorHex,
                               project: project,
                               window: nil,
                               sessions: [],
                               state: nil,
                               activeSubagents: 0,
                               subagentDescriptions: [],
                               chatTopic: nil,
                               model: nil,
                               contextUsedTokens: nil,
                               contextLimitTokens: nil,
                               lastActivity: nil)
        }
    }

    private func byPath(_ activity: [String: ProjectActivity]) -> [String: ProjectActivity] {
        var result: [String: ProjectActivity] = [:]
        for (name, value) in activity { result["/p/\(name)"] = value }
        return result
    }

    private func ranked(_ names: [String], _ activity: [String: ProjectActivity]) -> [String] {
        DataSource.ranked(rows(names), activity: byPath(activity)).map(\.displayName)
    }

    /// The case that made the rule change, in the numbers it was caught with:
    /// `pebble` had 36 sessions in the window and none for eight days, while
    /// `glazy_solver` had 7 and was being worked in that same day. Ordering by
    /// the count put the closed project on top of the open one, which is the
    /// opposite of what the section is opened to find.
    func testALargePileOfOldSessionsLosesToOneToday() {
        XCTAssertEqual(ranked(["pebble", "glazy_solver"],
                              ["pebble": ProjectActivity(recentSessions: 36, lastSession: daysAgo(8)),
                               "glazy_solver": ProjectActivity(recentSessions: 7, lastSession: daysAgo(0))]),
                       ["glazy_solver", "pebble"])
    }

    /// And that is the whole rule: the newest session first, whatever the counts
    /// say. Handed over in an order that says the opposite.
    func testTheProjectsAreOrderedByTheNewestSession() {
        XCTAssertEqual(ranked(["stale", "fresh", "middling"],
                              ["stale": ProjectActivity(recentSessions: 64, lastSession: daysAgo(9)),
                               "fresh": ProjectActivity(recentSessions: 1, lastSession: daysAgo(0)),
                               "middling": ProjectActivity(recentSessions: 31, lastSession: daysAgo(3))]),
                       ["fresh", "middling", "stale"])
    }

    /// The activity window no longer bounds the order. A session older than
    /// `activityWindowDays` still places its project, and places it above one
    /// whose newest session is older still — the window survives only as the
    /// count `--dump` prints.
    func testASessionOlderThanTheWindowStillPlacesItsProject() {
        XCTAssertEqual(ranked(["ancient", "old", "live"],
                              ["ancient": ProjectActivity(recentSessions: 0, lastSession: daysAgo(200)),
                               "old": ProjectActivity(recentSessions: 0, lastSession: daysAgo(40)),
                               "live": ProjectActivity(recentSessions: 3, lastSession: daysAgo(1))]),
                       ["live", "old", "ancient"])
    }

    /// A project that never hosted a session has no time at all and sinks below
    /// every project that has one, keeping the directory-mtime order the index
    /// handed it over in.
    func testProjectsWithNoSessionAtAllSink() {
        XCTAssertEqual(ranked(["never-a", "old", "never-b", "older", "live"],
                              ["old": ProjectActivity(recentSessions: 0, lastSession: daysAgo(40)),
                               "older": ProjectActivity(recentSessions: 0, lastSession: daysAgo(90)),
                               "live": ProjectActivity(recentSessions: 1, lastSession: daysAgo(2))]),
                       ["live", "old", "older", "never-a", "never-b"])
    }

    /// Rows the key cannot separate keep the order they arrived in: `sorted` is
    /// not stable, so without the explicit tiebreak they would be free to swap
    /// places between two snapshots a second apart. The counts differ here on
    /// purpose — they are not allowed to break the tie either.
    func testProjectsWithTheSameLastSessionKeepTheirArrivalOrder() {
        let same = daysAgo(2)
        XCTAssertEqual(ranked(["a", "b", "c"],
                              ["a": ProjectActivity(recentSessions: 1, lastSession: same),
                               "b": ProjectActivity(recentSessions: 40, lastSession: same),
                               "c": ProjectActivity(recentSessions: 9, lastSession: same)]),
                       ["a", "b", "c"])
    }

    /// With no activity known at all — the default the pure `assemble` is called
    /// with in tests — the rows come back exactly as they arrived.
    func testNoActivityLeavesTheOrderAlone() {
        XCTAssertEqual(ranked(["a", "b", "c"], [:]), ["a", "b", "c"])
    }

    /// The tie-break, asked of the comparison itself rather than through
    /// `sorted`. The test above goes through `sorted`, and `sorted` cannot show
    /// this: it is only documented as unstable, while the implementation shipping
    /// today leaves equal elements where they were — so with the arrival-index
    /// line deleted the whole ranking suite stays green and the order becomes
    /// whatever the next standard library feels like. Asked directly, the
    /// comparison has to answer both ways round, and a comparison that has run
    /// out of keys cannot.
    func testTheComparisonSeparatesRowsTheStampsCannot() {
        let pair = rows(["a", "b"])
        let left = (offset: 0, element: pair[0])
        let right = (offset: 1, element: pair[1])

        // Neither project ever hosted a session: the real tie, and the one that
        // happens on this machine — 63 projects of 93 (SPEC §2.2.1).
        XCTAssertTrue(DataSource.ranksAbove(left, right, activity: [:]))
        XCTAssertFalse(DataSource.ranksAbove(right, left, activity: [:]))

        // And on stamps that are equal rather than absent.
        let same = daysAgo(2)
        let activity = byPath(["a": ProjectActivity(recentSessions: 1, lastSession: same),
                               "b": ProjectActivity(recentSessions: 40, lastSession: same)])
        XCTAssertTrue(DataSource.ranksAbove(left, right, activity: activity))
        XCTAssertFalse(DataSource.ranksAbove(right, left, activity: activity))
    }
}

/// Counting a project's sessions on disk: one `*.jsonl` per session in
/// `~/.claude/projects/<slug>/`, the mtime of each being its last activity.
final class ProjectActivityTests: XCTestCase {

    func testCountsOnlyTheSessionsInsideTheWindow() throws {
        let root = try makeTemporaryDirectory()
        let path = "/Users/x/Data/Projects/ukuetis_panel_fw"
        let now = Date()
        try makeSessions(in: root, forPath: path,
                         mtimes: [0.5, 3, 12, 45, 400].map { now.addingTimeInterval(-$0 * 86_400) })

        let activity = ClaudeSessions.activity(forPath: path, windowDays: 30, now: now,
                                               projectsDirectory: root)
        XCTAssertEqual(activity.recentSessions, 3)
        // `lastSession` is the newest of *any* age, which is what orders the
        // projects that have nothing inside the window.
        XCTAssertEqual(activity.lastSession?.timeIntervalSince(now) ?? 0, -0.5 * 86_400, accuracy: 1)
    }

    /// The listing is cached against the directory's mtime, and starting a
    /// session writes a new file into it — which is exactly what moves that
    /// mtime.
    func testANewSessionInvalidatesTheCachedListing() throws {
        let root = try makeTemporaryDirectory()
        let path = "/Users/x/Data/Projects/glazy_solver"
        let now = Date()
        try makeSessions(in: root, forPath: path, mtimes: [now.addingTimeInterval(-3600)])
        XCTAssertEqual(ClaudeSessions.activity(forPath: path, windowDays: 30, now: now,
                                               projectsDirectory: root).recentSessions, 1)

        try makeSessions(in: root, forPath: path, mtimes: [now])
        XCTAssertEqual(ClaudeSessions.activity(forPath: path, windowDays: 30, now: now,
                                               projectsDirectory: root).recentSessions, 2)
    }

    /// Working on in a session that is already open moves that transcript's
    /// mtime and nothing else: the directory's own mtime and size stay put,
    /// because no entry was added or removed. So the timestamps must be read
    /// fresh every time — cached alongside the listing they froze at the moment
    /// the last session was *started*, and since `lastSession` is what orders
    /// the section (§2.2.1), the project being worked in right now would sit
    /// where it stood hours ago. The gap is 1.7 h at the median on the owner's
    /// machine and 222 h at the worst.
    func testWritingIntoAnOpenSessionMovesLastSessionWithoutANewFile() throws {
        let root = try makeTemporaryDirectory()
        let path = "/Users/x/Data/Projects/pebble"
        let now = Date()
        try makeSessions(in: root, forPath: path, mtimes: [now.addingTimeInterval(-8 * 86_400)])
        let directory = root.appendingPathComponent(ClaudeSessions.slug(forPath: path))
        let before = try FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate] as? Date
        // Unwrapped rather than defaulted: a `nil` here has to fail the test, and
        // any default value stands a chance of landing inside the tolerance of
        // the number it is compared against.
        let stale = try XCTUnwrap(ClaudeSessions.activity(forPath: path, windowDays: 30, now: now,
                                                          projectsDirectory: root).lastSession)
        XCTAssertEqual(stale.timeIntervalSince(now), -8 * 86_400, accuracy: 1)

        let transcript = try XCTUnwrap(try FileManager.default
            .contentsOfDirectory(atPath: directory.path).first { $0.hasSuffix(".jsonl") })
        try FileManager.default.setAttributes([.modificationDate: now],
                                              ofItemAtPath: directory.appendingPathComponent(transcript).path)

        // The directory itself did not move, which is the whole point.
        XCTAssertEqual(try FileManager.default
            .attributesOfItem(atPath: directory.path)[.modificationDate] as? Date, before)
        let last = try XCTUnwrap(ClaudeSessions.activity(forPath: path, windowDays: 30, now: now,
                                                         projectsDirectory: root).lastSession)
        XCTAssertEqual(last.timeIntervalSince(now), 0, accuracy: 1)
    }

    /// A project that never hosted a session has no directory here at all, and
    /// some directories that do exist hold no transcript — worktree snapshots,
    /// sessions since deleted. Both are ordinary.
    func testAMissingOrEmptyDirectoryIsNotAnError() throws {
        let root = try makeTemporaryDirectory()
        XCTAssertEqual(ClaudeSessions.activity(forPath: "/Users/x/never", windowDays: 30,
                                               projectsDirectory: root),
                       ProjectActivity())

        let path = "/Users/x/empty"
        let directory = root.appendingPathComponent(ClaudeSessions.slug(forPath: path))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeSessions.activity(forPath: path, windowDays: 30,
                                               projectsDirectory: root),
                       ProjectActivity())
    }

    private func makeSessions(in projectsDirectory: URL, forPath path: String, mtimes: [Date]) throws {
        let fileManager = FileManager.default
        let directory = projectsDirectory.appendingPathComponent(ClaudeSessions.slug(forPath: path))
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for mtime in mtimes {
            let file = directory.appendingPathComponent("\(UUID().uuidString).jsonl")
            try Data().write(to: file)
            try fileManager.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }
        // The mtime a fresh write leaves on the directory can land inside the
        // same instant as the previous read, and then the cache key has not
        // moved. Pushing it forward makes the invalidation the test's subject
        // rather than the clock's.
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                      ofItemAtPath: directory.path)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
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

    func testTheActivityWindowIsTunableAndRejectsNonsense() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-config-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        try #"{"activityWindowDays": 7}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(Config.load(from: url).activityWindowDays, 7)

        try #"{"activityWindowDays": 0}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(Config.load(from: url).activityWindowDays, Config.default.activityWindowDays)
    }

    func testTildeExpansion() {
        var config = Config.default
        config.projectRoots = ["~/Data/Projects", "~/Data/Projects"]
        XCTAssertEqual(config.resolvedProjectRoots.count, 1)
        XCTAssertFalse(config.resolvedProjectRoots[0].path.contains("~"))
    }

    /// **A key this file has retired is a key nobody has to remove**, and that is
    /// the whole promise made to a config written before it went.
    ///
    /// `usageLoadWindowHours` chose between two ways of estimating the week's
    /// demand and, by the same number, how deep to fetch. Nothing estimates
    /// demand any more — the gateway measures it — so both estimators went and
    /// the key with them. `load` walks the keys it knows rather than the keys the
    /// file has, so what is left of it is nothing at all: not a default, not a
    /// warning, no effect on any other field.
    ///
    /// Asked alongside a key that *is* read, because "the file was ignored
    /// wholesale" would satisfy the first half on its own and is the failure this
    /// is really about — a retired key must not take its neighbours down with it.
    func testARetiredKeyIsIgnoredWithoutDisturbingTheRest() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-config-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        try #"{"usageLoadWindowHours": 6, "scanDepth": 3}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let config = Config.load(from: url)
        XCTAssertEqual(config.scanDepth, 3,
                       "a key nobody reads any more took the whole file down with it")
        XCTAssertEqual(config, {
            var expected = Config.default
            expected.scanDepth = 3
            return expected
        }(), "the retired key moved something, and it is not supposed to be able to")
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

    /// The mirror of that defect, through the same plain entry point: an arrival
    /// stamp from the *future* — a `Date()` read after the build rather than
    /// before the call, an interval added to it, a clock nudged forward — is
    /// never reached by `lastSnapshotFinishedAt`, so the coalescing stops
    /// happening at all and everyone who queued behind a build in flight goes
    /// off and rescans the same disk the moment they are let through. It is
    /// silent: every answer stays correct and only the I/O multiplies, which is
    /// the one thing the coalescing exists to prevent.
    ///
    /// The build signals that it has started and then holds the lock for 0.3 s,
    /// so the second call is made — and its arrival stamped — well before the
    /// build finishes, with no race to lose.
    func testACallerArrivingDuringABuildSharesItThroughThePlainEntryPoint() {
        let counter = BuildCounter()
        let started = DispatchSemaphore(value: 0)
        let source = DataSource(config: .default) {
            counter.increment()
            started.signal()
            Thread.sleep(forTimeInterval: 0.3)
            return SwitcherSnapshot(openWindows: [],
                                    projects: [],
                                    accessibilityTrusted: false,
                                    generatedAt: Date(timeIntervalSince1970: Double(counter.value)))
        }

        let building = ResultBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            building.add(source.snapshot())
            finished.signal()
        }
        started.wait()
        let queued = source.snapshot()
        finished.wait()

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(queued.generatedAt, building.values.first?.generatedAt)
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

/// The two halves of "this subagent is still working" (SPEC §3.1).
///
/// The threshold is always passed in rather than taken from `Config.default`:
/// these are about the mechanism, not about the number, and the number moves —
/// it went from 90 s to 600 s once already.
final class SubagentLivenessTests: XCTestCase {

    /// The invariant everything else rests on: a subagent that ended normally
    /// goes quiet on its final record, at any threshold. Raising
    /// `subagentActiveSeconds` is only safe because the clock never gets asked
    /// about a subagent that finished.
    func testAFinishedSubagentIsInactiveWhileItsTranscriptIsStillFresh() throws {
        let root = try makeTemporaryDirectory()
        try writeTranscript(assistantTail(stopReason: "end_turn"), age: 0, in: root)

        for threshold in [300.0, 86_400.0] {
            XCTAssertEqual(subagents(in: root, activeSeconds: threshold).map(\.isActive),
                           [false],
                           "threshold \(threshold)")
        }
    }

    /// `stop_sequence` ends a turn the same way `end_turn` does (§2.4), so it
    /// has to gate the same way. Named only in the last record, which is why
    /// this is a separate transcript rather than an extra assertion.
    func testAStopSequenceEndsTheSubagentToo() throws {
        let root = try makeTemporaryDirectory()
        try writeTranscript(assistantTail(stopReason: "stop_sequence"), age: 0, in: root)

        XCTAssertEqual(subagents(in: root, activeSeconds: 300).map(\.isActive), [false])
    }

    /// The other way a subagent stops: the user cut it short — 166 of the 2776
    /// tails on this machine end on the marker (SPEC §3.1). Something does get
    /// appended after a marker now and then, and then that record becomes the
    /// tail and is read instead; it is how often that happens that separates a
    /// subagent from the main chain — 19 markers of 185 against 789 of 793 —
    /// which is why §2.4 needs a rule for it and this one line is enough here.
    func testAnInterruptedSubagentIsInactiveAtAnyThreshold() throws {
        let root = try makeTemporaryDirectory()
        try writeTranscript(Self.interrupted, age: 0, in: root)

        for threshold in [300.0, 86_400.0] {
            XCTAssertEqual(subagents(in: root, activeSeconds: threshold).map(\.isActive),
                           [false],
                           "threshold \(threshold)")
        }
    }

    /// The price of the fix, written down rather than left implicit: an answer
    /// that was delivered but carries `stop_reason: null` is *not* read as an
    /// ending, so its row keeps spinning until the clock runs out — 243 of the
    /// same 2776 tails. It stays that way on purpose: across the corpus read
    /// whole, the identical shape sits mid-turn 22204 times against 245 as a
    /// last record, so calling it an ending would blank the indicator over a
    /// subagent that is still working (SPEC §3.1).
    ///
    /// Two things hang on this row staying `true`: the `as? String` in
    /// `uncachedIsFinished` — JSON `null` parses to `NSNull`, not to a string —
    /// and the whitelist, in the form the blacklist is naturally written in.
    /// `stopReason != "tool_use"` over the *optional* needs no `guard let` and
    /// so drops it; that version passes every other test in this class and
    /// fails this one. The version that keeps the `guard let` is a different
    /// matter — see the test below.
    func testADeliveredAnswerWithoutAStopReasonKeepsWorking() throws {
        let root = try makeTemporaryDirectory()
        try writeTranscript(Self.deliveredWithoutStopReason, age: 60, in: root)

        XCTAssertEqual(subagents(in: root, activeSeconds: 300).map(\.isActive), [true])
    }

    /// The rule is a whitelist: only a proven ending ends a subagent, anything
    /// else keeps the row working until the clock retires it. That direction is
    /// the whole point — a value nobody has seen must not blank the indicator
    /// over a subagent that is still going.
    ///
    /// Four `stop_reason` values occur among the tails (`end_turn`,
    /// `stop_sequence`, `tool_use`, `null`), and on every one of them a
    /// blacklist that keeps the `guard let` answers exactly as the whitelist
    /// does — which is why that mutation survives everything else here. A fifth
    /// value is not hypothetical, though: read whole, the corpus has one
    /// `refusal` — record 53 of 91 in `agent-abbf674d09bc1b914.jsonl` — which
    /// has simply never landed last yet (SPEC §2.5). This pins what happens
    /// when it does.
    func testAnUnknownStopReasonIsNotAnEnding() throws {
        let root = try makeTemporaryDirectory()
        try writeTranscript(assistantTail(stopReason: "max_tokens"), age: 60, in: root)

        XCTAssertEqual(subagents(in: root, activeSeconds: 300).map(\.isActive), [true])
    }

    /// A tail that stopped mid-turn — the shape a thinking subagent leaves
    /// behind — is working as long as the clock allows.
    func testAnUnfinishedTranscriptWithinTheThresholdIsActive() throws {
        let root = try makeTemporaryDirectory()
        try writeTranscript(Self.toolResult, age: 60, in: root)

        XCTAssertEqual(subagents(in: root, activeSeconds: 300).map(\.isActive), [true])
    }

    /// The same tail past the threshold: the age is the only thing that can
    /// ever retire a transcript that was cut off before its final record.
    func testAnUnfinishedTranscriptOlderThanTheThresholdIsNotActive() throws {
        let root = try makeTemporaryDirectory()
        try writeTranscript(Self.toolResult, age: 60, in: root)

        XCTAssertEqual(subagents(in: root, activeSeconds: 30).map(\.isActive), [false])
    }

    /// A final answer longer than the 64 KB tail window: once the cut first line
    /// is dropped no whole line is left, and the finished subagent kept spinning
    /// until the clock retired it — 33 of 2786 tails, 31 of them `end_turn`
    /// (SPEC §3.1). 128 KiB of text is past the first doubled window as well.
    func testAFinalAnswerLongerThanTheTailWindowStillEndsTheSubagent() throws {
        let root = try makeTemporaryDirectory()
        let text = String(repeating: "x", count: 128 * 1024)
        try writeTranscript(Self.toolResult
                                + #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn"}}"#
                                + "\n",
                            age: 0,
                            in: root)

        XCTAssertEqual(subagents(in: root, activeSeconds: 300).map(\.isActive), [false])
    }

    /// Workflow agents sit two levels down, in `subagents/workflows/wf_<id>/`.
    /// Adding one there does not move the mtime of `subagents/`, so the agent
    /// that starts after the listing was cached has to show up all the same.
    func testWorkflowSubagentsAreListedEvenWhenAddedAfterTheListingWasCached() throws {
        let root = try makeTemporaryDirectory()
        try writeTranscript(Self.toolResult, age: 0, in: root)
        try writeTranscript(Self.toolResult, age: 0, in: root, name: "workflows/wf_x/agent-y.jsonl")
        XCTAssertEqual(Set(subagents(in: root, activeSeconds: 300).filter(\.isActive).map(\.id)),
                       ["a48ba5a32f6185898", "y"])

        try writeTranscript(Self.toolResult, age: 0, in: root, name: "workflows/wf_x/agent-z.jsonl")
        XCTAssertEqual(Set(subagents(in: root, activeSeconds: 300).filter(\.isActive).map(\.id)),
                       ["a48ba5a32f6185898", "y", "z"])
    }

    private let slug = "-Users-x-Data-Projects-pebble"
    private let sessionID = "914f8824-0e0e-4a0a-9b0b-000000000000"

    private func subagents(in projectsDirectory: URL, activeSeconds: Double) -> [SubagentInfo] {
        var config = Config.default
        config.subagentActiveSeconds = activeSeconds
        return ClaudeSessions.subagents(slug: slug,
                                        sessionId: sessionID,
                                        config: config,
                                        projectsDirectory: projectsDirectory)
    }

    /// One `agent-<id>.jsonl` with an explicit mtime. Waiting out a real clock
    /// would make the age half untestable at any useful threshold.
    private func writeTranscript(_ contents: String,
                                 age: TimeInterval,
                                 in projectsDirectory: URL,
                                 name: String = "agent-a48ba5a32f6185898.jsonl") throws {
        let file = projectsDirectory
            .appendingPathComponent(slug)
            .appendingPathComponent(sessionID)
            .appendingPathComponent("subagents")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                                              ofItemAtPath: file.path)
    }

    /// The last record before the answer: a tool call that came back. On its
    /// own this is an unfinished tail.
    private static let toolResult =
        ##"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"## + "\n"

    /// What a subagent the user cut short leaves behind: the marker in its
    /// block shape, on a `user` record.
    private static let interrupted = toolResult
        + ##"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"##
        + "\n"

    /// An assistant record that reads like a finished answer and does not say
    /// so anywhere in its shape. The `###` delimiters are for the heading the
    /// answer opens with: `"##` would close a `##`-delimited literal.
    private static let deliveredWithoutStopReason = toolResult
        + ###"{"type":"assistant","message":{"content":[{"type":"text","text":"## Done — added the moving average line"}],"stop_reason":null,"stop_details":null}}"###
        + "\n"

    private func assistantTail(stopReason: String) -> String {
        Self.toolResult
            + #"{"type":"assistant","message":{"stop_reason":"\#(stopReason)"}}"#
            + "\n"
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-subagent-liveness-\(UUID().uuidString)")
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

/// Which processes belong to which session, and what a rate between two sweeps
/// is allowed to mean (SPEC §2.8).
///
/// The attribution is asked directly rather than through a sweep of the machine
/// the tests run on: through a sweep a wrong answer is a percentage that looks
/// slightly off, which is also what a dozen unrelated mistakes look like.
final class SessionProcessTests: XCTestCase {

    private func facts(_ rows: [(pid: Int32, ppid: Int32, marker: Int32?)]) -> [SessionProcesses.Facts] {
        rows.map { SessionProcesses.Facts(pid: $0.pid, ppid: $0.ppid, marker: $0.marker) }
    }

    private func key(_ pid: Int32, _ start: UInt64) -> SessionProcesses.Key {
        SessionProcesses.Key(pid: pid, startTime: start)
    }

    /// One sweep's reading of a process. `ppid: 1` unless the fixture is about
    /// the tree, so that a vanished process in it has no heir and its
    /// already-reported total is owed by nobody.
    private func counters(_ own: UInt64,
                          child: UInt64 = 0,
                          ppid: Int32 = 1) -> SessionProcesses.Counters {
        SessionProcesses.Counters(ppid: ppid, own: own, child: child)
    }

    /// The rates alone, for the fixtures that start with an empty ledger — which
    /// is every fixture that is not about the ledger itself. Those call
    /// `SessionProcesses.rates` directly and read `debts` off the answer.
    private func percents(previous: [SessionProcesses.Key: SessionProcesses.Counters],
                          current: [SessionProcesses.Key: SessionProcesses.Counters],
                          elapsed: TimeInterval) -> [SessionProcesses.Key: Double]? {
        SessionProcesses.rates(previous: previous, current: current,
                               elapsed: elapsed, debts: [:])?.percentByKey
    }

    /// A debt written down this instant, for the fixtures that hand the ledger
    /// in rather than build it up over two passes. The ledger is keyed by the
    /// **debtor** and names the survivor it is charged to inside the entry, so
    /// both halves have to be given.
    private func debt(_ nanos: UInt64,
                      to heir: SessionProcesses.Key,
                      age: TimeInterval = 0) -> SessionProcesses.Debt {
        SessionProcesses.Debt(nanos: nanos, age: age, heir: heir)
    }

    /// The owner table `ProcessSampler` builds: attribution answers in pids,
    /// because the process tree is pid-shaped, and the sum is over keys.
    private func owners(_ attribution: SessionProcesses.Attribution,
                        startTime: UInt64) -> [SessionProcesses.Key: Int32] {
        var table: [SessionProcesses.Key: Int32] = [:]
        for (pid, owner) in attribution.ownerByPID { table[key(pid, startTime)] = owner }
        return table
    }

    // MARK: - The parent chain

    /// The ordinary case, and the one that carries almost everything: 261 of the
    /// 262 processes attributed on this machine came this way.
    ///
    /// The session's own process is in there too, mapped to itself — without
    /// that the `claude` binary's own CPU, which is most of a busy session's,
    /// would count towards nothing.
    func testAChildBelongsToTheSessionItHangsFrom() {
        let attribution = SessionProcesses.attribute(facts([(pid: 100, ppid: 1, marker: nil),
                                                            (pid: 200, ppid: 100, marker: nil)]),
                                                     sessionPIDs: [100])
        XCTAssertEqual(attribution.ownerByPID, [100: 100, 200: 100])
        XCTAssertEqual(attribution.orphansBySessionPID, [:])
    }

    /// And it is walked all the way up, not one step: an agent's `Bash` is a
    /// shell under a shell under the tool runner.
    func testTheChainIsWalkedToTheTop() {
        let attribution = SessionProcesses.attribute(facts([(pid: 100, ppid: 1, marker: nil),
                                                            (pid: 200, ppid: 100, marker: nil),
                                                            (pid: 300, ppid: 200, marker: nil),
                                                            (pid: 400, ppid: 300, marker: nil)]),
                                                     sessionPIDs: [100])
        XCTAssertEqual(attribution.ownerByPID[400], 100)
        XCTAssertEqual(attribution.ownerByPID.count, 4)
    }

    /// A process below no session at all belongs to nobody, and says so by being
    /// absent rather than by naming somebody.
    func testAProcessUnderNoSessionIsNotAttributed() {
        let attribution = SessionProcesses.attribute(facts([(pid: 500, ppid: 1, marker: nil)]),
                                                     sessionPIDs: [100])
        XCTAssertEqual(attribution.ownerByPID, [:])
    }

    // MARK: - The marker

    /// The whole reason the marker exists: a process whose parent has exited
    /// reparents to pid 1, which names nobody, while `CLAUDE_PID` in its
    /// environment still names the session that started it.
    ///
    /// Verified live on this machine — three spin loops left behind by an
    /// exiting shell reparented to launchd and turned up here as three orphans
    /// of the session that had spawned them (SPEC §2.8).
    func testAnOrphanIsClaimedByItsMarker() {
        let attribution = SessionProcesses.attribute(facts([(pid: 100, ppid: 1, marker: nil),
                                                            (pid: 200, ppid: 1, marker: 100)]),
                                                     sessionPIDs: [100])
        XCTAssertEqual(attribution.ownerByPID, [100: 100, 200: 100])
        XCTAssertEqual(attribution.orphansBySessionPID, [100: 1])
    }

    /// And the rule that keeps the inherited junk out. The marker is passed
    /// sideways — the `claude` binary itself carries the marker of whatever
    /// launched VSCode — so 120 of the 136 markers on this machine name a
    /// session that is not live, against 24 that are (26.08.2026). Most of what
    /// this signal says is junk, and the count that comes off it would be junk
    /// too. A marker is worth something only when the pid it names is
    /// a live session, and the two halves of that are checked apart:
    ///
    /// - `900` is not in the process table at all: the session is gone;
    /// - `800` is a perfectly live process that is simply not a session.
    ///
    /// The second is what stops "the marker names something that exists" from
    /// passing for the rule. Both processes stay unattributed, and neither adds
    /// an orphan to anybody.
    func testAMarkerThatDoesNotNameALiveSessionIsIgnored() {
        let attribution = SessionProcesses.attribute(facts([(pid: 100, ppid: 1, marker: nil),
                                                            (pid: 800, ppid: 1, marker: nil),
                                                            (pid: 200, ppid: 1, marker: 900),
                                                            (pid: 300, ppid: 1, marker: 800)]),
                                                     sessionPIDs: [100])
        XCTAssertNil(attribution.ownerByPID[200])
        XCTAssertNil(attribution.ownerByPID[300])
        XCTAssertEqual(attribution.orphansBySessionPID, [:])
    }

    /// When both signals speak and disagree, the chain wins and the marker is
    /// not even consulted: a descendant of session A carrying a marker naming
    /// session B is a process A spawned out of an environment B had already
    /// polluted.
    ///
    /// Zero such cases on live data (measured over 740 processes and 25
    /// sessions), which is exactly why the rule is written down and asked here:
    /// otherwise it is whatever order the code happens to check in.
    func testTheChainWinsOverAMarkerNamingAnotherLiveSession() {
        let attribution = SessionProcesses.attribute(facts([(pid: 100, ppid: 1, marker: nil),
                                                            (pid: 300, ppid: 1, marker: nil),
                                                            (pid: 200, ppid: 100, marker: 300)]),
                                                     sessionPIDs: [100, 300])
        XCTAssertEqual(attribution.ownerByPID[200], 100)
        // And it is not an orphan of anybody: nothing was lost, so nothing was
        // recovered.
        XCTAssertEqual(attribution.orphansBySessionPID, [:])
    }

    /// The marker is refused to everything hanging under the tree the sessions
    /// themselves hang under, however live the session it names (SPEC §2.8).
    ///
    /// The shape is the editor's, and it is ordinary rather than exotic: VSCode
    /// (`10`) was started with `code .` from a session that is still running, so
    /// every process it runs — the plugin host `20`, a language server `40`, a
    /// second `claude` typed into a neighbouring terminal — carries that
    /// session's `CLAUDE_PID`. None of them lost a parent. Counting them as
    /// orphans would put the whole editor's CPU on one row.
    ///
    /// On this machine the tree currently holds **80** processes the chain does
    /// not place, and it works today only because the marker they carry names a
    /// session that is dead — the accident this rule replaces.
    func testTheEditorsOwnTreeIsNotAnOrphanOfTheSessionThatLaunchedIt() {
        let attribution = SessionProcesses.attribute(facts([(pid: 10, ppid: 1, marker: 100),
                                                            (pid: 20, ppid: 10, marker: 100),
                                                            (pid: 30, ppid: 20, marker: nil),
                                                            (pid: 40, ppid: 20, marker: 100),
                                                            (pid: 100, ppid: 30, marker: 100)]),
                                                     sessionPIDs: [100])
        // The session itself, and nothing above or beside it.
        XCTAssertEqual(attribution.ownerByPID, [100: 100])
        XCTAssertEqual(attribution.orphansBySessionPID, [:])
    }

    /// And the rule must not cost a real orphan, which is the half that makes it
    /// worth having. Verified on live data as well — 6 marker claims on this
    /// machine, 6 kept, 0 refused — and asked here in both the shapes that
    /// occurred there.
    ///
    /// `200` is the plain case: its parent exited and launchd adopted it.
    /// `300` is the one a rule about ancestors could plausibly get wrong — it
    /// still has its parent, and its parent is `200`. Five of the six live
    /// claims were of that kind: a detached `python` with `docker` and two
    /// `ssh` underneath it. Nothing in that chain is above a session, so
    /// nothing in it is refused.
    func testAnOrphanAndEverythingUnderItStillCount() {
        let attribution = SessionProcesses.attribute(facts([(pid: 10, ppid: 1, marker: nil),
                                                            (pid: 100, ppid: 10, marker: nil),
                                                            (pid: 200, ppid: 1, marker: 100),
                                                            (pid: 300, ppid: 200, marker: 100)]),
                                                     sessionPIDs: [100])
        XCTAssertEqual(attribution.ownerByPID[200], 100)
        XCTAssertEqual(attribution.ownerByPID[300], 100)
        XCTAssertEqual(attribution.orphansBySessionPID, [100: 2])
    }

    /// A chain the sweep cannot follow to the end proves nothing, and must not
    /// be read as "detached" (SPEC §2.8).
    ///
    /// The hole is ordinary, not exotic. `proc_pid_rusage` refuses another
    /// user's process, so that row is dropped — and the row it drops has
    /// children of ours: `/usr/bin/login` is root-owned and refuses both calls
    /// while the login shell under it answers both, which is the shape of every
    /// Terminal.app tab. Of 266 foreign-parent/our-child pairs on this machine
    /// 265 are launchd, already excluded by the walk stopping above pid 1, and
    /// one is `login`.
    ///
    /// So `200` here is a process in a second terminal tab carrying a marker
    /// inherited sideways from the live session `100`. Its parent `20` is alive
    /// and well; the walk merely runs out of links at `6`, the `login` that was
    /// dropped. Reading that as "nothing above it" manufactures an orphan under
    /// a living parent — the flickering counter, arriving by another door.
    ///
    /// `300` is the control half, and it is what stops the fix from being "deny
    /// every marker": a real orphan reaches pid 1 and is claimed as before. A
    /// test without it stays green when the walk is made to return `broken` for
    /// everything.
    func testAChainTheSweepCannotFollowDoesNotManufactureAnOrphan() {
        let attribution = SessionProcesses.attribute(facts([(pid: 100, ppid: 10, marker: nil),
                                                            (pid: 10, ppid: 5, marker: nil),
                                                            (pid: 200, ppid: 20, marker: 100),
                                                            (pid: 20, ppid: 6, marker: 100),
                                                            (pid: 300, ppid: 1, marker: 100)]),
                                                     sessionPIDs: [100])
        XCTAssertNil(attribution.ownerByPID[200])
        XCTAssertNil(attribution.ownerByPID[20])
        XCTAssertEqual(attribution.ownerByPID[300], 100)
        XCTAssertEqual(attribution.orphansBySessionPID, [100: 1])
    }

    /// The three answers the walk has, asked one at a time, because `attribute`
    /// can only show two of them apart at a time.
    func testTheChainWalkTellsRunningOutOfLinksApartFromReachingTheTop() {
        let parents: [Int32: Int32] = [7: 6, 6: 5, 4: 3, 3: 1, 9: 9]
        XCTAssertEqual(SessionProcesses.walkUp(from: 7, parents: parents, to: [6]), .found(6))
        XCTAssertEqual(SessionProcesses.walkUp(from: 7, parents: parents, to: [7]), .found(7))
        // `5` has no line of its own: the walk has nowhere left to go.
        XCTAssertEqual(SessionProcesses.walkUp(from: 7, parents: parents, to: [42]), .broken)
        XCTAssertEqual(SessionProcesses.walkUp(from: 4, parents: parents, to: [42]), .reachedTop)
        // A ring is a chain that leads nowhere, which is `broken`, not the top.
        XCTAssertEqual(SessionProcesses.walkUp(from: 9, parents: parents, to: [42]), .broken)
    }

    /// launchd is above everything, so it must not be on the list: with pid 1 in
    /// it the rule would refuse every marker on the machine and quietly report
    /// no orphans ever.
    func testTheAncestorListStopsBelowLaunchd() {
        let ancestors = SessionProcesses.sessionAncestors(of: [100], parents: [100: 10, 10: 1])
        XCTAssertEqual(ancestors, [10])
    }

    /// The parent table is read one process at a time while the machine goes on
    /// forking, so a snapshot of it is not guaranteed to be a tree. A cycle in
    /// it must end the walk rather than spin inside a function that runs once or
    /// twice a second.
    ///
    /// Run with a timeout and off this thread, because the regression this
    /// guards against is a test run that never finishes rather than one that
    /// fails. Removing the visited set hangs here instead of going red, and the
    /// timeout is what turns that back into a failure.
    func testACycleInTheParentGraphEndsTheWalk() {
        let done = expectation(description: "attribution returned")
        let input = facts([(pid: 100, ppid: 1, marker: nil),
                           (pid: 200, ppid: 300, marker: nil),
                           (pid: 300, ppid: 400, marker: nil),
                           (pid: 400, ppid: 200, marker: nil)])
        DispatchQueue.global().async {
            let attribution = SessionProcesses.attribute(input, sessionPIDs: [100])
            // The ring reaches no session, so none of the three is claimed.
            XCTAssertEqual(attribution.ownerByPID, [100: 100])
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    // MARK: - Rates

    /// A whole core busy for the whole interval is 100%, and four threads on
    /// four cores are 400 — the convention `top` prints, and the reason the
    /// figure is not clamped.
    func testARateIsAPercentageOfOneCore() throws {
        let rates = try XCTUnwrap(percents(previous: [key(1, 10): counters(0),
                                                                    key(2, 10): counters(0)],
                                           current: [key(1, 10): counters(2_000_000_000),
                                                                   key(2, 10): counters(8_000_000_000)],
                                           elapsed: 2))
        XCTAssertEqual(try XCTUnwrap(rates[key(1, 10)]), 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(rates[key(2, 10)]), 400, accuracy: 0.001)
    }

    /// The first pass after launch has one sweep and no predecessor to subtract,
    /// and answers "not measured" rather than "idle". Zero is below the floor
    /// as well as being the division guard, and either way there is nothing to
    /// report.
    func testTheFirstSweepHasNoRateToReport() {
        XCTAssertNil(percents(previous: [:],
                              current: [key(1, 10): counters(500)],
                              elapsed: 0))
    }

    /// A gap too *short* is refused as well, and that is the end of the scale
    /// the panel actually lives at: three paths reach `refresh()` without the
    /// timer — the panel sliding out refreshes immediately, `apply` refreshes
    /// again when one was requested mid-build, and the watcher debounces at
    /// 0.15 s while the state hook renames files on every transition.
    ///
    /// Asked in seconds rather than through the constant, for the reason the
    /// ceiling is: through `minimumSampleSeconds` the test says only that the
    /// guard compares against whatever it compares against.
    ///
    /// The numbers are the promise the constant makes. It has to sit above the
    /// watcher's 0.15 s and below `SnapshotStore.activeInterval` — the fastest
    /// tick the panel has — because a floor *on* the tick is rejected by a few
    /// milliseconds of jitter every other time.
    func testAGapTooShortToDivideIsNotReported() {
        let previous = [key(1, 10): counters(0)]
        let current = [key(1, 10): counters(1_000_000_000)]
        func rate(after elapsed: TimeInterval) -> [SessionProcesses.Key: Double]? {
            percents(previous: previous, current: current, elapsed: elapsed)
        }
        XCTAssertNil(rate(after: 0.05))
        XCTAssertNil(rate(after: 0.15))
        XCTAssertNil(rate(after: 0.499))
        XCTAssertNotNil(rate(after: 0.5))
        XCTAssertNotNil(rate(after: 1))
    }

    /// A gap too long to call "now" is thrown away rather than reported. What
    /// comes out of such a pair is a mean over the gap, and the row promises the
    /// opposite.
    ///
    /// Both sides of the threshold, and in seconds rather than through the
    /// constant: asked through `staleSampleSeconds` itself the test says only
    /// "the guard compares against whatever it compares against", and stays
    /// green for 3 s and for 600 s alike.
    ///
    /// The numbers here are the promises the constant makes. An ordinary slow
    /// pass — the slowest tick is `SnapshotStore.idleInterval` = 2 s and a slow
    /// assembly adds up to 0.18 s of disk to it (§6) — must never blank the
    /// column. Ten of those ticks is the last gap that still counts as "now".
    /// And a minute is a mean over a minute whatever the constant says.
    func testAGapTooLongToCallNowIsNotReported() {
        let previous = [key(1, 10): counters(0)]
        let current = [key(1, 10): counters(1_000_000_000)]
        func rate(after elapsed: TimeInterval) -> [SessionProcesses.Key: Double]? {
            percents(previous: previous, current: current, elapsed: elapsed)
        }
        XCTAssertNotNil(rate(after: 2.2))
        XCTAssertNotNil(rate(after: 20))
        XCTAssertNil(rate(after: 20.001))
        XCTAssertNil(rate(after: 60))
    }

    /// A pid that came back is a different process with a counter of its own.
    /// Keyed on the number alone, the new process's small total minus the old
    /// one's large one is a wrong answer — negative, or a wrong zero once
    /// clamped. Keyed on the pair, there is simply no rate for it this pass,
    /// which is the same answer a process that has only just appeared gets.
    ///
    /// The environment cache in `ProcessSampler` is keyed by the same pair and
    /// for the same reason: a marker read from the process that used to have
    /// this pid would name the wrong session for as long as the new one lives.
    ///
    /// The fixture is the way round that the mistake actually shows, and the
    /// margin has to be wide enough to see. The pid's previous owner had burned
    /// 0.4 s; the process holding it now has burned 0.5 s, all of it inside this
    /// gap because it did not exist at the previous sweep. Keyed on the pair
    /// that is 50%. Keyed on the pid alone the new process is mistaken for a
    /// survivor and the dead one's total is subtracted from it: 10%.
    ///
    /// Two totals a hundredth apart would not tell those answers apart at all —
    /// which is what the fixture was before short-lived processes started
    /// counting for their whole total, and it would have gone quietly green.
    /// The other way round — an old total larger than the new one — the
    /// backwards-counter guard below catches by accident, and a fixture it
    /// catches proves nothing about *this* rule.
    ///
    /// `ppid: 1` on the dead process on purpose: launchd is not in the table, so
    /// it leaves no heir and its 0.4 s is charged to nobody. That rule has its
    /// own test; this one is about the key.
    func testAReusedPidGetsNoRateFromTheProcessThatHadItBefore() throws {
        let rates = try XCTUnwrap(percents(previous: [key(7, 100): counters(400_000_000)],
                                           current: [key(7, 200): counters(500_000_000)],
                                           elapsed: 1))
        XCTAssertEqual(try XCTUnwrap(rates[key(7, 200)]), 50, accuracy: 0.001)
        XCTAssertEqual(rates.count, 1)
    }

    /// The counters are cumulative and never fall. One that did is a reading
    /// from something else, and is dropped rather than clamped.
    func testACounterThatWentBackwardsIsDropped() throws {
        let rates = try XCTUnwrap(percents(previous: [key(1, 10): counters(5_000_000_000)],
                                           current: [key(1, 10): counters(1_000_000_000)],
                                           elapsed: 1))
        XCTAssertEqual(rates, [:])
    }

    // MARK: - Rates: the processes that do not survive a sweep

    /// The work an agent does is mostly done by processes that never live long
    /// enough to be seen twice: every `Bash` call is a fresh `rg`, `git`, `cc`
    /// or `node` living a fraction of a second. Asked only about the processes
    /// present in both sweeps, the rate misses all of it — measured 26.08.2026,
    /// a shell spawning and reaping a child every 0.15 s reported 0.3% against
    /// 63.6–86.9% of a core actually burned, and 0.3% is under the 1% the row
    /// prints anything above at all.
    ///
    /// The shell survives both sweeps and its `ri_child_*` is where the reaped
    /// children landed, so the figure is its own delta plus that one. Here the
    /// shell burned 0.1 s of its own and reaped 0.6 s of children: 70%.
    func testCPUBurnedByChildrenReapedBetweenSweepsIsCounted() throws {
        let rates = try XCTUnwrap(
            percents(previous: [key(50, 1): counters(0, child: 0)],
                     current: [key(50, 1): counters(100_000_000, child: 600_000_000)],
                     elapsed: 1))
        XCTAssertEqual(try XCTUnwrap(rates[key(50, 1)]), 70, accuracy: 0.001)
    }

    /// A process born since the previous sweep and still alive is the other half
    /// of the same hole, and the smaller one. Its counter starts at zero at
    /// birth, so all of it belongs to this gap and none of it has been reported
    /// before.
    func testAProcessBornSinceTheLastSweepCountsForItsWholeCounter() throws {
        let rates = try XCTUnwrap(percents(previous: [:],
                                           current: [key(60, 1): counters(250_000_000)],
                                           elapsed: 1))
        XCTAssertEqual(try XCTUnwrap(rates[key(60, 1)]), 25, accuracy: 0.001)
    }

    /// And this is why adding `ri_child_*` naively would be worse than the bug
    /// it fixes. At the moment a child is reaped the parent's counter gains the
    /// child's **entire lifetime**, the part earlier passes already reported
    /// included. A `swift build` that ran ten minutes and then exited would put
    /// 600 s of CPU inside one 1 s tick — some 60000%, on a row whose figure is
    /// read as "what is this window doing to my machine right now".
    ///
    /// Here the child was last seen holding 600 s and burned 0.2 s more before
    /// exiting; the parent burned 0.1 s of its own. The answer is 0.3 s over
    /// 1 s — 30%, not 60030%.
    func testReapingALongLivedChildDoesNotSpike() throws {
        let previous = [key(50, 1): counters(1_000_000_000, child: 0),
                        key(51, 1): counters(600_000_000_000, ppid: 50)]
        let current = [key(50, 1): counters(1_100_000_000, child: 600_200_000_000)]
        let rates = try XCTUnwrap(percents(previous: previous,
                                           current: current,
                                           elapsed: 1))
        XCTAssertEqual(try XCTUnwrap(rates[key(50, 1)]), 30, accuracy: 0.001)
    }

    /// `ri_child_*` folds in the **whole subtree** of a reaped child, not the
    /// child's own time alone — measured 26.08.2026 rather than read out of the
    /// header, a grandchild burning 1.0 s under a child burning 0.3 s landed
    /// 1.24 s in the grandparent at the moment the child was reaped. So what is
    /// subtracted for a vanished process is its last-seen *total*, own and child
    /// both.
    ///
    /// Here the middle process was last seen with 1 s of its own and 9 s of
    /// reaped grandchildren, and went in this gap having burned nothing more.
    /// Subtracting its own 1 s alone leaves 9.5 s of already-reported time
    /// inside one tick — 950%. Subtracting the total leaves 0.5 s of the top
    /// process's own work: 50%.
    func testWhatIsSubtractedForAVanishedProcessIncludesWhatItHadReaped() throws {
        let previous = [key(50, 1): counters(0, child: 0),
                        key(51, 1): counters(1_000_000_000, child: 9_000_000_000, ppid: 50)]
        let current = [key(50, 1): counters(500_000_000, child: 10_000_000_000)]
        let rates = try XCTUnwrap(percents(previous: previous,
                                           current: current,
                                           elapsed: 1))
        XCTAssertEqual(try XCTUnwrap(rates[key(50, 1)]), 50, accuracy: 0.001)
    }

    /// When a process and its parent go in the same gap, both totals travel up
    /// to the first ancestor still standing, so both have to be subtracted off
    /// there. Charging the subtraction to the immediate parent instead loses the
    /// deeper one — and `sh -c 'cc …'`, where the compiler and the shell that
    /// ran it both exit inside one tick, is the ordinary shape of it, not a
    /// contrived one.
    ///
    /// `50` survives. `51` (its child) and `52` (its grandchild) both vanish,
    /// last seen holding 2 s and 3 s. `50` gained all 5 s plus 0.4 s of new
    /// work: the answer is 40%, and charging only `51` would leave 3 s of
    /// already-reported time in the tick — 340%.
    func testAChainThatVanishedTogetherIsSubtractedAtTheSurvivor() throws {
        let previous = [key(50, 1): counters(0, child: 0),
                        key(51, 1): counters(2_000_000_000, ppid: 50),
                        key(52, 1): counters(3_000_000_000, ppid: 51)]
        let current = [key(50, 1): counters(400_000_000, child: 5_000_000_000)]
        let rates = try XCTUnwrap(percents(previous: previous,
                                           current: current,
                                           elapsed: 1))
        XCTAssertEqual(try XCTUnwrap(rates[key(50, 1)]), 40, accuracy: 0.001)
    }

    /// A process that was there for both sweeps and burned nothing reports `0`,
    /// not an absence. "Measured, and idle" and "not measured yet" are different
    /// answers, the row draws them differently and `--dump --json` keeps them
    /// apart (§3.1), and the difference is made right here: a session whose
    /// every process falls out of this map has no figure at all.
    ///
    /// It fell out once. Summing signed nanoseconds and then keeping only what
    /// came out above zero reads as tidying away the negatives and quietly takes
    /// the zeros with it — every quiet session on the machine turned `nil`, and
    /// the whole suite stayed green. A live probe caught it, so the case is
    /// written down.
    func testAProcessThatBurnedNothingReportsZeroRatherThanNothing() throws {
        let rates = try XCTUnwrap(percents(previous: [key(80, 1): counters(7_000_000_000)],
                                           current: [key(80, 1): counters(7_000_000_000)],
                                           elapsed: 1))
        XCTAssertEqual(try XCTUnwrap(rates[key(80, 1)]), 0)
    }

    // MARK: - Rates: the ledger

    /// **A process that leaves the table has not necessarily handed its counter
    /// over yet, so what it is owed is written down rather than deducted.**
    ///
    /// This fixture used to be `testAnOverSubtractedProcessIsFlooredAtZeroAndNotDropped`
    /// and asserted `0` — it pinned the defect as the expected answer. Two live
    /// shapes produce it and neither is exotic (SPEC §2.8): a **zombie**, which
    /// keeps answering `proc_pid_rusage` while `PROC_PIDTBSDINFO` refuses it, so
    /// the sweep drops the row a tick or more before the parent's `wait` lands;
    /// and a descendant **reparented to launchd**, whose counter never arrives
    /// anywhere at all. Deducted on disappearance, both take 9 s of
    /// already-reported time off a process that has gained none of it, and the
    /// row of a session burning a core reads as empty space.
    ///
    /// `80` burned 0.2 s of its own in this gap and gained nothing from `81`.
    /// The answer is its own work — 20%, not 0 — and the 9 s goes on the ledger
    /// to wait for growth that may or may not come.
    func testAVanishedProcessIsWrittenDownAgainstItsHeirRatherThanDeducted() throws {
        let previous = [key(80, 1): counters(0), key(81, 1): counters(9_000_000_000, ppid: 80)]
        // `81` is gone and `80` has gained nothing: no `wait` yet, or launchd
        // took it. From here the two are the same picture.
        let current = [key(80, 1): counters(200_000_000)]
        let measured = try XCTUnwrap(SessionProcesses.rates(previous: previous,
                                                            current: current,
                                                            elapsed: 1,
                                                            debts: [:]))
        XCTAssertEqual(try XCTUnwrap(measured.percentByKey[key(80, 1)]), 20, accuracy: 0.001)
        // Keyed by the debtor, charged to the parent it was last seen under.
        XCTAssertEqual(measured.debts[key(81, 1)]?.nanos, 9_000_000_000)
        XCTAssertEqual(measured.debts[key(81, 1)]?.heir, key(80, 1))
        XCTAssertEqual(measured.expired, 0)
    }

    /// And the pass where the reap really lands settles it, so the 9 s is
    /// reported exactly once — never, and then not twice.
    ///
    /// The gap between a child's exit and its parent's `wait` is what this
    /// bridges: short for a shell blocked in `wait4`, longer for anything
    /// reaping on its own loop. Here `80` finally reaps, its `ri_child_*`
    /// jumping by the child's whole lifetime — the 9 s already reported plus the
    /// 0.4 s the child burned after it was last seen — and `80` burned 0.1 s of
    /// its own. The answer is 0.5 s over 1 s, and the ledger comes back empty.
    ///
    /// Without the settlement this tick reports 950%; with the old deduct-on-
    /// disappearance rule it reported 940% here and 0 on the pass before.
    func testADebtIsSettledByTheGrowthOfTheLaterPassWhereTheReapLands() throws {
        let previous = [key(80, 1): counters(200_000_000)]
        let current = [key(80, 1): counters(300_000_000, child: 9_400_000_000)]
        let measured = try XCTUnwrap(SessionProcesses.rates(previous: previous,
                                                            current: current,
                                                            elapsed: 1,
                                                            debts: [key(81, 1): debt(9_000_000_000,
                                                                                     to: key(80, 1))]))
        XCTAssertEqual(try XCTUnwrap(measured.percentByKey[key(80, 1)]), 50, accuracy: 0.001)
        XCTAssertNil(measured.debts[key(81, 1)], "a settled debt is not kept around")
        XCTAssertEqual(measured.expired, 0)
    }

    /// The other shape, and the one the walk cannot tell from the first: the
    /// parent died before its child, so the child was handed to launchd and
    /// reaped there. Its counter left the tree and no survivor ever gains a
    /// nanosecond of it — measured 26.08.2026 on a live fixture, a grandparent
    /// whose grandchild burned 1.0 s saw its `ri_child_*` move by the middle
    /// process's own 6229 mach units and nothing more.
    ///
    /// `inheritor` still finds the grandparent, because from the table this is
    /// indistinguishable from "the chain died bottom-up and the grandparent
    /// holds it all". What tells them apart is that the growth never arrives:
    /// `min(debt, childDelta)` settles nothing, and the grandparent's tick keeps
    /// its own 1.0 s. Deducted outright, the same tick reported 0 — the busy
    /// session drawn as an idle one.
    func testAGrandchildReapedByLaunchdTakesNothingOffTheSurvivor() throws {
        let previous = [key(90, 1): counters(0),
                        key(91, 1): counters(50_000_000, ppid: 90),
                        key(92, 1): counters(24_000_000_000, ppid: 91)]
        // The middle and the grandchild both went in this gap, and `90` gained
        // nothing at all: launchd reaped what was left.
        let current = [key(90, 1): counters(1_000_000_000)]
        let measured = try XCTUnwrap(SessionProcesses.rates(previous: previous,
                                                            current: current,
                                                            elapsed: 1,
                                                            debts: [:]))
        XCTAssertEqual(try XCTUnwrap(measured.percentByKey[key(90, 1)]), 100, accuracy: 0.001)
        // Two debtors, one heir, and each written down for its own total: the
        // grandchild's 24 s travels up inside the middle process's, because from
        // the table the middle process may well have reaped it on the way out.
        XCTAssertEqual(measured.debts[key(91, 1)]?.nanos, 50_000_000)
        XCTAssertEqual(measured.debts[key(92, 1)]?.nanos, 24_000_000_000)
        XCTAssertEqual(measured.debts[key(91, 1)]?.heir, key(90, 1))
        XCTAssertEqual(measured.debts[key(92, 1)]?.heir, key(90, 1))
    }

    /// **Finding 1 of the fourth review: growth is only ever spent on a debt it
    /// could have carried.**
    ///
    /// `70` is busy and it reaps: `71` is an ordinary short-lived child, and its
    /// whole life lands in `70`'s `ri_child_*` in this gap. `72` disappears in
    /// the same gap, but the sweep last saw it under **pid 1** — its own parent
    /// had gone in some earlier gap, launchd holds it, and its 4 s will never
    /// arrive anywhere at all.
    ///
    /// So `72` is written down nowhere. Charged to the first surviving ancestor
    /// instead, its 4 s would be taken off the growth that came from `71`, and
    /// the tick of a process burning a core would read as nearly idle: 10%
    /// against the true 110%. This is the whole reason a debt is addressed to
    /// the debtor's **last-seen parent** — reparenting is visible in `ppid`, and
    /// a walk that ignores it cannot see the counter leaving the tree.
    ///
    /// `70` burned 0.1 s of its own and gained 1.1 s from `71`, 0.1 s of which
    /// had already been reported: 1.1 s over 1 s.
    func testGrowthIsNeverSpentOnADebtItCouldNotHaveCarried() throws {
        let previous = [key(70, 1): counters(0, child: 0),
                        key(71, 1): counters(100_000_000, ppid: 70),
                        key(72, 1): counters(4_000_000_000, ppid: 1)]
        let current = [key(70, 1): counters(100_000_000, child: 1_100_000_000)]
        let measured = try XCTUnwrap(SessionProcesses.rates(previous: previous,
                                                            current: current,
                                                            elapsed: 1,
                                                            debts: [:]))
        // `71`'s own 0.1 s is written down and settled by the growth that
        // carried it, on this one pass. `72` is not written down at all — and
        // it could not have been settled even if it had been, because 4 s does
        // not fit inside 1.1 s of growth, so an empty ledger is the assertion.
        //
        // What this fixture can and cannot fail on is worth being straight
        // about. The 110% catches settlement gone wrong in either direction
        // (none of it, or too much). The launchd half it cannot fail on by
        // itself: pid 1 is not in this table, so the walk stops for want of a
        // row whether or not the rule is there — that half is
        // `testACounterHandedToLaunchdIsNotChargedToLaunchd`, and the "growth
        // belongs to its own debt" half is
        // `testOneSurvivorsGrowthDoesNotSettleAnothersDebt`.
        XCTAssertNil(measured.debts[key(72, 1)],
                     "a counter launchd already held was written down against a survivor")
        XCTAssertTrue(measured.debts.isEmpty)
        XCTAssertEqual(try XCTUnwrap(measured.percentByKey[key(70, 1)]), 110, accuracy: 0.001)
    }

    /// The other half of that finding: **a debt is spent only against the growth
    /// of the process it is addressed to**, and the fixture is built so that the
    /// growth in it is somebody else's.
    ///
    /// `70` is holding a zombie child, `71`, whose 2 s have already been
    /// reported and whose reap has not happened yet — nothing has arrived at
    /// `70` at all. `75` is an unrelated process on the same machine that reaped
    /// 5 s of children of its own in this gap, which on an agent's machine is
    /// the ordinary state of `claude`: it reaps the next `Bash` on nearly every
    /// tick.
    ///
    /// A ledger that pools what is owed and pays it out of whatever growth turns
    /// up settles `71`'s debt from `75`'s reap: `75` reports 300% instead of
    /// 500%, `70` is left owing nothing, and when the reap finally lands there
    /// is nothing to take the reported part off — the spike back, one pass
    /// later. Per debtor and per heir, `75`'s growth is not eligible for it.
    func testOneSurvivorsGrowthDoesNotSettleAnothersDebt() throws {
        let previous = [key(70, 1): counters(0, child: 0),
                        key(75, 1): counters(0, child: 0),
                        key(71, 1): counters(2_000_000_000, ppid: 70)]
        let current = [key(70, 1): counters(0, child: 0),
                       key(75, 1): counters(0, child: 5_000_000_000)]
        let measured = try XCTUnwrap(SessionProcesses.rates(previous: previous,
                                                            current: current,
                                                            elapsed: 1,
                                                            debts: [:]))
        XCTAssertEqual(try XCTUnwrap(measured.percentByKey[key(75, 1)]), 500, accuracy: 0.001,
                       "an unrelated process paid somebody else's debt")
        XCTAssertEqual(try XCTUnwrap(measured.percentByKey[key(70, 1)]), 0, accuracy: 0.001)
        // And the debt is still standing, addressed where it was written.
        XCTAssertEqual(measured.debts[key(71, 1)]?.nanos, 2_000_000_000)
        XCTAssertEqual(measured.debts[key(71, 1)]?.heir, key(70, 1))
    }

    /// And the stop at launchd is a rule of its own, not a by-product of who
    /// answers the kernel.
    ///
    /// On this machine pid 1 never reaches the sweep at all — measured
    /// 27.08.2026, it answers neither `proc_pid_rusage` nor `PROC_PIDTBSDINFO`,
    /// while 318 of the 974 pids listed sit directly under it — so the walk in
    /// `heir(of:)` stops there anyway, for want of a row to climb to, and taking
    /// the `ppid > 1` test out failed **no** test in the suite. That is the
    /// accident, not the rule: launchd is unreadable because the app runs as the
    /// user, and the day it were readable every debt on the machine would be
    /// addressed to the one process that reaps every orphan there is, so
    /// unrelated growth would settle all of them within a tick.
    ///
    /// The fixture therefore puts launchd in the table and gives it what it
    /// really has — growth from reaping somebody else — and asks that the 4 s
    /// last seen under it change nothing: 10 s of growth over 1 s is 1000%,
    /// which is what a machine full of exiting orphans looks like. Charged to
    /// launchd, the debt would take 4 s off and report 600%.
    func testACounterHandedToLaunchdIsNotChargedToLaunchd() throws {
        let previous = [key(1, 1): counters(0, child: 0, ppid: 0),
                        key(72, 1): counters(4_000_000_000, ppid: 1)]
        let current = [key(1, 1): counters(0, child: 10_000_000_000, ppid: 0)]
        let measured = try XCTUnwrap(SessionProcesses.rates(previous: previous,
                                                            current: current,
                                                            elapsed: 1,
                                                            debts: [:]))
        XCTAssertEqual(try XCTUnwrap(measured.percentByKey[key(1, 1)]), 1000, accuracy: 0.001)
        XCTAssertTrue(measured.debts.isEmpty)
    }

    /// **Finding 2 of the fourth review: an unsettled debt travels with the
    /// counters it was written against, instead of being forgiven.**
    ///
    /// `61` was holding a debt for a zombie child of its own — 100 s already
    /// reported, nothing settled, because `61` had not called `wait` yet. In
    /// this gap it finally reaps, and then exits; `60` reaps `61`. Everything
    /// `61` ever accounted for lands in `60`'s `ri_child_*` at that moment, the
    /// zombie's 100 s included, because a reaped process hands over its whole
    /// subtree (`Counters.child`).
    ///
    /// Given up on at the moment its debtor left the table — which is what the
    /// ledger did until this review — those 100 s have nothing left to take them
    /// off, and `60`'s one-second tick reports them in full: 10000%, bounded
    /// only by how long the zombie lived. Carried up with `61`'s own total
    /// instead, they are deducted exactly once and the tick keeps the 0.3 s of
    /// work that is genuinely new.
    ///
    /// Asked twice, because the two halves of it show in different places. When
    /// the reap lands in the same gap the ledger comes out empty either way and
    /// only the *figure* tells the two apart; when `61` is still a zombie
    /// nothing has arrived at `60` yet, and the debt's new address is on the
    /// ledger to be read.
    func testAnUnsettledDebtTravelsUpWithTheCountersItWasWrittenAgainst() throws {
        let previous = [key(60, 1): counters(0, child: 0),
                        key(61, 1): counters(200_000_000, ppid: 60)]
        let ledger = [key(62, 1): debt(100_000_000_000, to: key(61, 1))]

        let arrived = try XCTUnwrap(
            SessionProcesses.rates(previous: previous,
                                   current: [key(60, 1): counters(0, child: 100_500_000_000)],
                                   elapsed: 1, debts: ledger))
        XCTAssertEqual(arrived.expired, 0, "the debt was given up on when its heir left the table")
        XCTAssertEqual(try XCTUnwrap(arrived.percentByKey[key(60, 1)]), 30, accuracy: 0.001)

        // `61` exited and `60` has not called `wait`: nothing has travelled yet,
        // so both debts sit at `60` waiting for the pass where it does.
        let pending = try XCTUnwrap(
            SessionProcesses.rates(previous: previous,
                                   current: [key(60, 1): counters(0, child: 0)],
                                   elapsed: 1, debts: ledger))
        XCTAssertEqual(pending.debts[key(62, 1)]?.heir, key(60, 1),
                       "the debt was dropped when the process it was charged to left")
        XCTAssertEqual(pending.debts[key(62, 1)]?.age, 1, "and it kept ageing while it travelled")
        XCTAssertEqual(pending.debts[key(61, 1)]?.nanos, 200_000_000)
        XCTAssertEqual(pending.expired, 0)
    }

    /// **What keeps the figure off the floor is that settlement is bounded by
    /// the growth, not by the debt** — and the arithmetic is unsigned, so this
    /// is the invariant that keeps the whole function from trapping rather than
    /// a matter of taste. There is no clamp at the end to catch a negative,
    /// because with the ledger nothing can produce one: each counter is guarded
    /// forward, and `settled ≤ childDelta` leaves `own + (child - settled) ≥ 0`.
    ///
    /// The mutation that proves it is `settled = min(debt, child)` → `settled =
    /// debt`: on this fixture the debt is 9 s against 0.4 s of growth, so the
    /// subtraction underflows. **It surfaces as a crashed test run rather than a
    /// clean failure** — a `UInt64` underflow traps — so a suite that aborts
    /// here is this guard firing, not the suite breaking.
    ///
    /// The answer is the whole of the growth eaten by the debt and the process's
    /// own 0.1 s left standing: 10%. And 8.6 s of the debt is still owed.
    func testSettlementCannotOutrunTheGrowthItSettles() throws {
        let previous = [key(80, 1): counters(0)]
        let current = [key(80, 1): counters(100_000_000, child: 400_000_000)]
        let measured = try XCTUnwrap(SessionProcesses.rates(previous: previous,
                                                            current: current,
                                                            elapsed: 1,
                                                            debts: [key(81, 1): debt(9_000_000_000,
                                                                                     to: key(80, 1))]))
        XCTAssertEqual(try XCTUnwrap(measured.percentByKey[key(80, 1)]), 10, accuracy: 0.001)
        XCTAssertEqual(measured.debts[key(81, 1)]?.nanos, 8_600_000_000)
    }

    /// And no debt can be settled beyond **its own** amount, which is what
    /// keeps one debtor's reap from working off another's already-reported
    /// time. Two debts stand against `80`, 0.2 s and 5 s, and 1 s of growth
    /// arrives: it clears the first whole and takes 0.8 s off the second, so
    /// 4.2 s is still owed and the tick reports the 0.1 s `80` burned itself.
    ///
    /// Settled as one pooled amount the totals come out the same, which is why
    /// this is asked of the **records**: the ledger has to still know which
    /// debtor owes what, or the ages below cannot be per debtor either.
    func testGrowthIsSpreadOverDebtsWithoutOverpayingAnyOfThem() throws {
        let previous = [key(80, 1): counters(0)]
        let current = [key(80, 1): counters(100_000_000, child: 1_000_000_000)]
        let measured = try XCTUnwrap(
            SessionProcesses.rates(previous: previous, current: current, elapsed: 1,
                                   debts: [key(81, 1): debt(200_000_000, to: key(80, 1), age: 5),
                                           key(82, 1): debt(5_000_000_000, to: key(80, 1), age: 2)]))
        XCTAssertNil(measured.debts[key(81, 1)], "the older debt was left standing")
        XCTAssertEqual(measured.debts[key(82, 1)]?.nanos, 4_200_000_000)
        XCTAssertEqual(try XCTUnwrap(measured.percentByKey[key(80, 1)]), 10, accuracy: 0.001)
    }

    /// **Finding 1 of the fifth review: a debt of nothing must not stop the
    /// settlement of the debts behind it.**
    ///
    /// `settle` used to leave the loop on `take == 0`, and `take` is
    /// `min(debt, left)` — zero for two unrelated reasons. The one it meant is
    /// "the growth has run out". The one it did not is "*this* debt is zero",
    /// and a zero debt sorts to the **front** of its heir's bucket: ages tie at
    /// 0 and the tie-break is the lower pid. So the loop stopped on the first
    /// entry and never reached the real one behind it.
    ///
    /// The pid order is the whole fixture. `81` owes nothing, `82` owes one
    /// second, `80` gains exactly that second, and the answer is 0%: the growth
    /// is the reap of already-reported time. Against the old code this pass
    /// reported **100%** — the spike the ledger exists to prevent — left `82`
    /// still owing its second, to eat somebody's growth later or expire and be
    /// charged twice, and did not even clear `81`, the removal sitting behind
    /// the `break`.
    ///
    /// **With the zero debtor at the higher pid the fixture is green against
    /// the bug** (measured: `percent80=0.0`, `owed82=nil` either way), which is
    /// why it is `81` here and not `83`.
    func testAZeroDebtDoesNotStopTheSettlementOfTheDebtsBehindIt() throws {
        let previous = [key(80, 1): counters(0)]
        let current = [key(80, 1): counters(0, child: 1_000_000_000)]
        let measured = try XCTUnwrap(
            SessionProcesses.rates(previous: previous, current: current, elapsed: 1,
                                   debts: [key(81, 1): debt(0, to: key(80, 1)),
                                           key(82, 1): debt(1_000_000_000, to: key(80, 1))]))
        XCTAssertEqual(try XCTUnwrap(measured.percentByKey[key(80, 1)]), 0, accuracy: 0.001,
                       "a zero debt abandoned the real debt behind it")
        XCTAssertNil(measured.debts[key(82, 1)], "the debt behind the zero one was left standing")
        XCTAssertNil(measured.debts[key(81, 1)], "the zero debt was not even cleared")
        XCTAssertEqual(measured.expired, 0)
    }

    /// And the other end of the same finding: a vanishing that owes nothing is
    /// not written down at all.
    ///
    /// `81` was there and is gone, having burned not one nanosecond. An entry
    /// of zero on `80` settles for nothing and clears for nothing, but it is
    /// still an entry: it counts itself among `PassStats.openDebts`, and among
    /// `expiredDebts` if its heir sees no growth for the whole lifetime — the
    /// two figures `debtLifetimeSeconds` argues from. Nothing owed, nothing
    /// recorded.
    func testAVanishingThatOwesNothingIsNotWrittenDown() throws {
        let previous = [key(80, 1): counters(0), key(81, 1): counters(0, ppid: 80)]
        let current = [key(80, 1): counters(0)]
        let measured = try XCTUnwrap(SessionProcesses.rates(previous: previous,
                                                            current: current,
                                                            elapsed: 1,
                                                            debts: [:]))
        XCTAssertTrue(measured.debts.isEmpty, "a debt of nothing went on the ledger")
        XCTAssertEqual(measured.expired, 0)
    }

    /// A debt has to live long enough to meet the only event that can settle it,
    /// and that event is a pass. A pass may legitimately arrive as late as
    /// `staleSampleSeconds` — that is the whole of why the lifetime is that same
    /// gap and not a number of its own.
    ///
    /// So: a debt written down now survives a pass of the longest legal length,
    /// whatever that costs. Halving the lifetime leaves this red.
    ///
    /// Asked in seconds on the far side, for the reason the two sampling guards
    /// are: through the constant it would only say that the comparison compares.
    /// The ledger ages by the gap each pass reports rather than by a clock, so
    /// a burst of passes too short to divide — which compute no rate at all —
    /// does not age it either.
    func testADebtSurvivesTheLongestPassThatCouldSettleIt() throws {
        let previous = [key(80, 1): counters(0)]
        let current = [key(80, 1): counters(0)]
        func ledger(after elapsed: TimeInterval,
                    age: TimeInterval) throws -> [SessionProcesses.Key: SessionProcesses.Debt] {
            try XCTUnwrap(SessionProcesses.rates(previous: previous, current: current,
                                                 elapsed: elapsed,
                                                 debts: [key(81, 1): debt(5_000_000_000,
                                                                          to: key(80, 1),
                                                                          age: age)])).debts
        }
        XCTAssertEqual(try ledger(after: SessionProcesses.staleSampleSeconds, age: 0).count, 1,
                       "a debt has to outlive the longest pass that could settle it")
        // And it does not live for ever: an unsettled debt is indistinguishable
        // from a pending one and spends itself against the next genuine growth,
        // so holding it longer holds that suppression longer. Letting go is not
        // free either — the counter may still be coming, and then the whole
        // forgiven amount lands on one tick — which is why `expired` is counted.
        XCTAssertEqual(try ledger(after: 1, age: 19).count, 1)
        XCTAssertEqual(try ledger(after: 1, age: 19.001).count, 0)
        XCTAssertEqual(try XCTUnwrap(SessionProcesses.rates(previous: previous, current: current,
                                                            elapsed: 1,
                                                            debts: [key(81, 1): debt(5_000_000_000,
                                                                                     to: key(80, 1),
                                                                                     age: 19.001)])).expired,
                       1, "and giving up on one is counted, because nothing else records it")
    }

    /// **Finding 3 of the fourth review: an old debt leaves a ledger that is
    /// being topped up every pass.**
    ///
    /// The ledger used to be one pool per heir carrying one age, re-dated by
    /// every addition — and the process that loses a descendant on nearly every
    /// pass is exactly the one this matters for: `claude` is a node process
    /// spawning the next `Bash`. Its pool would be re-dated for ever, so a debt
    /// nothing can settle would never age out and would go on eating that
    /// session's growth indefinitely.
    ///
    /// Here `80` is that heir. One debt has been waiting almost the whole
    /// lifetime, a second is half its age, and `80` loses a fresh child on this
    /// very pass. The old one has to go while the other two stay, with their own
    /// ages. On a single-entry fixture both "never age an entry" and "re-date it
    /// on every addition" stay green; here the first leaves `81` standing and so
    /// does the second.
    func testAnOldDebtLeavesALedgerThatIsToppedUpEveryPass() throws {
        let previous = [key(80, 1): counters(0),
                        key(83, 1): counters(700_000_000, ppid: 80)]
        let current = [key(80, 1): counters(0)]
        let measured = try XCTUnwrap(
            SessionProcesses.rates(previous: previous, current: current, elapsed: 1,
                                   debts: [key(81, 1): debt(5_000_000_000, to: key(80, 1), age: 19.5),
                                           key(82, 1): debt(2_000_000_000, to: key(80, 1), age: 3)]))
        XCTAssertNil(measured.debts[key(81, 1)], "the oldest debt outlived its deadline")
        XCTAssertEqual(measured.debts[key(82, 1)]?.age, 4)
        XCTAssertEqual(measured.debts[key(83, 1)]?.nanos, 700_000_000)
        XCTAssertEqual(measured.debts[key(83, 1)]?.age, 0)
        XCTAssertEqual(measured.expired, 1)
    }

    /// A debt with nowhere left to travel is given up on, and counted.
    ///
    /// `61` was holding the debt and has gone, but `61` hung directly off
    /// launchd: its counters left the tree with it, nothing above will ever gain
    /// them, and so nothing above may be charged for them. The other side of
    /// this rule — the heir that *does* have a survivor above it — is
    /// `testAnUnsettledDebtTravelsUpWithTheCountersItWasWrittenAgainst`, and
    /// neither of the two is worth anything without the other: this one alone is
    /// green even if debts never travel at all.
    func testADebtWithNowhereLeftToTravelIsGivenUpOn() throws {
        let previous = [key(61, 1): counters(200_000_000, ppid: 1)]
        let current = [key(99, 1): counters(0)]
        let measured = try XCTUnwrap(
            SessionProcesses.rates(previous: previous, current: current, elapsed: 1,
                                   debts: [key(62, 1): debt(5_000_000_000, to: key(61, 1))]))
        XCTAssertTrue(measured.debts.isEmpty)
        XCTAssertEqual(measured.expired, 1)
    }

    /// The heir has to be a process that was **already there** — an ancestor of
    /// a process the previous sweep saw existed at the previous sweep. Looked up
    /// by the bare pid among everything alive now, a pid handed to a new process
    /// inside the gap answers instead, and the newcomer is left holding a debt
    /// it can never work off: every reap it makes for the next twenty seconds
    /// settles somebody else's already-reported time, and the session it belongs
    /// to reads idle while it works.
    ///
    /// Here `50` dies and its pid is immediately reused — same number, different
    /// start time — while its child `51` dies with it. Nothing is written down:
    /// the walk goes past the impostor to launchd. Keyed on the bare pid, the
    /// newcomer would be charged 3 s.
    func testTheHeirOfAVanishedProcessMustBeAProcessThatWasAlreadyThere() throws {
        let previous = [key(50, 100): counters(1_000_000_000),
                        key(51, 100): counters(3_000_000_000, ppid: 50)]
        let current = [key(50, 200): counters(80_000_000)]
        let measured = try XCTUnwrap(SessionProcesses.rates(previous: previous,
                                                            current: current,
                                                            elapsed: 1,
                                                            debts: [:]))
        XCTAssertTrue(measured.debts.isEmpty, "the pid is the same, the process is not")
        XCTAssertEqual(try XCTUnwrap(measured.percentByKey[key(50, 200)]), 8, accuracy: 0.001)
    }

    /// A process whose parent died first is adopted by launchd, and launchd
    /// reaps it: its counter leaves the tree and is added to nothing we can see.
    /// Subtracting it anyway would take already-reported time off a session that
    /// never gained it — a second error stacked on the first, and one that shows
    /// as an idle row under a busy agent.
    ///
    /// `70` survives and burned 0.5 s. `71` was an orphan — `ppid: 1` — holding
    /// 4 s, and is gone. Nothing is subtracted, so the answer is 50%.
    func testAProcessReapedByLaunchdSubtractsFromNobody() throws {
        let previous = [key(70, 1): counters(0),
                        key(71, 1): counters(4_000_000_000, ppid: 1)]
        let current = [key(70, 1): counters(500_000_000)]
        let rates = try XCTUnwrap(percents(previous: previous,
                                           current: current,
                                           elapsed: 1))
        XCTAssertEqual(try XCTUnwrap(rates[key(70, 1)]), 50, accuracy: 0.001)
    }

    /// A session's CPU is the sum over every process attributed to it, the ones
    /// the marker had to rescue included — an orphan is still doing the
    /// session's work, and it is usually the one doing the most of it.
    func testASessionSumsEveryProcessAttributedToIt() throws {
        let rates = [key(100, 1): 5.0, key(200, 1): 20.0, key(300, 1): 40.0, key(400, 1): 90.0]
        let attribution = SessionProcesses.attribute(facts([(pid: 100, ppid: 1, marker: nil),
                                                            (pid: 200, ppid: 100, marker: nil),
                                                            (pid: 300, ppid: 1, marker: 100),
                                                            (pid: 400, ppid: 1, marker: nil)]),
                                                     sessionPIDs: [100])
        let cpu = SessionProcesses.cpuBySession(rates: rates,
                                                ownerByKey: owners(attribution, startTime: 1))
        // 5 of the session's own, 20 of its child, 40 of the orphan. The 90 of
        // the unattributed process belongs to nobody and is not smuggled in.
        XCTAssertEqual(try XCTUnwrap(cpu[100]), 65, accuracy: 0.001)
        XCTAssertEqual(cpu.count, 1)
    }

    /// **The two sides of that sum need not be the same age**, and the join is
    /// the one place the `(pid, startTime)` discipline used to be dropped. On a
    /// pass that arrives too soon the rates are held from an earlier pass while
    /// the ownership table is this sweep's, which is exactly what holding rates
    /// per process rather than per session was for: "a process that has since
    /// died drops out of the sum instead of being credited to a session by a
    /// stale ownership table".
    ///
    /// Keyed on the bare pid it does the opposite. Here the held rate belongs to
    /// pid 200 as it was — 40% under session 100 — and pid 200 now belongs to a
    /// fresh process under session 700. By the number alone the dead process's
    /// 40% is credited to session 700, which never ran it. By the key it drops
    /// out, and 700 is left with the 5% of the process that really is its own.
    func testAHeldRateIsNotCreditedToWhoeverInheritedThePid() throws {
        let held = [key(200, 100): 40.0, key(300, 1): 5.0]
        let attribution = SessionProcesses.attribute(facts([(pid: 700, ppid: 1, marker: nil),
                                                            (pid: 200, ppid: 700, marker: nil),
                                                            (pid: 300, ppid: 700, marker: nil)]),
                                                     sessionPIDs: [700])
        var table = owners(attribution, startTime: 1)
        // Everything in this sweep started at 1; the held rate is for the pid as
        // it was at 100, which is a different process.
        XCTAssertEqual(table[key(200, 1)], 700)
        let cpu = SessionProcesses.cpuBySession(rates: held, ownerByKey: table)
        XCTAssertEqual(try XCTUnwrap(cpu[700]), 5, accuracy: 0.001)

        // And the same figure is counted when the key really does match, or the
        // assertion above would hold for a sum that credits nothing at all.
        table[key(200, 100)] = 700
        XCTAssertEqual(try XCTUnwrap(SessionProcesses.cpuBySession(rates: held, ownerByKey: table)[700]),
                       45, accuracy: 0.001)
    }

    // MARK: - Onto the row

    /// "Idle" and "not measured yet" are different answers, and the row is where
    /// they are told apart: a session the sweep measured at nothing is `0`, a
    /// session the sweep has not reached is `nil`. Folding the second into the
    /// first would put a permanent `0%` on the panel one second after launch.
    func testAnUnmeasuredSessionHasNoCPUAndAMeasuredIdleOneHasZero() throws {
        var session = TestFixtures.session(id: "s", cwd: "/p", state: .idle)
        session.pid = 4242
        XCTAssertNil(DataSource.aggregate([session], cpu: [:], orphans: [:]).cpuPercent)
        XCTAssertEqual(try XCTUnwrap(DataSource.aggregate([session], cpu: [4242: 0], orphans: [:]).cpuPercent), 0)
    }

    /// A row is a window, a window holds several chats, and the figure it shows
    /// is the whole window's: both the CPU and the orphans are summed over every
    /// chat in the row.
    func testARowSumsEveryChatItHolds() throws {
        var first = TestFixtures.session(id: "a", cwd: "/p", state: .working)
        first.pid = 11
        var second = TestFixtures.session(id: "b", cwd: "/p", state: .idle)
        second.pid = 22
        let aggregate = DataSource.aggregate([first, second],
                                             cpu: [11: 30, 22: 12.5, 33: 500],
                                             orphans: [11: 2, 22: 1, 33: 9])
        XCTAssertEqual(try XCTUnwrap(aggregate.cpuPercent), 42.5, accuracy: 0.001)
        XCTAssertEqual(aggregate.orphanCount, 3)
        XCTAssertFalse(aggregate.cpuIsLowerBound, "a complete sum was marked as a floor")
    }

    /// **Finding 9 of the fourth review: a partial sum says that it is one.**
    ///
    /// The sweep answers per session, and a row is a window with several chats
    /// in it, so one of them can be missing from a pass — a chat that started
    /// this second, a process that went, a counter that went backwards. What is
    /// left is still measured and still worth printing; what it must not do is
    /// pass for the whole row.
    ///
    /// Reporting `nil` instead is the wrong repair and this is where that shows:
    /// `nil` draws as `-`, exactly like a quiet row (§3.1), so it understates by
    /// the *whole* figure where the partial sum understates by one chat's share.
    /// The number stands and wears `≥`, which is what `usageIsLowerBound`
    /// already does with the same shape of hole.
    func testARowMissingAChatSaysItsFigureIsAFloor() throws {
        var measured = TestFixtures.session(id: "a", cwd: "/p", state: .working)
        measured.pid = 11
        var missing = TestFixtures.session(id: "b", cwd: "/p", state: .working)
        missing.pid = 22

        let partial = DataSource.aggregate([measured, missing], cpu: [11: 30], orphans: [:])
        XCTAssertEqual(try XCTUnwrap(partial.cpuPercent), 30, accuracy: 0.001)
        XCTAssertTrue(partial.cpuIsLowerBound, "a sum over one chat of two passed for the whole row")

        // Nothing measured at all is the other answer, and it is not a floor:
        // there is no number under it to be a floor of.
        let nothing = DataSource.aggregate([measured, missing], cpu: [:], orphans: [:])
        XCTAssertNil(nothing.cpuPercent)
        XCTAssertFalse(nothing.cpuIsLowerBound)
    }

    /// And every section of the panel carries them. The three row constructors
    /// are three separate pieces of code — a window, a project with no window,
    /// and the `cwd:` row for an agent outside every scan root — so a figure
    /// wired into one of them can be missing from the other two without a single
    /// test going red.
    func testEverySectionOfThePanelCarriesTheProcessFigures() throws {
        var windowed = TestFixtures.session(id: "w", cwd: "/p/open", state: .working, topic: "topic w")
        windowed.pid = 11
        var headless = TestFixtures.session(id: "h", cwd: "/p/quiet", state: .working)
        headless.pid = 22
        var stray = TestFixtures.session(id: "s", cwd: "/elsewhere/scratch", state: .working)
        stray.pid = 33

        let snapshot = DataSource.assemble(
            projects: [TestFixtures.project(path: "/p/open", rootName: "open"),
                       TestFixtures.project(path: "/p/quiet", rootName: "quiet")],
            windows: [TestFixtures.window(index: 0, title: "topic w \u{2014} open (Workspace)")],
            sessions: [windowed, headless, stray],
            cpuBySessionPID: [11: 30, 22: 40, 33: 50],
            orphansBySessionPID: [11: 1, 22: 2, 33: 3],
            accessibilityTrusted: true)

        let window = try XCTUnwrap(snapshot.openWindows.first)
        XCTAssertEqual(try XCTUnwrap(window.cpuPercent), 30, accuracy: 0.001)
        XCTAssertEqual(window.orphanCount, 1)

        let project = try XCTUnwrap(snapshot.projects.first { $0.displayName == "quiet" })
        XCTAssertEqual(try XCTUnwrap(project.cpuPercent), 40, accuracy: 0.001)
        XCTAssertEqual(project.orphanCount, 2)

        let orphanRow = try XCTUnwrap(snapshot.projects.first { $0.id == "cwd:/elsewhere/scratch" })
        XCTAssertEqual(try XCTUnwrap(orphanRow.cpuPercent), 50, accuracy: 0.001)
        XCTAssertEqual(orphanRow.orphanCount, 3)
    }

    /// The same question put to *every* row instead of to three named ones.
    ///
    /// `aggregate` refuses to have its two tables defaulted, so a fourth row
    /// constructor that forgets to *ask* for the figures is a compile error.
    /// That is only half the door: `SwitcherRow.cpuPercent`, `orphanCount` and
    /// `cpuIsLowerBound` all have memberwise defaults, so a constructor that
    /// asks `aggregate` and then forgets to carry the answer onto the row
    /// compiles perfectly and shows a blank column — or an unmarked partial sum
    /// — for ever. The test that names three rows cannot see that either, for
    /// whichever row it does not name.
    ///
    /// `cpuIsLowerBound` was the field that proved the point. It reaches the row
    /// through the same three constructors and nothing asked about it: deleting
    /// `cpuIsLowerBound: aggregate.cpuIsLowerBound,` from all three left the
    /// whole suite green, and in that state the `≥` could never appear on the
    /// panel and a sum over one chat of two would read as a whole one.
    ///
    /// Which is why pid 44 is **not** in the `cpu` table below. With every
    /// session measured the flag is `false` on every row, and an assertion that
    /// compares `false` to `false` everywhere cannot go red whatever the
    /// constructors do. Leaving the twin unmeasured lights it on the `quiet`
    /// row, and costs that row's expected figure the twin's share: 40 rather
    /// than 45.5.
    ///
    /// Modelled on `testEveryAssembledRowTakesItsSubagentsFromItsOwnChats`, and
    /// over the same fixture shape, because the awkward row is the same one: two
    /// windows of one project where only the second title names a chat, so the
    /// twin ends up holding no sessions at all and must report `nil` CPU rather
    /// than somebody else's.
    func testEveryAssembledRowTakesItsProcessFiguresFromItsOwnChats() throws {
        var windowed = TestFixtures.session(id: "w", cwd: "/p/open", state: .working, topic: "topic w")
        windowed.pid = 11
        var headless = TestFixtures.session(id: "h", cwd: "/p/quiet", state: .working)
        headless.pid = 22
        var headlessTwin = TestFixtures.session(id: "h2", cwd: "/p/quiet", state: .idle)
        headlessTwin.pid = 44
        var stray = TestFixtures.session(id: "s", cwd: "/elsewhere/scratch", state: .working)
        stray.pid = 33

        // No entry for 44: the twin is the chat that went unmeasured this pass,
        // which is what lights `cpuIsLowerBound` on the row it shares.
        let cpu: [Int32: Double] = [11: 30, 22: 40, 33: 50, 99: 900]
        let orphans: [Int32: Int] = [11: 1, 22: 2, 33: 3, 44: 4, 99: 99]
        let snapshot = DataSource.assemble(
            projects: [TestFixtures.project(path: "/p/open", rootName: "open"),
                       TestFixtures.project(path: "/p/quiet", rootName: "quiet")],
            windows: [TestFixtures.window(index: 0, title: "\u{0438}\u{043d}\u{0430}\u{044f} \u{2014} open (Workspace)"),
                      TestFixtures.window(index: 1, title: "topic w \u{2014} open (Workspace)")],
            sessions: [windowed, headless, headlessTwin, stray],
            cpuBySessionPID: cpu,
            orphansBySessionPID: orphans,
            accessibilityTrusted: true)

        // `rows` rather than the two lists by hand: a third list would then be
        // covered too instead of quietly skipped.
        let rows = snapshot.rows
        for row in rows {
            let expected = DataSource.aggregate(row.sessions, cpu: cpu, orphans: orphans)
            XCTAssertEqual(row.cpuPercent, expected.cpuPercent, "\(row.id)")
            XCTAssertEqual(row.cpuIsLowerBound, expected.cpuIsLowerBound, "\(row.id)")
            XCTAssertEqual(row.orphanCount, expected.orphanCount, "\(row.id)")
        }

        // And the fixture has to hold every kind of row the loop is for, or it
        // agrees about nothing. The chat-less window is the fragile one: it
        // exists only because `distribute` leaves the twin empty.
        XCTAssertTrue(snapshot.openWindows.contains { $0.sessions.isEmpty }, "no chat-less window row")
        XCTAssertTrue(snapshot.projects.contains { $0.id.hasPrefix("cwd:") }, "no orphan row")
        // The two-chat row sums rather than picking one: 40 over the one chat
        // that was measured, and 2 + 4 over both, because orphans are counted
        // from the table for every chat the row holds.
        let twoChats = try XCTUnwrap(snapshot.projects.first { $0.displayName == "quiet" })
        XCTAssertEqual(twoChats.sessions.count, 2)
        XCTAssertEqual(try XCTUnwrap(twoChats.cpuPercent), 40, accuracy: 0.001)
        XCTAssertEqual(twoChats.orphanCount, 6)
        // And the flag is lit somewhere, or the loop above compares `false` to
        // `false` on every row and could not go red.
        XCTAssertTrue(twoChats.cpuIsLowerBound, "the fixture measures every chat")
        XCTAssertTrue(rows.contains { !$0.cpuIsLowerBound && $0.cpuPercent != nil },
                      "and unlit somewhere, or it compares `true` to `true` instead")
        // Every row that has a chat carries a figure, so the loop is comparing
        // numbers rather than agreeing that everything is `nil`.
        XCTAssertEqual(rows.filter { $0.cpuPercent != nil }.count,
                       rows.filter { !$0.sessions.isEmpty }.count)
        XCTAssertTrue(rows.contains { $0.sessions.isEmpty && $0.cpuPercent == nil }, "no unmeasured row")
    }
}

/// The half of §2.8 that talks to the kernel: the units its counters are in,
/// the hand-rolled parse of `KERN_PROCARGS2`, and what one pass of
/// `ProcessSampler` promises the next one.
///
/// These run against real processes because there is nothing else to run them
/// against — the questions here are all about what the machine actually hands
/// over, and a fixture would only restate the assumption being tested.
final class SessionProcessSyscallTests: XCTestCase {

    private var spawned: [Process] = []

    override func tearDown() {
        for process in spawned where process.isRunning { process.terminate() }
        spawned = []
        super.tearDown()
    }

    /// An interpreter that hands its environment over. Platform binaries do not
    /// — that is the point of `testAPlatformBinaryWithholdsItsEnvironment` — so
    /// the marker tests need one that does.
    private static let interpreter = "/usr/bin/python3"

    /// A child that stays alive until the test ends, with the environment given.
    ///
    /// A fixture that has something to report back does it through a file it
    /// renames into place, not through a pipe: a pipe can only be read by
    /// blocking on it, and the fixtures here have to keep sampling while they
    /// wait.
    private func spawn(_ path: String,
                       _ arguments: [String],
                       _ environment: [String: String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        try process.run()
        spawned.append(process)
        return process.processIdentifier
    }

    /// The child's argument block only exists after `execve`, so a read that
    /// beats the exec sees nothing. Polls rather than sleeps a fixed time.
    private func marker(of pid: Int32, settlingFor seconds: TimeInterval = 5) -> SessionProcesses.Marker {
        var buffer = [UInt8](repeating: 0, count: SessionProcesses.argumentsMaximum)
        let deadline = Date().addingTimeInterval(seconds)
        var answer = SessionProcesses.marker(of: pid, buffer: &buffer)
        while case .withheld = answer, Date() < deadline {
            usleep(20_000)
            answer = SessionProcesses.marker(of: pid, buffer: &buffer)
        }
        return answer
    }

    private func requireInterpreter() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.interpreter) else {
            throw XCTSkip("no \(Self.interpreter) to read an environment out of")
        }
    }

    // MARK: - Units

    /// `ri_user_time` and `ri_system_time` are mach absolute time units, not
    /// nanoseconds, whatever the `_time` in their names suggests. Read as
    /// nanoseconds every figure on the panel was 41.7 times too small on this
    /// machine — three processes each burning a whole core showed as 7.25%.
    ///
    /// Asked against an independent clock rather than against the timebase the
    /// conversion itself uses: one thread spinning for a third of a second must
    /// move the process's counter by very nearly the wall time it spun for.
    /// `DispatchTime.uptimeNanoseconds` does its own conversion, so the two
    /// sides of this ratio share nothing but the hardware. Dropping the
    /// conversion makes it 0.024.
    func testTheKernelsCPUCounterIsNotAlreadyInNanoseconds() throws {
        let before = try XCTUnwrap(SessionProcesses.cpuNanos(of: getpid())).own
        let start = DispatchTime.now().uptimeNanoseconds
        var spins = 0
        while DispatchTime.now().uptimeNanoseconds - start < 300_000_000 { spins += 1 }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let burned = try XCTUnwrap(SessionProcesses.cpuNanos(of: getpid())).own - before
        XCTAssertGreaterThan(spins, 0)
        let ratio = Double(burned) / Double(elapsed)
        // Not exactly 1: the process has other threads, and a busy machine
        // deschedules this one. The bound has to leave room for that and still
        // catch the mistake, and the mistake is a factor of 41.7 — read as
        // nanoseconds this ratio is 0.024.
        //
        // 0.5 was too tight and was measured to be: under the load of agents
        // and a sweep probe this thread got only 0.455 of the wall time it spun
        // for, and the test went red in 1 run of 3 (26.08.2026). 0.1 sits
        // between the two, and roughly four times from each: 4.6x below the
        // worst descheduling actually seen, 4.2x above the ratio the mistake
        // this test is named for would produce.
        XCTAssertGreaterThan(ratio, 0.1, "the counter barely moved: still being read as nanoseconds?")
        XCTAssertLessThan(ratio, 2.0)
    }

    /// The timebase is a ratio and the conversion is exact, remainder included.
    ///
    /// The ratio is a parameter here rather than this machine's own, because
    /// asked through `timebase` the test cannot reach the branch it is named
    /// after. It built its input as `denom * 1_000_003 + denom - 1`, which is a
    /// multiple of `denom` whenever `denom == 1` — so on Intel and on the `(1,1)`
    /// fallback the remainder is always zero and the oracle degenerates to
    /// `units == units`. 125/3 is this machine; 1/1 is the other case, and it
    /// has to be asked on purpose.
    func testMachUnitsConvertExactly() {
        func check(numer: UInt64, denom: UInt64) {
            XCTAssertEqual(SessionProcesses.nanoseconds(fromMachUnits: 0, numer: numer, denom: denom), 0)
            // Not a multiple of `denom`, whatever `denom` is, so the remainder
            // path is the one being asked.
            let units = denom * 1_000_003 + 1
            XCTAssertEqual(SessionProcesses.nanoseconds(fromMachUnits: units, numer: numer, denom: denom),
                           units * numer / denom,
                           "\(numer)/\(denom)")
        }
        check(numer: 125, denom: 3)
        check(numer: 1, denom: 1)

        // And the live ratio really is the one the app converts with.
        let (numer, denom) = SessionProcesses.timebase
        XCTAssertGreaterThan(numer, 0)
        XCTAssertGreaterThan(denom, 0)
        XCTAssertEqual(SessionProcesses.nanoseconds(fromMachUnits: 1_000_003),
                       SessionProcesses.nanoseconds(fromMachUnits: 1_000_003, numer: numer, denom: denom))
    }

    // MARK: - The argument block

    /// The marker, read out of a live process's environment by the hand-rolled
    /// parse: `argc`, the exec path, the NUL padding, `argv`, then the block the
    /// answer is in.
    ///
    /// Two arguments past the script, so that the `argv` skip has more than one
    /// string to get right — an off-by-one there lands in the middle of the
    /// environment or past the end of it.
    func testTheMarkerIsReadOutOfALiveProcessEnvironment() throws {
        try requireInterpreter()
        let pid = try spawn(Self.interpreter,
                            ["-c", "import time; time.sleep(30)", "alpha", "beta"],
                            ["CLAUDE_PID": "424242", "PATH": "/usr/bin:/bin"])
        XCTAssertEqual(marker(of: pid), .pid(424242))
    }

    /// The compare is a prefix compare, and a prefix compare that starts
    /// anywhere but the beginning of the variable matches `MY_CLAUDE_PID=` too.
    /// The wrong session, from a variable that has nothing to do with Claude
    /// Code — and nothing else on this path would notice.
    func testAVariableMerelyEndingInTheMarkersNameIsNotTheMarker() throws {
        try requireInterpreter()
        let pid = try spawn(Self.interpreter,
                            ["-c", "import time; time.sleep(30)"],
                            ["MY_CLAUDE_PID": "424242", "PATH": "/usr/bin:/bin"])
        XCTAssertEqual(marker(of: pid), .absent)
    }

    /// The measured negative result of §2.8: `KERN_PROCARGS2` hands over `argv`
    /// and stops for a platform binary, whatever is actually in its
    /// environment. The marker cannot see 296 of the 682 readable processes on
    /// this machine — 43% of them — and `/bin/sleep` is one.
    ///
    /// The environment here really does carry the marker, which is what makes
    /// this "withheld" rather than "absent": the parser is not being asked
    /// whether the variable is there, it is being asked whether it was allowed
    /// to look.
    ///
    /// And `.withheld` on its own cannot answer that. It is the parser's answer
    /// to four different things — a buffer smaller than an `Int32`, a `sysctl`
    /// that failed with EPERM, one that failed with ESRCH because the process
    /// exited, and the one meant here, a block that ends where `argv` ends. The
    /// assertion is their union, so it holds when the process simply died before
    /// the call, which is the one outcome that would make this test about
    /// nothing. So the cause is asked directly: the syscall **succeeded**, and
    /// there is nothing past `argv`.
    func testAPlatformBinaryWithholdsItsEnvironment() throws {
        let pid = try spawn("/bin/sleep", ["30"], ["CLAUDE_PID": "424242", "PATH": "/usr/bin:/bin"])
        // No settling loop: `withheld` is the answer, so waiting for it to stop
        // being `withheld` would wait the whole timeout out every run.
        var buffer = [UInt8](repeating: 0, count: SessionProcesses.argumentsMaximum)
        usleep(200_000)
        XCTAssertEqual(SessionProcesses.marker(of: pid, buffer: &buffer), .withheld)

        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        XCTAssertEqual(sysctl(&mib, 3, &buffer, &size, nil, 0), 0,
                       "the kernel refused the call outright: this is not the case under test")
        XCTAssertGreaterThan(size, MemoryLayout<Int32>.size)

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buffer[0..<MemoryLayout<Int32>.size]) }
        XCTAssertEqual(argc, 2, "/bin/sleep 30")
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        for _ in 0..<argc {
            while index < size, buffer[index] != 0 { index += 1 }
            index += 1
        }
        XCTAssertGreaterThanOrEqual(index, size, "the block did not stop at argv after all")
    }

    // MARK: - The ledger, against real processes

    /// The processes the sweep can see hanging directly off `parent`.
    private func children(of parent: Int32) -> [Int32] {
        SessionProcesses.listProcesses().filter { $0.counters.ppid == parent }.map(\.pid)
    }

    /// Waits for `parent` to fork, and answers with the child's pid.
    private func firstChild(of parent: Int32, within seconds: TimeInterval = 5) throws -> Int32 {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let child = children(of: parent).first { return child }
            usleep(20_000)
        }
        throw XCTSkip("the fixture never forked")
    }

    /// The state finding 1 is about: the process has exited and nobody has
    /// waited for it yet, so it is still in `proc_listallpids` and still answers
    /// `proc_pid_rusage` while `PROC_PIDTBSDINFO` refuses it. `listProcesses`
    /// needs both and therefore drops the row — a disappearance that is not one.
    private func isZombie(_ pid: Int32) -> Bool {
        SessionProcesses.cpuNanos(of: pid) != nil && SessionProcesses.parentAndStart(of: pid) == nil
    }

    /// **Finding 1, against a real zombie.** A child burns 3.0 core-seconds and
    /// exits; its parent does not call `wait` until the sampling loop below
    /// hands it the `reap` file, which that loop writes only once a pass has
    /// both seen the zombie and swept past it. Through that window the sweep
    /// cannot see the child at all, and its counter has not gone anywhere — the
    /// parent's `ri_child_*` does not move until the `wait`.
    ///
    /// Deducted on disappearance, this fixture reports the child's whole
    /// lifetime inside the tick where the reap lands, while the pass where the
    /// child turned into a zombie floors to zero, because the deduction is
    /// charged to a parent that gained nothing. With `swift build` in the
    /// child's place that spike is the 60000% §2.8 names. The ledger defers
    /// instead: no growth, nothing settled, and the debt waits for the pass
    /// where the reap really lands.
    ///
    /// **How much the child burns is what makes `peak < 150` discriminate, so
    /// it is derived from the pass rather than picked.** Deducted on
    /// disappearance the whole reaped total lands in one pass, so the ceiling
    /// can only fire when that total is over 1.5 passes' worth — and a pass was
    /// measured rather than assumed: a second of sleep plus a sweep costs
    /// 1.0043–1.0195 s over five instrumented runs, 27.08.2026. The sweep in
    /// that second is a *warm* one, which §6 puts at about a millisecond;
    /// §6's 5.9–6.6 ms is the cold sweep, and exactly one sweep here is cold —
    /// the baseline one before the loop, outside every tick measured. What
    /// fills the rest of the spread is `Thread.sleep` overshoot and scheduling
    /// jitter, which was not measured and is not being sized here. At the 1.5
    /// core-seconds this loop used to spin, the threshold was 1.5 passes ≈
    /// 1.51 s of burn against 1.50 reaped: the mutation peaked at 148.795% and
    /// 149.457% and **passed**, while the fixture stayed green and said
    /// nothing. At 3.0 a pass would have to stretch to 2.0 s — double what was
    /// measured — before the ceiling stopped catching it, and the mutation now
    /// comes to 296.995% and 296.242% over two runs the same day, failing on
    /// the ceiling and on the integral both (4.9990 and 5.9294 core-seconds
    /// against 3.000983 and 3.000826 reaped, 1.67× and 1.98×, where the bound
    /// below is 1.2×).
    ///
    /// What moved is the burn and not the ceiling, because the healthy peak is
    /// a *rate* and does not know how long the child spins: 99.969%, 99.874%
    /// and 100.003% over three runs at 3.0, against 96.355% and 99.457% from
    /// the 1.5 child — the same one core either way. Those four figures are
    /// unloaded runs, and the peak moves with load: later the same day, minutes
    /// apart and under other work, the same fixture read 89.9–99.8% at 3.0 and
    /// 76.2–86.0% at 1.5. The claim rests on the mechanism rather than on them.
    /// The most a healthy pass can report for one attributed process is what
    /// that process burned since the previous sweep, which cannot exceed one
    /// core's worth of one pass, over the sampler's own interval; the row's
    /// figure sums over every process of the session
    /// (`cpuPercentBySessionPID`), so the strict bound is one core per
    /// attributed process, and it comes to ~100% here only because the parent
    /// sleeps in its polling loop. That interval is bounded below by the
    /// `Thread.sleep(1)` plus the sweep, so contention moves the figure down by
    /// whole percents. Up it can move only by one residual skew: the counters
    /// are read *inside* the sweep while `now` is taken after it
    /// (`SessionProcesses.sample`, where "same side both times is the whole of
    /// the fix"), and where in a sweep a given process is read still differs
    /// between two passes, so the interval the numerator covers can slightly
    /// outrun the one the denominator measures. That is what the 100.003%
    /// opening this paragraph is — a fraction of a percent, and no size is
    /// being put on it here. Lowering the ceiling to
    /// the size of the spike would have eaten the 50 points of slack that
    /// absorb a loaded machine — the very margin the load flake cured below
    /// turned on. **The price of the burn is a pass, and it is counted in
    /// passes because seconds cannot express it:** a run is a whole number of
    /// ~1 s passes and the machine decides how many the child needs, so
    /// neither the run's length nor the difference between two burns is a
    /// fixed number of seconds — the difference is quantised the same way the
    /// absolute is. Counted, 27.08.2026, six runs at each burn back to back in
    /// one session with the pass count printed from the loop: at 1.5 the run
    /// took 4 passes five times and 5 once (4.166, 4.173, 4.168, 5.187, 4.177
    /// and 4.182 s), at 3.0 it took 5 passes three times, 6 twice and 8 once
    /// (5.111, 5.122, 8.817, 6.128, 5.175 and 6.118 s). One pass between the
    /// two usual shapes, and a spread of one pass at 1.5 against three at 3.0,
    /// because the child's exit lands on a pass boundary rather than safely
    /// between two. The counts say where: a run ends two passes after the one
    /// that saw the zombie, so 5 and 6 passes put the exit either side of the
    /// third check — which is what the mutation's own integrals already
    /// showed, 4.9990 and 5.9294 being a pass apart, the child last seen on
    /// the second pass and on the third. The eight-pass run is that boundary
    /// moved and not the account failing: it puts the exit between the fifth
    /// check and the sixth, a loaded machine taking five to six *passes* — 5.5
    /// to 6.6 wall seconds at the 1.0923 s its own passes averaged — to hand
    /// the child its three core-seconds. Against that 1.0923 s stand
    /// 1.0066–1.0123 s in the other eight instrumented runs at 3.0: the five
    /// of the six counted above that are not this one, plus the three of the
    /// `print`-cost check below. Every set of seconds recorded here before is
    /// one of these shapes rather than a disagreement with another — 4.10 and 4.14 s are
    /// the four-pass run at 1.5, 5.11/5.13/5.13 the five-pass run at 3.0,
    /// 6.13/6.14/6.13 the six-pass one — so a re-measure is only readable
    /// beside its own pass count. One shape has a second sighting and the
    /// other does not: 6.13/6.14/6.13 is the six-pass record just quoted, not
    /// a repeat of it, while 5.116/5.100/5.113/5.127 is genuinely new — a
    /// separate uninstrumented sitting of the same unchanged fixture the same
    /// day. Neither sitting had its passes counted, so calling them the
    /// six-pass and the five-pass shape is read off the bands the counted runs
    /// establish — 5.111–5.175 s for five passes, 6.118/6.128 for six — and is
    /// an inference, not a reading. Anyone taking the burn back down to 1.5 to
    /// save that pass is buying it with the ceiling, which stops
    /// discriminating at that size. Every per-pass figure above was read with
    /// a `print` inside the loop, which costs nothing the clock can see:
    /// three further runs with it came to 5.12, 5.13 and 5.14 s against the
    /// 5.11, 5.13 and 5.13 s without it, both of them the five-pass shape and
    /// therefore comparable, and all twelve runs of the count above carried
    /// it too. The 227.95% and 281.22% §2.8 records are not this fixture's
    /// margin either: those runs reaped 2.30 and 2.85 core-seconds, so
    /// whatever else they measured, it was not this child.
    ///
    /// The table-driven fixtures cannot express this at all — in them a
    /// disappearance and the reap that follows it always fall in the same gap,
    /// which is the one arrangement where deducting on disappearance is right.
    ///
    /// What is asserted is the whole figure and not one tick: no pass may report
    /// more than one core when only one core was ever burned, and the child's
    /// CPU must be counted **once** across the run.
    ///
    /// How much CPU that is cannot be assumed, so the oracle is `wait4`, which
    /// is a different API from the one under test and the same one §2.8's
    /// whole-figure check used through `/usr/bin/time`: the fixture reports what
    /// the kernel handed it at the reap, and the integral of the panel's own
    /// figure has to come to the same thing. Deducting on disappearance roughly
    /// doubles that integral — the child's total is reported once as it burns
    /// and again in the tick where the reap lands.
    ///
    /// A run that never saw the zombie state would prove nothing, so that is
    /// asserted too.
    ///
    /// **Every wait in here is on a condition, and it took two rounds of red runs
    /// to get there.** The child used to spin for 3 s of *wall* time, which on a
    /// machine with its own work to do is not an amount of CPU at all: under a
    /// concurrent build it came out below the half-core-second the canary
    /// demands and the test failed for the machine's reasons rather than the
    /// ledger's. The child now spins until `time.process_time()` says it has
    /// burned the **core**-seconds sized above, signals its exit through a file
    /// so the zombie window is a window and not a guess, and the sampling loop
    /// runs until the reap has landed and a pass has carried it rather than for a
    /// fixed nine passes — because how many wall seconds those core-seconds
    /// take now belongs to the machine. Same fix as
    /// `testARealGrandchildLeftToLaunchdDoesNotBlankTheSurvivorsTick`, which
    /// waits on the grandchild's counter for the same reason.
    ///
    /// **And the zombie window itself was the last fixed interval, measured in
    /// the wrong clock.** The parent used to hold the corpse for 3 s and then
    /// reap it, which is only a window if a pass falls inside it — and a pass is
    /// a second of sleep plus a whole sweep of the process table, so how many
    /// passes fit in three seconds belongs to the machine's load and not to this
    /// test. Overrun, the fixture does not fail loudly: the disappearance and
    /// the reap land in the same gap, which is the *ordinary* case and the one
    /// arrangement in which deducting on disappearance is right, so the run
    /// quietly stops testing the thing it is named for and goes red on
    /// `zombieSeen`. The parent now waits for a third file instead, which this
    /// loop creates once a pass has actually seen the zombie **and swept**. The
    /// window is then exactly as long as it needs to be, which also keeps it far
    /// inside `debtLifetimeSeconds` — a debt that aged out before its reap would
    /// spike by the whole amount written off.
    ///
    /// **Shown rather than argued, and without loading anything**: what decides
    /// the old shape is the ratio between the window and the pass, so the window
    /// was shrunk instead of the machine being slowed. Cut to 0.05 s with the
    /// passes left at a second, the fixed-window shape went red on `zombieSeen`
    /// in 3 runs of 3 (27.08.2026), on the very assertion the flake was reported
    /// on; the handshake is green in 3 of 3, at 4.1 s a run — that being the
    /// 1.5-core-second child of the hour, whose four-pass shape re-measured
    /// the same day at 4.166–4.182 s, and the run costs a pass more now for
    /// the reason sized at the top.
    ///
    /// A flake here is worse than it looks: this suite is the only thing between
    /// the ledger and a silent regression, and a test that cries wolf under load
    /// gets re-run rather than believed.
    func testARealZombieIsDeferredRatherThanSpikingWhenItIsReaped() throws {
        try requireInterpreter()
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        let exited = scratch.appendingPathComponent("vscode-switcher-zombie-exited-\(getpid())")
        let reap = scratch.appendingPathComponent("vscode-switcher-zombie-reap-\(getpid())")
        let reaped = scratch.appendingPathComponent("vscode-switcher-zombie-reaped-\(getpid())")
        let scratchFiles = [exited, reap, reaped]
        for url in scratchFiles { try? FileManager.default.removeItem(at: url) }
        defer { for url in scratchFiles { try? FileManager.default.removeItem(at: url) } }
        // The child burns core-seconds, not wall seconds, and says so by
        // touching a file the instant before it exits — the parent cannot ask
        // whether it has exited without reaping it, and reaping it is the one
        // thing that must wait. It waits on a file of its own rather than on a
        // clock: only the sampling loop below knows whether the zombie has been
        // observed yet. The result goes through a rename so a pass never reads
        // it half-written.
        let script = """
            import os, time
            exited = "\(exited.path)"
            reap = "\(reap.path)"
            reaped = "\(reaped.path)"
            pid = os.fork()
            if pid == 0:
                base = time.process_time()
                while time.process_time() - base < 3.0: pass
                open(exited, "w").close()
                os._exit(0)
            while not os.path.exists(exited): time.sleep(0.05)
            while not os.path.exists(reap): time.sleep(0.05)
            usage = os.wait4(pid, 0)[2]
            with open(reaped + ".tmp", "w") as handle:
                handle.write(repr(usage.ru_utime + usage.ru_stime))
            os.rename(reaped + ".tmp", reaped)
            time.sleep(120)
            """
        let parent = try spawn(Self.interpreter, ["-c", script], ["PATH": "/usr/bin:/bin"])
        let child = try firstChild(of: parent)

        let sampler = ProcessSampler()
        _ = sampler.sample(sessionPIDs: [parent])
        var last = DispatchTime.now().uptimeNanoseconds
        var zombieSeen = false
        var peak = 0.0
        var coreSeconds = 0.0
        // Until the reap has landed and a pass has carried it — the jump in
        // `ri_child_*` lands in the gap after the `wait4`, so one more pass
        // after the result appears is what makes the integral complete. The
        // deadline is only there so a machine that cannot manage it at all
        // fails rather than hangs.
        let deadline = Date().addingTimeInterval(180)
        var passesSinceReap = 0
        var released = false
        while passesSinceReap < 2, Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
            // The zombie window is what makes this fixture the case under test,
            // so it is looked for at the same moment the sweep runs.
            if isZombie(child) { zombieSeen = true }
            let now = DispatchTime.now().uptimeNanoseconds
            let percent = sampler.sample(sessionPIDs: [parent]).cpuPercentBySessionPID[parent] ?? 0
            peak = max(peak, percent)
            coreSeconds += percent / 100 * Double(now - last) / 1e9
            last = now
            // Let the parent reap, now that a pass has both seen the zombie and
            // swept past it — that sweep is the one that writes the debt down.
            // Released any earlier and the reap could land in the same gap as
            // the disappearance, which is the ordinary case and not this one.
            if zombieSeen, !released {
                FileManager.default.createFile(atPath: reap.path, contents: nil)
                released = true
            }
            if FileManager.default.fileExists(atPath: reaped.path) { passesSinceReap += 1 }
        }

        XCTAssertTrue(zombieSeen,
                      "the child was never caught between exit and wait within the deadline: "
                          + "this run tested nothing")
        XCTAssertEqual(passesSinceReap, 2,
                       "the fixture never got as far as the reap within the deadline")
        XCTAssertLessThan(peak, 150,
                          "one core was burned and one pass claimed more than one core")

        let printed = try String(contentsOf: reaped, encoding: .utf8)
        let burned = try XCTUnwrap(Double(printed.trimmingCharacters(in: .whitespacesAndNewlines)),
                                   "the fixture never reported what it reaped: \(printed)")
        // The child spins on its own counter, so this cannot fail for want of a
        // free core any more. It stays because it is the one assertion that
        // would notice `process_time` measuring something other than CPU.
        XCTAssertGreaterThan(burned, 0.5, "the child barely ran: this run tested nothing")
        // Below `burned` by whatever the child had spent before the baseline
        // sweep, and never above it: the point of the ledger is that the same
        // nanoseconds are not reported twice.
        XCTAssertGreaterThan(coreSeconds, burned * 0.7)
        XCTAssertLessThan(coreSeconds, burned * 1.2)
    }

    /// **Finding 3, against a real reparented grandchild.** The middle process
    /// exits first, so its child is handed to launchd and reaped there: the
    /// counter leaves the tree, and the grandparent — which the walk still finds
    /// and still charges — never gains a nanosecond of it.
    ///
    /// Both deaths are made to fall in one gap on purpose, because that is the
    /// only arrangement in which the walk is fooled: given a sweep in between,
    /// the grandchild is seen with `ppid` 1 and no heir is found at all (which
    /// is `testAProcessReapedByLaunchdSubtractsFromNobody`, and was already
    /// right). The live shape is a `Bash` timeout killing a process group, the
    /// shell exiting a moment before the compiler.
    ///
    /// The grandparent burns a core throughout. Deducted on disappearance, the
    /// grandchild's seconds come off the grandparent's one-second tick and the
    /// row of a session burning a whole core reads as empty space. Written down
    /// instead, it waits for growth that never comes, and the tick keeps its
    /// own work.
    ///
    /// **How much work that is, is measured rather than assumed.** This machine
    /// is shared and a spinning fixture does not get a whole core — under a load
    /// average of 26 it got about two thirds of one (26.08.2026) — so the
    /// assertion compares the panel's figure against the grandparent's own
    /// counter over the same window, read directly. That is not an independent
    /// syscall, and it is not meant to be: what it is independent of is the rate
    /// path, the ledger and the attribution, which is the whole of what this
    /// fixture is about. The defect reports 0 against an oracle that reports
    /// whatever the process really got.
    func testARealGrandchildLeftToLaunchdDoesNotBlankTheSurvivorsTick() throws {
        try requireInterpreter()
        let stop = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vscode-switcher-reparent-\(getpid())")
        try? FileManager.default.removeItem(at: stop)
        let script = """
            import os, time
            stop = "\(stop.path)"
            middle = os.fork()
            if middle == 0:
                grandchild = os.fork()
                if grandchild == 0:
                    while not os.path.exists(stop): pass
                    time.sleep(0.4)
                    os._exit(0)
                while not os.path.exists(stop): time.sleep(0.01)
                os._exit(0)
            while True: pass
            """
        let grandparent = try spawn(Self.interpreter, ["-c", script], ["PATH": "/usr/bin:/bin"])
        let middle = try firstChild(of: grandparent)
        let grandchild = try firstChild(of: middle)

        let sampler = ProcessSampler()
        _ = sampler.sample(sessionPIDs: [grandparent])
        // **Waited for rather than slept through.** The grandchild has to be
        // holding more than one tick's worth when it goes, or deducting it
        // would not blank anything and the run would prove nothing. Two seconds
        // of wall clock is not that: this fixture spins two processes at once on
        // a machine that has its own work to do, and while the suite itself was
        // running the grandchild came out with 0.788 core-seconds of the two
        // (27.08.2026) — the canary below fired, in a run that was green when
        // the machine was quiet. So the gap lasts until the counter is really
        // there, and the canary stays to catch the machine that cannot manage it
        // at all.
        let deadline = Date().addingTimeInterval(10)
        var owed: UInt64 = 0
        repeat {
            Thread.sleep(forTimeInterval: 0.25)
            owed = try XCTUnwrap(SessionProcesses.cpuNanos(of: grandchild)).own
        } while owed <= 1_100_000_000 && Date() < deadline
        _ = sampler.sample(sessionPIDs: [grandparent])
        let ownBefore = try XCTUnwrap(SessionProcesses.cpuNanos(of: grandparent)).own
        let startedAt = DispatchTime.now().uptimeNanoseconds
        XCTAssertGreaterThan(owed, 1_000_000_000,
                             "the grandchild has to hold more than one tick's worth, "
                                 + "or deducting it would not blank anything")

        // Both die inside this one gap: the middle at once, the grandchild 0.4 s
        // later — orphaned in between, which is what sends it to launchd.
        FileManager.default.createFile(atPath: stop.path, contents: nil)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNil(SessionProcesses.parentAndStart(of: grandchild), "the grandchild outlived the gap")
        XCTAssertFalse(SessionProcesses.listProcesses().contains { $0.pid == middle },
                       "the middle process outlived the gap")

        let ownAfter = try XCTUnwrap(SessionProcesses.cpuNanos(of: grandparent)).own
        let window = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1e9
        let oracle = Double(ownAfter - ownBefore) / 1e9 / window * 100
        let alone = sampler.sample(sessionPIDs: [grandparent]).cpuPercentBySessionPID[grandparent] ?? 0
        XCTAssertGreaterThan(oracle, 20, "the grandparent was starved: this run tested nothing")
        XCTAssertEqual(alone, oracle, accuracy: max(15, oracle * 0.25),
                       "the survivor was charged for a counter that went to launchd")
        // Nothing will ever settle it, which is exactly what the counter is for:
        // an unsettled debt is invisible everywhere else.
        XCTAssertGreaterThan(sampler.lastPassStats().openDebts, 0)
        try? FileManager.default.removeItem(at: stop)
    }

    // MARK: - The sampler

    /// A rate needs two passes, and the second one has to actually have it. The
    /// timestamp of the pass before is the whole of that state: forget to store
    /// it and every pass forever is a first pass, which the panel draws as a
    /// blank column and nothing anywhere complains about.
    func testARateArrivesOnTheSecondPassAndNotTheFirst() throws {
        let sampler = ProcessSampler()
        let me = getpid()
        XCTAssertNil(sampler.sample(sessionPIDs: [me]).cpuPercentBySessionPID[me])

        // Past `minimumSampleSeconds`, or the second pass is a hold of the first
        // and the first had nothing to hold.
        let start = DispatchTime.now().uptimeNanoseconds
        var spins = 0
        while DispatchTime.now().uptimeNanoseconds - start < 600_000_000 { spins += 1 }
        XCTAssertGreaterThan(spins, 0)

        let percent = try XCTUnwrap(sampler.sample(sessionPIDs: [me]).cpuPercentBySessionPID[me])
        XCTAssertGreaterThan(percent, 10)
    }

    /// A pass that arrives too soon holds the last rate rather than computing a
    /// new one from a gap too short to divide (SPEC §2.8), and holds its
    /// baseline with it so the gap goes on growing.
    ///
    /// The shape is the panel's own: `SnapshotStore.setPanelVisible(_:)`
    /// rebuilds the snapshot the moment the panel slides out, whenever the last
    /// timer tick happened to be. Recomputed from that gap a steady 30% reads as
    /// anything from 0 to 93 (§2.8); recomputed from nothing at all it reads as
    /// a blank column at the one moment somebody is looking at it.
    ///
    /// Two things are asked, and the second is what makes it a hold rather than
    /// a coincidence: the burst passes report the same figure the measured one
    /// did, to the last bit, and the pass after the burst — a full gap later —
    /// reports a different one. A sampler that simply recomputed would drift
    /// across the burst; one that blanked would report nothing there at all.
    func testAPassThatArrivesTooSoonHoldsTheRateItHad() throws {
        let sampler = ProcessSampler()
        let me = getpid()
        _ = sampler.sample(sessionPIDs: [me])

        let start = DispatchTime.now().uptimeNanoseconds
        var spins = 0
        while DispatchTime.now().uptimeNanoseconds - start < 600_000_000 { spins += 1 }
        XCTAssertGreaterThan(spins, 0)
        let measured = try XCTUnwrap(sampler.sample(sessionPIDs: [me]).cpuPercentBySessionPID[me])

        for _ in 0..<3 {
            let held = try XCTUnwrap(sampler.sample(sessionPIDs: [me]).cpuPercentBySessionPID[me])
            XCTAssertEqual(held, measured)
        }

        // And the baseline was held too, so this one divides the whole span
        // since `measured` rather than the sliver since the last burst pass.
        let after = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - after < 600_000_000 { spins += 1 }
        XCTAssertNotEqual(try XCTUnwrap(sampler.sample(sessionPIDs: [me]).cpuPercentBySessionPID[me]),
                          measured)
    }

    /// A process cannot change its environment after `execve`, so the sweep
    /// reads each one once and remembers the answer — including the answer
    /// "there is no marker here", which is nearly every process. Caching only
    /// the markers that were found would leave the cache doing nothing and make
    /// every pass a cold one: 5–8 ms of environment reads against 1–2 ms for
    /// the whole warm pass (§6), on the panel's once-a-second tick.
    func testASecondPassReadsOnlyTheEnvironmentsThatAreNew() {
        let sampler = ProcessSampler()
        _ = sampler.sample(sessionPIDs: [])
        let cold = sampler.lastPassStats()
        XCTAssertEqual(cold.environmentsRead, cold.processes)

        _ = sampler.sample(sessionPIDs: [])
        let warm = sampler.lastPassStats()
        // The machine goes on forking, so this is not zero. It is nowhere near
        // the table's size, and it is the whole size when the cache is broken.
        XCTAssertLessThan(warm.environmentsRead * 4, warm.processes)
    }

    /// `--dump` throws its first snapshot away and reports the second, because
    /// a rate needs a predecessor and a single-pass dump has none (SPEC §2.8).
    ///
    /// Nothing else in the dump depends on the first pass, so deleting it
    /// breaks no other test and the only symptom is a dash down the whole CPU
    /// column — which is also what a quiet machine looks like.
    func testTheDumpThrowsItsFirstSnapshotAway() {
        var passes = 0
        let reported = ConsoleDump.measuredSnapshot { () -> SwitcherSnapshot in
            passes += 1
            return SwitcherSnapshot(openWindows: [],
                                    projects: [SwitcherRow(id: "pass\(passes)",
                                                           kind: .project,
                                                           displayName: "pass\(passes)",
                                                           colorHex: "#000000",
                                                           project: nil,
                                                           window: nil,
                                                           sessions: [],
                                                           state: nil,
                                                           activeSubagents: 0,
                                                           subagentDescriptions: [])],
                                    accessibilityTrusted: true,
                                    generatedAt: Date())
        }
        XCTAssertEqual(passes, 2)
        XCTAssertEqual(reported.projects.first?.id, "pass2")
    }

    /// Evicting the dead and filling in the new are one operation: the tables
    /// are rebuilt from each sweep rather than added to. Added to, they would
    /// grow for as long as the app runs, holding an entry for every process the
    /// machine has ever started.
    ///
    /// Processes are started and killed across the two passes so that there is
    /// something to evict — on a quiet machine two consecutive sweeps can see
    /// exactly the same table, and then a cache that never evicts looks the
    /// same as one that does.
    ///
    /// The question has to be put as a **decrease**, and both halves of the
    /// previous version of it were unable to answer it. `cacheEntries` was
    /// filled from the local the field is built from, one entry per process by
    /// construction, so `cacheEntries == processes` was a tautology and the
    /// mutation "append to the cache instead of rebuilding it" — which makes it
    /// grow for the life of the app — stayed green. And `previousCPU` was not
    /// asked about at all, though the name of the test is plural. Both are now
    /// read back off the fields themselves.
    ///
    /// Forty processes rather than one, because the machine goes on forking
    /// between the sweeps and a decrease of one would be inside that noise.
    /// The pass with them in it has to be a *measured* one, not a held one, or
    /// `previousCPU` is deliberately not rebuilt and the counter half of this
    /// asks nothing — hence the wait past `minimumSampleSeconds`.
    func testTheTablesAreRebuiltFromEachSweepRatherThanAddedTo() throws {
        let sampler = ProcessSampler()
        var processes: [Process] = []
        for _ in 0..<40 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            try process.run()
            processes.append(process)
        }

        _ = sampler.sample(sessionPIDs: [])
        let before = sampler.lastPassStats()
        XCTAssertGreaterThan(before.processes, 40)
        XCTAssertEqual(before.cacheEntries, before.processes)

        for process in processes { process.terminate() }
        // `waitUntilExit` reaps them, so by here the pids are out of the table.
        for process in processes { process.waitUntilExit() }
        Thread.sleep(forTimeInterval: SessionProcesses.minimumSampleSeconds)

        _ = sampler.sample(sessionPIDs: [])
        let after = sampler.lastPassStats()
        XCTAssertLessThan(after.cacheEntries, before.cacheEntries)
        XCTAssertLessThan(after.counterEntries, before.counterEntries)
        XCTAssertEqual(after.cacheEntries, after.processes)
        XCTAssertEqual(after.counterEntries, after.processes)
    }
}
