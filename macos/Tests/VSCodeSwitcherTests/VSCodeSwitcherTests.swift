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

    func testContextLimitSwitchesToOneMillionAboveTwoHundredK() {
        XCTAssertEqual(ClaudeSessions.contextLimitTokens(model: "claude-opus-5", usedTokens: 120_000), 200_000)
        XCTAssertEqual(ClaudeSessions.contextLimitTokens(model: "claude-opus-5", usedTokens: 460_494), 1_000_000)
        XCTAssertEqual(ClaudeSessions.contextLimitTokens(model: "claude-opus-5[1m]", usedTokens: 10_000), 1_000_000)
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
