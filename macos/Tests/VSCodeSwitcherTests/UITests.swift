import AppKit
import XCTest
@testable import VSCodeSwitcher

/// Panel geometry. `frame(on:config:)` takes an `NSScreen`, which no test can
/// build, so the arithmetic lives in `frame(in:config:)` and is checked there.
@MainActor
final class PanelFrameTests: XCTestCase {

    private func config(width: Double = 380, fraction: Double = 0.7) -> Config {
        var config = Config.default
        config.panelWidth = width
        config.panelHeightFraction = fraction
        return config
    }

    func testFlushWithTheLeftEdgeOfTheUsableArea() {
        // The Dock on the left takes 80 pt out of the usable area, and the panel
        // has to start where that area starts — not at the screen edge, which is
        // under the Dock.
        let usable = NSRect(x: 80, y: 0, width: 1630, height: 1068)
        let frame = PanelController.frame(in: usable, config: config())
        XCTAssertEqual(frame.minX, 80)
        XCTAssertEqual(frame.width, 380)
    }

    func testVerticallyCentredOnTheUsableArea() {
        let usable = NSRect(x: 0, y: 0, width: 1710, height: 1068)
        let frame = PanelController.frame(in: usable, config: config())
        XCTAssertEqual(frame.height, 748)          // 1068 * 0.7, rounded
        XCTAssertEqual(frame.midY, usable.midY, accuracy: 1)
        XCTAssertGreaterThan(frame.minY, usable.minY)
        XCTAssertLessThan(frame.maxY, usable.maxY)
    }

    func testHonoursTheMenuBarOffsetOfTheUsableArea() {
        // `visibleFrame` on the main screen starts above the Dock and stops
        // below the menu bar; the panel must stay inside it.
        let usable = NSRect(x: 0, y: 44, width: 1710, height: 1024)
        let frame = PanelController.frame(in: usable, config: config())
        XCTAssertGreaterThanOrEqual(frame.minY, usable.minY)
        XCTAssertLessThanOrEqual(frame.maxY, usable.maxY)
    }

    func testFullHeightFractionCoversTheWholeUsableArea() {
        let usable = NSRect(x: 0, y: 0, width: 1710, height: 1000)
        let frame = PanelController.frame(in: usable, config: config(fraction: 1.0))
        XCTAssertEqual(frame.minY, 0)
        XCTAssertEqual(frame.height, 1000)
    }

    func testGeometryIsIntegral() {
        // Half points make the blurred backdrop and its rounded corners fringe.
        let usable = NSRect(x: 0.5, y: 0.25, width: 1709.5, height: 1067.5)
        let frame = PanelController.frame(in: usable, config: config())
        for value in [frame.minX, frame.minY, frame.width, frame.height] {
            XCTAssertEqual(value, value.rounded(), "\(value) is not integral")
        }
    }
}

/// The metric labels of a row. `shortModelName` and `contextLabel` are the two
/// places where "a bare token count instead of a percentage" is easy to break.
final class RowLabelTests: XCTestCase {

    func testContextPrefersThePercentage() {
        XCTAssertEqual(SwitcherRowView.contextLabel(used: 93953, fraction: 0.46), "46%")
        XCTAssertEqual(SwitcherRowView.contextLabel(used: nil, fraction: 0.5), "50%")
    }

    func testContextFallsBackToTokensWhenTheLimitIsUnknown() {
        // The data layer reports `nil` rather than assuming 200k, and the UI has
        // to keep that honesty: `194k (97%)` for a 1M session was the bug.
        XCTAssertEqual(SwitcherRowView.contextLabel(used: 194_000, fraction: nil), "194k")
        XCTAssertEqual(SwitcherRowView.contextLabel(used: 460_901, fraction: nil), "460k")
        XCTAssertEqual(SwitcherRowView.contextLabel(used: 999, fraction: nil), "999")
    }

    func testContextIsAbsentWhenNothingIsKnown() {
        XCTAssertNil(SwitcherRowView.contextLabel(used: nil, fraction: nil))
        XCTAssertNil(SwitcherRowView.contextLabel(used: 0, fraction: nil))
    }

    func testShortModelNameDropsThePrefixAndTheReleaseDate() {
        XCTAssertEqual(SwitcherRowView.shortModelName("claude-opus-5"), "opus-5")
        XCTAssertEqual(SwitcherRowView.shortModelName("claude-3-5-sonnet-20241022"), "3-5-sonnet")
        XCTAssertEqual(SwitcherRowView.shortModelName("claude-sonnet-4-5-20250929"), "sonnet-4-5")
    }

    func testShortModelNameKeepsTheContextWindowSuffix() {
        // `[1m]` is the difference between a 200k and a 1M session and the only
        // hint the row carries about it.
        XCTAssertEqual(SwitcherRowView.shortModelName("claude-opus-5[1m]"), "opus-5[1m]")
    }

    func testShortModelNameKeepsAnUnknownIdentifierAsIs() {
        XCTAssertEqual(SwitcherRowView.shortModelName("gpt-nonsense"), "gpt-nonsense")
        XCTAssertNil(SwitcherRowView.shortModelName(nil))
        XCTAssertNil(SwitcherRowView.shortModelName(""))
        XCTAssertNil(SwitcherRowView.shortModelName("claude-"))
    }

    func testShortModelNameOnlyStripsATrailingDate() {
        // Eight digits in the middle are part of the name, not a release stamp.
        XCTAssertEqual(SwitcherRowView.shortModelName("claude-20241022-x"), "20241022-x")
    }
}

/// The list cap. It exists to keep the "not open" section short, and it is not
/// allowed to hide a row that has a live session behind it.
@MainActor
final class ProjectLimitTests: XCTestCase {

    private func row(_ name: String, sessions: Int = 0) -> SwitcherRow {
        let session = ClaudeSessionInfo(sessionId: "s-\(name)",
                                        pid: 1,
                                        cwd: "/tmp/\(name)",
                                        name: name,
                                        aiTitle: nil,
                                        lastPrompt: nil,
                                        state: .permission,
                                        stateSource: .hook,
                                        model: nil,
                                        contextUsedTokens: nil,
                                        contextLimitTokens: nil,
                                        activeSubagents: 0,
                                        subagents: [],
                                        lastActivity: nil)
        return SwitcherRow(id: "project:/tmp/\(name)",
                           kind: .project,
                           displayName: name,
                           colorHex: "#000000",
                           project: nil,
                           window: nil,
                           sessions: Array(repeating: session, count: sessions),
                           state: sessions > 0 ? .permission : nil,
                           stateCount: sessions,
                           activeSubagents: 0,
                           subagentDescriptions: [],
                           chatTopic: nil,
                           model: nil,
                           contextUsedTokens: nil,
                           contextLimitTokens: nil,
                           lastActivity: nil)
    }

    func testCapsTheSessionLessRows() {
        let rows = (0..<50).map { row("p\($0)") }
        XCTAssertEqual(SwitcherViewModel.limited(rows, to: 30).count, 30)
        XCTAssertEqual(SwitcherViewModel.limited(rows, to: 30).first?.displayName, "p0")
        XCTAssertEqual(SwitcherViewModel.limited(rows, to: 30).last?.displayName, "p29")
    }

    func testKeepsEveryRowWithASessionHoweverFarDownTheList() {
        // The orphan `cwd:` rows are appended at the very end of
        // `snapshot.projects`, so with 92 project rows a flat `prefix(30)` hid
        // all of them, always. So did an old directory mtime for a project whose
        // agent is sitting on a permission dialog.
        var rows = (0..<92).map { row("p\($0)") }
        rows.append(row("orphan", sessions: 2))
        rows.insert(row("stale-but-busy", sessions: 1), at: 60)

        let limited = SwitcherViewModel.limited(rows, to: 30)
        XCTAssertTrue(limited.contains { $0.displayName == "orphan" })
        XCTAssertTrue(limited.contains { $0.displayName == "stale-but-busy" })
        XCTAssertEqual(limited.filter { $0.sessions.isEmpty }.count, 30)
        XCTAssertEqual(limited.count, 32)
    }

    func testPreservesTheOriginalOrder() {
        let rows = [row("a"), row("live", sessions: 1), row("b"), row("c")]
        XCTAssertEqual(SwitcherViewModel.limited(rows, to: 2).map(\.displayName),
                       ["a", "live", "b"])
    }

    func testAZeroLimitStillShowsTheLiveRows() {
        let rows = [row("a"), row("live", sessions: 1)]
        XCTAssertEqual(SwitcherViewModel.limited(rows, to: 0).map(\.displayName), ["live"])
    }
}

/// The frozen order of the "open windows" section. Clicking a row raises that
/// window, and the z-order the data layer reports would otherwise reshuffle the
/// list under the pointer a second later.
@MainActor
final class WindowOrderTests: XCTestCase {

    private func rows(_ ids: [String]) -> [SwitcherRow] {
        ids.map { id in
            SwitcherRow(id: id,
                        kind: .window,
                        displayName: id,
                        colorHex: "#000000",
                        project: nil,
                        window: nil,
                        sessions: [],
                        state: nil,
                        stateCount: 0,
                        activeSubagents: 0,
                        subagentDescriptions: [],
                        chatTopic: nil,
                        model: nil,
                        contextUsedTokens: nil,
                        contextLimitTokens: nil,
                        lastActivity: nil)
        }
    }

    func testARaisedWindowStaysWhereItWas() {
        let frozen = ["a", "b", "c", "d"]
        // The user clicked "c"; the next snapshot has it in front.
        let reshuffled = rows(["c", "a", "b", "d"])
        XCTAssertEqual(SwitcherViewModel.ordered(reshuffled, by: frozen).map(\.id),
                       ["a", "b", "c", "d"])
    }

    func testAClosedWindowLeavesNoHole() {
        let frozen = ["a", "b", "c"]
        XCTAssertEqual(SwitcherViewModel.ordered(rows(["c", "a"]), by: frozen).map(\.id),
                       ["a", "c"])
    }

    func testAWindowOpenedWhileThePanelIsUpGoesToTheEnd() {
        let frozen = ["a", "b"]
        // z-order puts the new window first; the frozen section must not shift.
        XCTAssertEqual(SwitcherViewModel.ordered(rows(["new", "b", "a"]), by: frozen).map(\.id),
                       ["a", "b", "new"])
    }

    func testSeveralNewWindowsKeepTheirRelativeOrder() {
        XCTAssertEqual(SwitcherViewModel.ordered(rows(["x", "y", "a"]), by: ["a"]).map(\.id),
                       ["a", "x", "y"])
    }

    func testWithoutAFrozenOrderTheZOrderIsUsedAsIs() {
        XCTAssertEqual(SwitcherViewModel.ordered(rows(["c", "b", "a"]), by: []).map(\.id),
                       ["c", "b", "a"])
    }

    // MARK: Folding a fresh z-order into a frozen one

    /// The re-freeze lands just as the panel finishes sliding in, with the
    /// pointer already on its way to a row, so it may only add. Taking the fresh
    /// order whole moved every window raised since the cached snapshot was read
    /// — here "c" — for the sake of the one window that was genuinely missing.
    func testOnlyTheUnknownWindowsAreWovenIn() {
        XCTAssertEqual(SwitcherViewModel.merged(["a", "b", "c"], with: ["new", "c", "a", "b"]),
                       ["new", "a", "b", "c"])
    }

    /// A newcomer goes to the frozen slot of the closest window in front of it,
    /// which for the frontmost window means the very top — that is the whole
    /// point of redoing the freeze.
    func testANewWindowLandsBehindTheWindowInFrontOfIt() {
        XCTAssertEqual(SwitcherViewModel.merged(["a", "b"], with: ["a", "new", "b"]),
                       ["a", "new", "b"])
        XCTAssertEqual(SwitcherViewModel.merged(["a", "b"], with: ["new", "a", "b"]),
                       ["new", "a", "b"])
    }

    func testSeveralNewWindowsKeepTheirZOrderAmongThemselves() {
        XCTAssertEqual(SwitcherViewModel.merged(["a"], with: ["x", "y", "a"]), ["x", "y", "a"])
    }

    func testAnEmptyFrozenOrderTakesTheZOrderWhole() {
        XCTAssertEqual(SwitcherViewModel.merged([], with: ["c", "a", "b"]), ["c", "a", "b"])
    }

    /// A window that closed between the two snapshots keeps its slot in the
    /// order; `ordered` drops it because no row carries that id any more, and
    /// nothing below it moves.
    func testAWindowThatWentAwayDoesNotShiftTheRest() {
        XCTAssertEqual(SwitcherViewModel.merged(["a", "b", "c"], with: ["a", "c"]),
                       ["a", "b", "c"])
    }

    // MARK: When the order is taken

    private func snapshot(_ ids: [String], generatedAt: Date) -> SwitcherSnapshot {
        SwitcherSnapshot(openWindows: rows(ids),
                         projects: [],
                         accessibilityTrusted: true,
                         generatedAt: generatedAt)
    }

    private func projectRow(_ id: String) -> SwitcherRow {
        var row = rows([id])[0]
        row.kind = .project
        return row
    }

    private func windowIDs(_ model: SwitcherViewModel) -> [String] {
        model.sections.first { $0.title == "Открытые окна" }?.rows.map(\.id) ?? []
    }

    /// The cache the panel opens on is up to two seconds old and no watcher
    /// tells it about a new editor window, so a window opened just before the
    /// panel was summoned is missing from the frozen order — and "not in the
    /// order" means "appended at the end", which is exactly where the newest
    /// window must not be. The freeze is therefore redone on the first snapshot
    /// read after the show.
    func testTheOrderIsTakenFromTheFirstSnapshotReadAfterTheShow() {
        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(["a", "b"], generatedAt: Date()))
        model.panelDidShow()

        model.update(snapshot: snapshot(["new", "a", "b"], generatedAt: Date()))
        XCTAssertEqual(windowIDs(model), ["new", "a", "b"])

        // And it is frozen from then on: the click that raises "b" must not move it.
        model.update(snapshot: snapshot(["b", "new", "a"], generatedAt: Date()))
        XCTAssertEqual(windowIDs(model), ["new", "a", "b"])
    }

    /// A snapshot already in flight when the panel appeared carries pre-show
    /// data, so it is not the one to freeze on: until one that was read after
    /// the show arrives, a window the frozen order has never seen stays at the
    /// end, where every newcomer goes.
    func testASnapshotReadBeforeTheShowDoesNotFreezeTheOrder() {
        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(["a", "b"], generatedAt: Date()))
        model.panelDidShow()

        model.update(snapshot: snapshot(["new", "a", "b"], generatedAt: .distantPast))
        XCTAssertEqual(windowIDs(model), ["a", "b", "new"])
        model.update(snapshot: snapshot(["new", "a", "b"], generatedAt: Date()))
        XCTAssertEqual(windowIDs(model), ["new", "a", "b"])
    }

    /// The re-freeze may only add. It lands just as the panel finishes sliding
    /// in, so re-sorting windows the frozen order already knows — here "c",
    /// raised in the two seconds the cached snapshot was stale for — shifted
    /// every row under a pointer already on its way to one.
    func testTheRefreezeDoesNotResortWindowsItAlreadyKnows() {
        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(["a", "b", "c"], generatedAt: Date()))
        model.panelDidShow()

        model.update(snapshot: snapshot(["c", "a", "b"], generatedAt: Date()))
        XCTAssertEqual(windowIDs(model), ["a", "b", "c"])
    }

    /// Clicking raises a window, and the snapshot that follows reports the new
    /// z-order. It must not be mistaken for the fresh order to freeze on.
    func testAClickSettlesTheOrderStraightAway() {
        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(["a", "b"], generatedAt: Date()))
        model.panelDidShow()

        model.rowActivated(rows(["b"])[0])
        model.update(snapshot: snapshot(["b", "a"], generatedAt: Date()))
        XCTAssertEqual(windowIDs(model), ["a", "b"])
    }

    /// The panel can open before the very first snapshot has landed. The frozen
    /// order was empty then, `ordered` fell through to the raw z-order, and the
    /// list reshuffled after every click for the rest of that appearance.
    func testAPanelShownBeforeTheFirstSnapshotStillFreezes() {
        let model = SwitcherViewModel()
        model.panelDidShow()

        model.update(snapshot: snapshot(["a", "b", "c"], generatedAt: Date()))
        model.update(snapshot: snapshot(["c", "a", "b"], generatedAt: Date()))
        XCTAssertEqual(windowIDs(model), ["a", "b", "c"])
    }

    /// The same first appearance, but the click comes before the re-freeze. It
    /// has to write the order down, not merely cancel the wait: cancelling alone
    /// left `windowOrder` empty, `ordered` fell through to the raw z-order, and
    /// the list jumped after every click for the rest of that appearance —
    /// exactly the defect the freeze exists for.
    func testAClickBeforeTheFirstFreshSnapshotFixesTheOrder() {
        let model = SwitcherViewModel()
        model.panelDidShow()
        // Read before the show, so it is not the one to freeze on.
        model.update(snapshot: snapshot(["a", "b", "c"], generatedAt: .distantPast))

        model.rowActivated(rows(["b"])[0])
        model.update(snapshot: snapshot(["b", "a", "c"], generatedAt: Date()))
        XCTAssertEqual(windowIDs(model), ["a", "b", "c"])
    }

    /// Windows opened from a panel that stays up are frozen too, once they show
    /// up in a snapshot. Until they were, their place among themselves came from
    /// live z-order: two projects clicked in a row put two new rows at the
    /// bottom, and clicking the lower one raised it, so the very next snapshot
    /// swapped the pair under the pointer.
    func testAWindowOpenedWhileThePanelIsUpIsFrozenOnceItAppears() {
        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(["a"], generatedAt: Date()))
        model.panelDidShow()
        model.update(snapshot: snapshot(["a"], generatedAt: Date()))

        // Two projects clicked: the newest window is in front of the other.
        model.update(snapshot: snapshot(["w2", "w1", "a"], generatedAt: Date()))
        XCTAssertEqual(windowIDs(model), ["a", "w2", "w1"])

        // Clicking the bottom row raises it, and the rows must stay put.
        model.rowActivated(rows(["w1"])[0])
        model.update(snapshot: snapshot(["w1", "w2", "a"], generatedAt: Date()))
        XCTAssertEqual(windowIDs(model), ["a", "w2", "w1"])
    }

    /// The very first use of the app: no editor window exists — it is closed, or
    /// the Accessibility grant has only just been given — so the panel shows the
    /// "Проекты" section alone and the first click is a project. There was no
    /// order to settle then, but the click cancelled the pending re-freeze all
    /// the same, and it never came: the windows opened from the panel were laid
    /// out by live z-order for the rest of that appearance, reshuffling under the
    /// pointer at every click.
    func testAClickWithNoWindowsToSettleKeepsTheReFreezePending() {
        let model = SwitcherViewModel()
        model.panelDidShow()
        model.rowActivated(projectRow("project:/tmp/foo"))

        model.update(snapshot: snapshot(["a", "b", "c"], generatedAt: Date()))
        model.update(snapshot: snapshot(["c", "a", "b"], generatedAt: Date()))
        XCTAssertEqual(windowIDs(model), ["a", "b", "c"])
    }
}

/// Clicking an orphan row. It has neither a window nor an indexed project, and
/// used to do nothing at all while looking exactly as clickable as its
/// neighbours.
@MainActor
final class SyntheticProjectTests: XCTestCase {

    private func orphanRow(cwd: String) -> SwitcherRow {
        let session = ClaudeSessionInfo(sessionId: "s",
                                        pid: 1,
                                        cwd: cwd,
                                        name: nil,
                                        aiTitle: nil,
                                        lastPrompt: nil,
                                        state: .working,
                                        stateSource: .hook,
                                        model: nil,
                                        contextUsedTokens: nil,
                                        contextLimitTokens: nil,
                                        activeSubagents: 0,
                                        subagents: [],
                                        lastActivity: nil)
        return SwitcherRow(id: "cwd:\(cwd)",
                           kind: .project,
                           displayName: (cwd as NSString).lastPathComponent,
                           colorHex: "#123456",
                           project: nil,
                           window: nil,
                           sessions: [session],
                           state: .working,
                           stateCount: 1,
                           activeSubagents: 0,
                           subagentDescriptions: [],
                           chatTopic: nil,
                           model: nil,
                           contextUsedTokens: nil,
                           contextLimitTokens: nil,
                           lastActivity: nil)
    }

    func testOrphanRowOpensItsWorkingDirectoryAsAFolder() throws {
        let row = orphanRow(cwd: "/private/tmp/scratch/work")
        let project = try XCTUnwrap(PanelController.syntheticProject(for: row))
        XCTAssertEqual(project.path, "/private/tmp/scratch/work")
        XCTAssertEqual(project.displayName, "work")
        XCTAssertEqual(project.rootName, "work")
        // No workspace file, so `openProject` takes its "open the folder" branch.
        XCTAssertNil(project.workspaceFile)
        XCTAssertEqual(project.colorHex, row.colorHex)
    }

    func testRowsThatAlreadyKnowWhatToOpenAreLeftAlone() {
        var row = orphanRow(cwd: "/tmp/work")
        row.project = ProjectInfo(path: "/tmp/real",
                                  displayName: "real",
                                  rootName: "real",
                                  colorHex: "#000000",
                                  workspaceFile: nil,
                                  mtime: .distantPast)
        XCTAssertNil(PanelController.syntheticProject(for: row))

        var windowRow = orphanRow(cwd: "/tmp/work")
        windowRow.project = nil
        windowRow.window = VSCodeWindowInfo(pid: 1,
                                            windowIndex: 0,
                                            windowNumber: 7,
                                            title: "t",
                                            rootName: "t",
                                            chatTopicPrefix: nil,
                                            isWorkspace: false,
                                            isMinimized: false)
        XCTAssertNil(PanelController.syntheticProject(for: windowRow))
    }

    func testASessionLessRowHasNothingToOpen() {
        var row = orphanRow(cwd: "/tmp/work")
        row.sessions = []
        XCTAssertNil(PanelController.syntheticProject(for: row))
    }
}

/// The pulse means "working" (§3), so it has to follow the state rather than the
/// lifetime of the view that draws it.
final class StateBadgeTests: XCTestCase {
    func testOnlyWorkAndPermissionAnimate() {
        XCTAssertTrue(StateBadge.animates(.working))
        XCTAssertTrue(StateBadge.animates(.permission))
        XCTAssertFalse(StateBadge.animates(.waiting))
        XCTAssertFalse(StateBadge.animates(.idle))
    }

    func testEveryStateHasItsOwnColourAndLabel() {
        let labels = Set(AgentState.allCases.map { StateBadge.label(for: $0) })
        XCTAssertEqual(labels.count, AgentState.allCases.count)
    }

    /// `repeatForever` does not stop when the panel is ordered out, so SwiftUI
    /// went on laying the whole list out and rendering it once per display cycle
    /// for a pulse nobody could see — 13.6% of a core against 2.0%. A `nil` key
    /// is what ends the pulse, and the panel's visibility is half of that key.
    @MainActor
    func testThePulseOnlyRunsWhileThePanelIsOnScreen() {
        XCTAssertEqual(StateBadge(state: .working, count: 1, panelVisible: true).pulseState,
                       .working)
        XCTAssertNil(StateBadge(state: .working, count: 1, panelVisible: false).pulseState)
        XCTAssertNil(StateBadge(state: .waiting, count: 1, panelVisible: true).pulseState)
    }

    /// And the flag itself follows the panel.
    @MainActor
    func testTheVisibilityFlagFollowsTheShowAndTheHide() {
        let model = SwitcherViewModel()
        XCTAssertFalse(model.panelVisible)
        model.panelDidShow()
        XCTAssertTrue(model.panelVisible)
        model.panelDidHide()
        XCTAssertFalse(model.panelVisible)
    }
}
