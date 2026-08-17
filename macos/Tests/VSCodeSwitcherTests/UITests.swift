import AppKit
import SwiftUI
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

/// The "projects" section lists every project, in the order the data layer
/// ranked them. It used to be cut at thirty rows, which made it a top-of-list
/// rather than a list.
@MainActor
final class ProjectSectionTests: XCTestCase {

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
                           activeSubagents: 0,
                           subagentDescriptions: [],
                           chatTopic: nil,
                           model: nil,
                           contextUsedTokens: nil,
                           contextLimitTokens: nil,
                           lastActivity: nil)
    }

    private func snapshot(_ rows: [SwitcherRow]) -> SwitcherSnapshot {
        SwitcherSnapshot(openWindows: [], projects: rows, accessibilityTrusted: true, generatedAt: Date())
    }

    func testListsEveryProject() {
        // 92 rows is the real count on this machine, and the section header
        // shows it: the cap made the number a lie as well as the list.
        var rows = (0..<92).map { row("p\($0)") }
        rows.append(row("orphan", sessions: 2))

        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(rows))

        let section = model.sections.first { $0.title == "Projects" }
        XCTAssertEqual(section?.rows.count, 93)
        XCTAssertEqual(section?.rows.map(\.displayName), rows.map(\.displayName))
    }

    func testKeepsTheOrderTheDataLayerRanked() {
        let rows = [row("a"), row("live", sessions: 1), row("b"), row("c")]
        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(rows))
        XCTAssertEqual(model.sections.first?.rows.map(\.displayName), ["a", "live", "b", "c"])
    }

    func testSearchStillSpansEveryProject() {
        let rows = (0..<92).map { row("p\($0)") } + [row("needle")]
        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(rows))
        model.query = "needle"
        XCTAssertEqual(model.sections.first?.rows.map(\.displayName), ["needle"])
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

    /// No freeze at all — `nil`, not an empty list, which means an order frozen
    /// while no window was open and is a freeze like any other.
    func testWithoutAFrozenOrderTheZOrderIsUsedAsIs() {
        XCTAssertEqual(SwitcherViewModel.ordered(rows(["c", "b", "a"]), by: nil).map(\.id),
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

    /// The window in front of the newcomer can be the oldest one in the frozen
    /// order — open a window, click an old one, summon the panel — and then
    /// "just after the anchor" is the very bottom of the list, where the window
    /// most likely to be wanted must not go. The closest known window behind it
    /// anchors the insertion instead.
    func testTheAnchorInFrontDoesNotSendANewWindowToTheBottom() {
        XCTAssertEqual(SwitcherViewModel.merged(["a", "b", "c"], with: ["c", "new", "a", "b"]),
                       ["new", "a", "b", "c"])
    }

    /// The two sides can disagree, and this is the price that was accepted for
    /// keeping the second one: the newcomer trails `c` (whose slot is the last)
    /// and leads `a` (whose slot is the first), so it goes above `a` — and thus
    /// above `b` and `c`, which currently outrank it. One layout on one
    /// appearance, and the next show re-freezes from scratch.
    ///
    /// A twin of the case above rather than a second net: measured by mutation,
    /// every break it catches that one catches too, and the reverse does not
    /// hold (`.first` → `.last` fails only the neighbour). It is here as the
    /// executable form of the example in `merged`'s doc comment — the awkward
    /// half of the bargain, written down so a later repair of one side cannot
    /// quietly change what was agreed.
    func testTheTwoSidesDisagreeAndTheFrontOneWins() {
        XCTAssertEqual(SwitcherViewModel.merged(["a", "b", "c"], with: ["b", "c", "new", "a"]),
                       ["new", "a", "b", "c"])
    }

    /// With nothing known behind it, the end is where the newcomer belongs —
    /// that is the plain "opened while the panel was up" case.
    func testANewWindowBehindEverythingKnownStillGoesToTheEnd() {
        XCTAssertEqual(SwitcherViewModel.merged(["a", "b"], with: ["b", "new"]),
                       ["a", "b", "new"])
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
        model.sections.first { $0.title == "Open windows" }?.rows.map(\.id) ?? []
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

    /// The freeze now holds against a second source of movement. The data layer
    /// orders the windows by the last message written in each, so a row moves
    /// when an agent says something — no click needed — and that is every bit as
    /// unwelcome under a pointer already travelling towards a row.
    func testTheOrderHoldsWhenAnAgentReordersTheWindows() {
        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(["a", "b", "c"], generatedAt: Date()))
        model.panelDidShow()
        model.update(snapshot: snapshot(["a", "b", "c"], generatedAt: Date()))

        // An agent in "c" answers: the data layer now puts it first.
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
    /// "Projects" section alone and the first click is a project. There was no
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

    /// The same first appearance, but the fresh snapshot arrives before the
    /// click — the usual case, since it lands while the panel is still sliding
    /// in. It freezes an *empty* order, and that has to count as frozen: told
    /// apart from "nothing frozen yet" by emptiness alone, it switched the rule
    /// that records newcomers off for the rest of the appearance, so every
    /// window opened from the panel was laid out by live z-order and clicking
    /// one of them swapped the rows under the pointer.
    func testAnOrderFrozenWithNoWindowsStillTakesInTheNewOnes() {
        let model = SwitcherViewModel()
        model.panelDidShow()
        model.update(snapshot: snapshot([], generatedAt: Date()))

        // Two projects clicked in a row, each opening a window in front of the
        // other; both rows appear at the end of the frozen order, in that order.
        model.rowActivated(projectRow("project:/tmp/one"))
        model.update(snapshot: snapshot(["w1"], generatedAt: Date()))
        model.rowActivated(projectRow("project:/tmp/two"))
        model.update(snapshot: snapshot(["w2", "w1"], generatedAt: Date()))
        XCTAssertEqual(windowIDs(model), ["w1", "w2"])

        // Clicking the upper row raises it, and the rows must stay put.
        model.rowActivated(rows(["w1"])[0])
        model.update(snapshot: snapshot(["w1", "w2"], generatedAt: Date()))
        XCTAssertEqual(windowIDs(model), ["w1", "w2"])
    }
}

/// The frozen order of the "projects" section — the same freeze as the windows
/// above, for the same reason. That section is ordered by the time of the last
/// session (SPEC §2.2.1), which is the mtime of a transcript a working agent
/// moves several times a minute, so its rows travelled under the pointer once a
/// second: two projects with no editor window and an agent writing in each is
/// the ordinary shape of "Accessibility not granted", where every live agent is
/// in this section.
@MainActor
final class ProjectOrderTests: XCTestCase {

    private func rows(_ ids: [String]) -> [SwitcherRow] {
        ids.map { id in
            SwitcherRow(id: id,
                        kind: .project,
                        displayName: id,
                        colorHex: "#000000",
                        project: nil,
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

    private func snapshot(_ ids: [String], generatedAt: Date) -> SwitcherSnapshot {
        SwitcherSnapshot(openWindows: [],
                         projects: rows(ids),
                         accessibilityTrusted: true,
                         generatedAt: generatedAt)
    }

    private func projectIDs(_ model: SwitcherViewModel) -> [String] {
        model.sections.first { $0.title == "Projects" }?.rows.map(\.id) ?? []
    }

    /// The panel is up and an agent writes a line in project "c": its transcript
    /// becomes the newest, the data layer puts it first, and the row must not
    /// move — once a second, under a pointer already aimed at a row.
    func testTheOrderHoldsWhenASessionIsWrittenTo() {
        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(["project:/a", "project:/b", "project:/c"], generatedAt: Date()))
        model.panelDidShow()
        model.update(snapshot: snapshot(["project:/a", "project:/b", "project:/c"], generatedAt: Date()))

        model.update(snapshot: snapshot(["project:/c", "project:/a", "project:/b"], generatedAt: Date()))
        XCTAssertEqual(projectIDs(model), ["project:/a", "project:/b", "project:/c"])
        // And again a second later, the other way round.
        model.update(snapshot: snapshot(["project:/b", "project:/c", "project:/a"], generatedAt: Date()))
        XCTAssertEqual(projectIDs(model), ["project:/a", "project:/b", "project:/c"])
    }

    /// A row that turns up while the panel is up is written into the frozen
    /// order at the place the fresh ranking gives it — a project whose window has
    /// just been closed comes back into this section where its last session puts
    /// it, and stays there. Appending it instead, as the windows section does,
    /// would put it at the bottom of a hundred rows.
    func testAProjectThatAppearsIsWovenInWhereTheRankingPutsIt() {
        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(["project:/a", "project:/b", "project:/c"], generatedAt: Date()))
        model.panelDidShow()
        model.update(snapshot: snapshot(["project:/a", "project:/b", "project:/c"], generatedAt: Date()))

        model.update(snapshot: snapshot(["project:/a", "project:/new", "project:/b", "project:/c"],
                                        generatedAt: Date()))
        XCTAssertEqual(projectIDs(model),
                       ["project:/a", "project:/new", "project:/b", "project:/c"])
        // Frozen from then on: the newcomer keeps its slot when the ranking moves.
        model.update(snapshot: snapshot(["project:/c", "project:/a", "project:/new", "project:/b"],
                                        generatedAt: Date()))
        XCTAssertEqual(projectIDs(model),
                       ["project:/a", "project:/new", "project:/b", "project:/c"])
    }

    /// An orphan `cwd:` row is a live agent running outside the scan roots, and
    /// it belongs at the head of the section (SPEC §2.2.1) — that is where the
    /// data layer puts it and where the freeze has to keep it. Appending
    /// newcomers, which is the rule for windows, would drop an agent that has
    /// just started to the bottom of the list at the moment it is wanted most.
    func testAnOrphanThatAppearsGoesToTheHeadOfTheSection() {
        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(["project:/a", "project:/b"], generatedAt: Date()))
        model.panelDidShow()
        model.update(snapshot: snapshot(["project:/a", "project:/b"], generatedAt: Date()))

        model.update(snapshot: snapshot(["cwd:/private/tmp/scratch", "project:/a", "project:/b"],
                                        generatedAt: Date()))
        XCTAssertEqual(projectIDs(model), ["cwd:/private/tmp/scratch", "project:/a", "project:/b"])
    }

    /// The newcomer arrives with the *first* snapshot after the show — the state
    /// the two tests above never reach, because each of them burns a snapshot
    /// first and so exercises the standing rule instead. For the projects that
    /// first snapshot is also where the re-freeze would happen, and this is the
    /// only test that would notice if weaving newcomers in were left to a
    /// separate line of it.
    func testANewcomerInTheFirstSnapshotAfterTheShowIsWovenInToo() {
        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(["project:/a", "project:/b"], generatedAt: Date()))
        model.panelDidShow()

        model.update(snapshot: snapshot(["cwd:/private/tmp/x", "project:/a", "project:/b"],
                                        generatedAt: Date()))
        XCTAssertEqual(projectIDs(model), ["cwd:/private/tmp/x", "project:/a", "project:/b"])
    }

    /// And that first snapshot is routinely one read *before* the show: the store
    /// serves a cache up to two seconds old and no watcher tells it an agent has
    /// started, so an agent a second older than the panel is missing from the
    /// order frozen at the show and turns up in a stale snapshot. Held back until
    /// a snapshot read after the show — around a second of polling, plus 40–180 ms
    /// of assembly — the row fell through to the tail `ordered` appends, which
    /// for an orphan `cwd:` row is the one place it must never be (SPEC §2.2.1).
    func testAnOrphanFromAStaleSnapshotStillGoesToTheHead() {
        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(["project:/a", "project:/b"], generatedAt: Date()))
        model.panelDidShow()

        let readBeforeTheShow = Date().addingTimeInterval(-5)
        model.update(snapshot: snapshot(["cwd:/private/tmp/x", "project:/a", "project:/b"],
                                        generatedAt: readBeforeTheShow))
        XCTAssertEqual(projectIDs(model), ["cwd:/private/tmp/x", "project:/a", "project:/b"])

        // And it keeps that place once the fresh snapshot arrives, rather than
        // being re-frozen into a different one.
        model.update(snapshot: snapshot(["cwd:/private/tmp/x", "project:/a", "project:/b"],
                                        generatedAt: Date()))
        XCTAssertEqual(projectIDs(model), ["cwd:/private/tmp/x", "project:/a", "project:/b"])
    }

    /// The freeze is taken afresh at every show, so the list is ranked again —
    /// the project worked in last on top — as soon as the panel is reopened.
    func testReopeningThePanelTakesTheFreshOrder() {
        let model = SwitcherViewModel()
        model.update(snapshot: snapshot(["project:/a", "project:/b", "project:/c"], generatedAt: Date()))
        model.panelDidShow()
        model.update(snapshot: snapshot(["project:/c", "project:/a", "project:/b"], generatedAt: Date()))
        XCTAssertEqual(projectIDs(model), ["project:/a", "project:/b", "project:/c"])

        model.panelDidHide()
        model.panelDidShow()
        model.update(snapshot: snapshot(["project:/c", "project:/a", "project:/b"], generatedAt: Date()))
        XCTAssertEqual(projectIDs(model), ["project:/c", "project:/a", "project:/b"])
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

/// The pulse means "something is moving" (§3), so it has to follow the status
/// rather than the lifetime of the view that draws it.
final class StatusBadgeTests: XCTestCase {
    /// Only movement pulses. Both `blocked` and `done` hold for as long as the
    /// user takes to come back, and a list where half the rows blink is a list
    /// nothing stands out in — the user chose a separate glyph over a second
    /// blinking state.
    func testOnlyActivityAnimates() {
        XCTAssertTrue(StatusBadge.animates(.active))
        XCTAssertFalse(StatusBadge.animates(.blocked))
        XCTAssertFalse(StatusBadge.animates(.done))
        XCTAssertFalse(StatusBadge.animates(.asleep))
    }

    /// Each of the four has to be told apart by shape alone: the colour is a
    /// second channel, not the only one.
    func testEveryStatusHasItsOwnSymbol() {
        let symbols = RowStatus.allCases.map { StatusBadge.symbol(for: $0) }
        XCTAssertEqual(Set(symbols).count, RowStatus.allCases.count)
        XCTAssertFalse(symbols.contains(where: \.isEmpty))
    }

    /// And the point of splitting the fold: a stuck chat does not look like a
    /// finished one. Both the shape and the colour differ.
    func testBeingStuckLooksNothingLikeHavingFinished() {
        XCTAssertNotEqual(StatusBadge.symbol(for: .blocked), StatusBadge.symbol(for: .done))
        XCTAssertNotEqual(StatusBadge.color(for: .blocked), StatusBadge.color(for: .done))
    }

    /// A name SF Symbols does not know draws nothing at all — an empty slot
    /// where the one indicator of the row should be. There is no compiler check
    /// for these strings.
    ///
    /// Every symbol the app names anywhere goes through here, not just the row's
    /// four: the popover's failure mark is the same kind of unchecked string,
    /// and a picture drawing nothing at all is the same silent failure wherever
    /// it happens. The menu bar icon names none — it is drawn, not symbolic,
    /// and its app glyph is gone.
    func testEverySymbolNameActuallyResolves() {
        let names = RowStatus.allCases.map { StatusBadge.symbol(for: $0) }
            + [UsagePopoverView.failureSymbolName]
        for name in names {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil),
                            "\(name) is not an SF Symbol")
        }
    }

    /// Every chat state still has its own word, because the tooltip is where
    /// the fold is undone.
    func testEveryStateHasItsOwnWord() {
        let labels = Set(AgentState.allCases.map { SwitcherRowView.stateLabel(for: $0) })
        XCTAssertEqual(labels.count, AgentState.allCases.count)
    }

    /// `repeatForever` does not stop when the panel is ordered out, so SwiftUI
    /// went on laying the whole list out and rendering it once per display cycle
    /// for a pulse nobody could see — 13.6% of a core against 2.0%. A `nil` key
    /// is what ends the pulse, and the panel's visibility is half of that key.
    @MainActor
    func testThePulseOnlyRunsWhileThePanelIsOnScreen() {
        XCTAssertEqual(StatusBadge(status: .active, panelVisible: true).pulseState, .active)
        XCTAssertNil(StatusBadge(status: .active, panelVisible: false).pulseState)
        XCTAssertNil(StatusBadge(status: .blocked, panelVisible: true).pulseState)
        XCTAssertNil(StatusBadge(status: .done, panelVisible: true).pulseState)
        // An empty slot has nothing to pulse either.
        XCTAssertNil(StatusBadge(status: nil, panelVisible: true).pulseState)
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

/// The title line carries the count now, in the wording the user asked for.
@MainActor
final class RowTitleTests: XCTestCase {

    private func row(working: Int, subagents: Int, name: String = "vscode-switcher") -> SwitcherRow {
        var sessions = (0..<max(working, 1)).map {
            TestFixtures.session(id: "s\($0)", cwd: "/tmp/p", state: working > 0 ? .working : .idle)
        }
        sessions[0].activeSubagents = subagents
        let aggregate = DataSource.aggregate(sessions)
        return SwitcherRow(id: "project:/tmp/p",
                           kind: .project,
                           displayName: name,
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

    /// Verbatim, brackets and all: `vscode-switcher (agents: 5)`.
    func testTheCountReadsTheWayItWasAskedFor() {
        XCTAssertEqual(SwitcherRowView.countLabel(for: row(working: 1, subagents: 4)), "(agents: 5)")
        XCTAssertEqual(SwitcherRowView.countLabel(for: row(working: 1, subagents: 0)), "(agents: 1)")
    }

    /// At zero there are no brackets at all — just the name. Ninety-odd rows of
    /// the "projects" section have never run an agent, and `(agents: 0)` on
    /// every one of them would be the noise the empty badge slot already avoids.
    func testNothingRunningMeansNoBracketsAtAll() {
        XCTAssertNil(SwitcherRowView.countLabel(for: row(working: 0, subagents: 0)))
    }

    /// The same pair in `--dump`, where the column has a width to keep to: the
    /// name is cut to what the brackets leave of the cell, so the cell comes out
    /// exactly as wide as its column and the count comes out whole.
    ///
    /// The rows that have a count are the ones a dump of this machine may or may
    /// not contain — an orphan session, or a project with a live session and no
    /// window — so this cannot be left to be noticed in the output. Budgeting
    /// the name to the full 34 first and appending the brackets afterwards makes
    /// the cell as wide as the two together — 48 characters for the row below —
    /// and `column` pads without cutting: every column to the right of it
    /// shifts, on the rows where name and brackets do not fit in 34 together and
    /// nowhere else.
    func testTheDumpCellKeepsTheCountWholeInsideItsColumn() {
        let longest = "wirenboard/node-red-contrib-wirenboard"
        let cell = ConsoleDump.nameCell(for: row(working: 1, subagents: 122, name: longest), width: 34)
        XCTAssertEqual(cell.count, 34, "the cell is not the width of its column: '\(cell)'")
        XCTAssertTrue(cell.hasSuffix(" (agents: 123)"), "the count did not survive whole: '\(cell)'")
        // And the name is what was cut, visibly, by `shorten`.
        XCTAssertTrue(cell.hasPrefix("wirenboard/node-red\u{2026}"), "'\(cell)'")
    }

    /// The age of the last session, which is the key this section is sorted by.
    /// Whole days — what the dump printed while the count was the key — cannot
    /// explain the order they are printed in: the top of a live list is several
    /// rows of "last 0d ago", and the dump exists to verify the ranking.
    func testTheDumpPrintsTheLastSessionFinelyEnoughToExplainTheOrder() {
        let now = Date()
        XCTAssertEqual(ConsoleDump.age(of: now.addingTimeInterval(-3 * 3600 - 754), now: now),
                       "3h 12m 34s")
        XCTAssertEqual(ConsoleDump.age(of: now.addingTimeInterval(-47), now: now), "0h 00m 47s")
        // Beyond a day the days are what the eye wants, with the hours kept so
        // two projects last worked in on the same day are still told apart.
        XCTAssertEqual(ConsoleDump.age(of: now.addingTimeInterval(-8 * 86_400 - 5 * 3600), now: now),
                       "8d 5h")
    }
}

/// The requirement this whole round exists for, measured rather than eyeballed:
/// the indicator keeps the same place in every row, whatever else the row holds.
/// Now that the count sits in the title line instead of a slot of its own, there
/// is a second half to it — the count has to survive a name too long for the
/// row, and it still may not nudge the indicator.
///
/// `StatusBadge` and `SwitcherRowView` are rendered for real — what the panel
/// draws, not a copy of it — and the ink is read back off the bitmap. Everything
/// is measured in points at scale 4, so a quarter of a point shows.
@MainActor
final class RowLayoutTests: XCTestCase {

    /// Padding around the badge, so a glyph that outgrew its box lands as ink
    /// outside the slot instead of being clipped away by the render bounds.
    private static let pad: CGFloat = 20
    /// Where the badge's box sits in an isolated render.
    private static var badgeSlot: ClosedRange<Double> {
        Double(pad)...Double(pad + StatusBadge.boxWidth)
    }

    private struct Rendered {
        var size: CGSize
        /// Columns carrying ink, in points from the left edge of the canvas.
        var ink: [Double]

        var span: ClosedRange<Double>? { ink.isEmpty ? nil : ink.min()!...ink.max()! }
        func span(rightOf x: Double) -> ClosedRange<Double>? {
            let columns = ink.filter { $0 >= x }
            return columns.isEmpty ? nil : columns.min()!...columns.max()!
        }
        func span(leftOf x: Double) -> ClosedRange<Double>? {
            let columns = ink.filter { $0 < x }
            return columns.isEmpty ? nil : columns.min()!...columns.max()!
        }
        /// Ink inside a band, so a measurement can leave out both the colour bar
        /// on the left and the indicator on the right.
        func span(from: Double, to: Double) -> ClosedRange<Double>? {
            let columns = ink.filter { $0 >= from && $0 <= to }
            return columns.isEmpty ? nil : columns.min()!...columns.max()!
        }
        /// True when nothing at all is drawn between the two points.
        func isBlank(from: Double, to: Double) -> Bool {
            !ink.contains { $0 >= from && $0 <= to }
        }
    }

    private func render(status: RowStatus?) throws -> Rendered {
        // `panelVisible: false` keeps the pulse out of it: `.task` never runs
        // under `ImageRenderer`, but an animated opacity would be one more thing
        // deciding what counts as ink.
        try measure(StatusBadge(status: status, panelVisible: false)
            .padding(.horizontal, Self.pad))
    }

    private func measure(_ view: some View) throws -> Rendered {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        let image = try XCTUnwrap(renderer.nsImage, "ImageRenderer produced nothing")
        let bitmap = try XCTUnwrap(renderer.cgImage)

        let pixelWidth = bitmap.width, pixelHeight = bitmap.height
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels,
                                              width: pixelWidth,
                                              height: pixelHeight,
                                              bitsPerComponent: 8,
                                              bytesPerRow: pixelWidth * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        let scale = Double(pixelWidth) / Double(image.size.width)
        var columns: [Double] = []
        for x in 0..<pixelWidth {
            var drawn = false
            for y in 0..<pixelHeight {
                let offset: Int = (y * pixelWidth + x) * 4 + 3
                // Anything above the antialiasing floor counts as drawn.
                if pixels[offset] > 8 {
                    drawn = true
                    break
                }
            }
            if drawn { columns.append(Double(x) / scale) }
        }
        return Rendered(size: image.size, ink: columns)
    }

    /// A whole row at a given width, laid out the way the list lays it out and
    /// built the way the data layer builds one: both the status and the count
    /// come out of real chats and real subagents, and the row is asked to
    /// confirm it folded to what the test meant.
    ///
    /// Not every pair of status and count exists, and the fold is why (§3.1):
    /// `done` and `asleep` say nothing is running, so their count is zero by
    /// construction, and `active` says something is, so its count is never zero.
    /// Only `blocked` is free in both — a chat can hold its hand up while the
    /// rest of the window keeps working — which is why it is the status the
    /// count-vs-indicator checks below are run against.
    private func makeRow(status: RowStatus,
                         count: Int,
                         name: String = "проект с длинным именем, которое не влезает",
                         topic: String? = "тема чата, тоже подлиннее строки",
                         usage: TokenCounts? = nil) -> SwitcherRow {
        let state: AgentState = switch status {
        case .blocked: .question
        case .done: .waiting
        // A chat idle in itself, made active by the subagents hung off it, so
        // that the count is exactly what the test asked for rather than one more
        // than it.
        case .active: .idle
        case .asleep: .idle
        }
        var session = TestFixtures.session(id: "s", cwd: "/tmp/p", state: state)
        session.activeSubagents = count
        let aggregate = DataSource.aggregate([session])
        let row = SwitcherRow(id: "window:1:w1",
                              kind: .window,
                              displayName: name,
                              colorHex: "#1857a4",
                              project: nil,
                              window: nil,
                              sessions: [session],
                              state: aggregate.state,
                              activeSubagents: aggregate.activeSubagents,
                              subagentDescriptions: aggregate.subagentDescriptions,
                              chatTopic: topic,
                              model: nil,
                              contextUsedTokens: nil,
                              contextLimitTokens: nil,
                              lastActivity: nil,
                              usage: usage)
        XCTAssertEqual(row.status, status, "the fixture does not fold to \(status)")
        XCTAssertEqual(row.activeCount, count)
        return row
    }

    private func renderRow(status: RowStatus,
                           count: Int,
                           name: String = "проект с длинным именем, которое не влезает",
                           topic: String? = "тема чата, тоже подлиннее строки",
                           usage: TokenCounts? = nil,
                           width: Double) throws -> Rendered {
        let row = makeRow(status: status, count: count, name: name, topic: topic, usage: usage)
        return try measure(SwitcherRowView(row: row, isFrontmost: false, panelVisible: false)
            .padding(.horizontal, 6)
            .frame(width: width))
    }

    /// Where the colour bar's ink sits in a rendered row: 4 pt of bar behind the
    /// list's 6 pt of padding and the row's own 7. Measured 13.00…16.75.
    ///
    /// It is worth a constant because it is in front of the name in *every* row
    /// and never moves: a span taken from the left edge of the row is the bar's
    /// whatever the name does, which is how "the name is not a stump" once
    /// passed on a row that had no name at all.
    private static let colourBar: ClosedRange<Double> = 13.0...16.75

    /// The longest real project name on this machine, 36 characters and no
    /// spaces in it — the row where the name and the count fight for the line.
    private static let longestName = "wirenboard/node-red-contrib-wirenboard"

    /// The least ink the name may be left with while the count is still drawn.
    ///
    /// Not the width of four glyphs, because that is not what a span across the
    /// name measures: the ellipsis is inside the span too, and so is the gap in
    /// front of it. At the floor the name renders `wire…` — 37.00 pt in all,
    /// 25.75 of them glyphs, 1.75 the gap, 9.50 the three dots. One character
    /// less is `wir…`, 29.25 pt in the row. The threshold sits between those two
    /// with 3.75 pt of slack either way: enough to fail a floor that has dropped
    /// a character, enough to survive the half-point of glyph drift an OS update
    /// can bring. Asserting the glyphs' own 25.75 instead let `wir…` through, so
    /// every floor from 31 pt up passed a check that promises four characters.
    private static let nameSpanFloor: Double = 33

    /// Where the badge lands in a whole row: the last box-width before the row's
    /// trailing padding, with the list's own padding outside that.
    private func badgeSlot(inRowOfWidth width: Double) -> ClosedRange<Double> {
        // `LazyVStack` pads the list by 6 and the row pads itself by 7.
        let slotEnd = width - 6 - 7
        return (slotEnd - Double(StatusBadge.boxWidth))...slotEnd
    }

    /// The numbers, in one place, so a change to any of them has to be
    /// deliberate. One slot on the right, and it is the badge's own box: the
    /// count that used to have a slot of its own beside it now lives in the
    /// title line, and there is nothing left outside the badge to set a width
    /// for.
    func testTheSlotIsWhatTheSpecSays() {
        XCTAssertEqual(StatusBadge.boxWidth, 14)
        XCTAssertEqual(StatusBadge.boxHeight, 12)
    }

    /// Nothing a row can hold changes the width of the slot, so it starts at the
    /// same distance from the right edge of every row.
    func testTheSlotIsTheSameWidthWhateverIsInIt() throws {
        for status in RowStatus.allCases.map(Optional.some) + [nil] {
            let rendered = try render(status: status)
            XCTAssertEqual(rendered.size.width,
                           2 * Self.pad + StatusBadge.boxWidth,
                           accuracy: 0.01,
                           "status=\(status as Any)")
        }
    }

    /// And the four glyphs sit in the same slot as each other: each is centred
    /// in the same 14 pt box, so their ink is inside it and shares a midpoint.
    /// They are not the same width — that is exactly why the box is fixed.
    ///
    /// The containment half is a canary rather than the requirement: `frame`
    /// does not clip, so a glyph that outgrew the box would spill outside it
    /// without moving the slot. Worth hearing about all the same.
    ///
    /// And it is a canary with very little room: measured in the 20…34 slot,
    /// `hand.raised.fill` 22.75…31.5, `checkmark.circle.fill` and
    /// `moon.zzz.fill` 21.5…32.5, `arrow.triangle.2.circlepath` 20.25…33.5 —
    /// a quarter of a point from the left edge of the box. Half a point of
    /// glyph drift in an SF Symbols or macOS update breaks this line with
    /// nothing changed in the repository. If it fails on the containment
    /// assertions alone while the midpoints still agree, that is the OS having
    /// moved, not the layout: widen the box rather than hunting for a regression
    /// that is not there.
    func testEveryGlyphSitsInTheSameSlot() throws {
        var midpoints: [Double] = []
        for status in RowStatus.allCases {
            let rendered = try render(status: status)
            let badge = try XCTUnwrap(rendered.span, "\(status)")
            XCTAssertGreaterThanOrEqual(badge.lowerBound, Self.badgeSlot.lowerBound, "\(status) overflows left")
            XCTAssertLessThanOrEqual(badge.upperBound, Self.badgeSlot.upperBound, "\(status) overflows right")
            midpoints.append((badge.lowerBound + badge.upperBound) / 2)
        }
        let slotMidpoint = (Self.badgeSlot.lowerBound + Self.badgeSlot.upperBound) / 2
        for midpoint in midpoints {
            XCTAssertEqual(midpoint, slotMidpoint, accuracy: 0.5)
        }
    }

    /// A row with nothing to report draws nothing in the slot, and the slot is
    /// still there — that is what makes the empty case hold the column.
    func testAnEmptySlotDrawsNothingAndStillHoldsItsGround() throws {
        let empty = try render(status: nil)
        XCTAssertNil(empty.span, "an empty row drew something")
        XCTAssertEqual(empty.size.width, 2 * Self.pad + StatusBadge.boxWidth, accuracy: 0.01)
    }

    /// The same thing measured where the user sees it: a whole row, laid out at
    /// the real panel width, with the list's padding around it. The indicator
    /// lands in the last 14 pt before the row's trailing padding — 353…367 in a
    /// 380 pt panel — for every status and every count that status can have.
    ///
    /// Containment alone does not say "the same place": the four glyphs are
    /// right-aligned against one edge, so all of them fit inside 353…367 even
    /// with the fixed box gone — which is what the midpoint check is for.
    /// Measured 359.875 / 360.0 / 360.125 against a slot midpoint of 360, so
    /// 0.375 of the tolerance is spare. A 1 pt nudge of the slot fails it even
    /// for the narrow moon, whose ink would still be inside the bounds.
    func testTheIndicatorIsInTheSamePlaceInAWholeRowAtPanelWidth() throws {
        let panelWidth = Config.default.panelWidth
        let slot = badgeSlot(inRowOfWidth: panelWidth)
        let slotMidpoint = (slot.lowerBound + slot.upperBound) / 2

        for status in RowStatus.allCases {
            for count in Self.counts(for: status) {
                let rendered = try renderRow(status: status, count: count, width: panelWidth)
                let badge = try XCTUnwrap(rendered.span(rightOf: slot.lowerBound - 3),
                                          "\(status) count=\(count)")
                XCTAssertGreaterThanOrEqual(badge.lowerBound, slot.lowerBound, "\(status) count=\(count)")
                XCTAssertLessThanOrEqual(badge.upperBound, slot.upperBound, "\(status) count=\(count)")
                XCTAssertEqual((badge.lowerBound + badge.upperBound) / 2, slotMidpoint, accuracy: 0.5,
                               "\(status) count=\(count)")
            }
        }
    }

    /// The counts each fold can actually carry (§3.1). `blocked` is the only one
    /// free to have any of them.
    private static func counts(for status: RowStatus) -> [Int] {
        switch status {
        case .blocked: return [0, 1, 12, 123]
        case .active: return [1, 12, 123]
        case .done, .asleep: return [0]
        }
    }

    /// The point of the round, and the part the move into the title line could
    /// have broken: the count — absent, one digit, two, or three — never moves
    /// the indicator by so much as a subpixel, whether the name leaves room or
    /// runs the whole width of the row.
    func testTheCountInTheTitleNeverMovesTheIndicator() throws {
        let panelWidth = Config.default.panelWidth
        let slot = badgeSlot(inRowOfWidth: panelWidth)
        for name in ["p", "wirenboard/node-red-contrib-wirenboard"] {
            var seen: ClosedRange<Double>?
            for count in [0, 1, 12, 123] {
                let rendered = try renderRow(status: .blocked, count: count, name: name, width: panelWidth)
                let badge = try XCTUnwrap(rendered.span(rightOf: slot.lowerBound - 3),
                                          "no indicator drawn for count=\(count)")
                if let seen {
                    XCTAssertEqual(badge.lowerBound, seen.lowerBound, accuracy: 0.01, "\(name) count=\(count)")
                    XCTAssertEqual(badge.upperBound, seen.upperBound, accuracy: 0.01, "\(name) count=\(count)")
                } else {
                    seen = badge
                }
            }
        }
    }

    /// The name is what gives way when the row runs out of width, not the count:
    /// the ellipsis lands in the name and `(agents: N)` stays whole. The other
    /// way round it would be the long-named row — the one worth reading the
    /// number on — that lost it.
    ///
    /// Measured rather than asserted about. The label is rendered on its own to
    /// learn how wide its ink is, and then looked for at the end of the title
    /// line: that many points of ink flush with the right edge of the text, with
    /// a blank band in front of them where the `HStack` spacing is. A label
    /// truncated to fit would be narrower than its own ink, so the name would
    /// fill that band; a label dropped altogether leaves the name running
    /// unbroken to the edge. Both counts are checked, because a label clamped to
    /// some fixed width would pass one of them by accident.
    ///
    /// The name is the longest real one on this machine, 36 characters, and has
    /// no spaces in it — so a blank band this wide inside the title line is the
    /// gap in front of the label and nothing else. The row is rendered without a
    /// chat topic for the same reason: the second line would put its own ink in
    /// these columns.
    ///
    /// Several widths, because the narrow ones are where the name has to be
    /// defended. At the 380 pt default there is room for both and the shrink
    /// lands on the name by itself. Further down — `panelWidth` is a setting and
    /// takes any value above zero — the name is at its floor and the count is
    /// still whole, which is the middle rung of the ladder doing its job: 40 pt
    /// answers the fit question, the rest of the line is still drawn in, and at
    /// least `nameSpanFloor` of the name survives — 33 pt, which is four
    /// characters and their ellipsis. Measured without the colour bar in front
    /// of it: the bar's own 13.00…16.75 is in every row and would carry any such
    /// assertion on its own.
    ///
    /// Where that rung gives out was measured by sweeping the width a point at a
    /// time against the longest real name: the count is drawn down to 188 pt with
    /// one digit, 193 with two, 201 with three. Hence the pairs — 200 pt is
    /// below the three-digit line. The two tests below take it from here: the
    /// sweep walks every width down to where the rung gives out, and the
    /// narrow-panel one stands on the far side of it. (A short name keeps its
    /// count further down still, 156 pt for a single character: the first rung
    /// fits where the second does not.)
    func testALongNameGivesWayBeforeTheCountDoes() throws {
        for (width, count) in [(Config.default.panelWidth, 5), (Config.default.panelWidth, 123),
                               (240.0, 5), (240.0, 123), (200.0, 5)] {
            let drawn = try countIsDrawnAboveTheNameFloor(width: width,
                                                         count: count,
                                                         name: Self.longestName,
                                                         labelWidth: try inkWidthOfLabel(count: count))
            XCTAssertTrue(drawn, "the count went away already at \(width) pt — count=\(count)")
        }
    }

    /// The top rung, which neither the test above nor the sweep below ever
    /// reaches: both are run against the longest real name, which has not fitted
    /// whole since 380 pt, so both of them land on the middle rung and a build
    /// with the top rung deleted passes them all.
    ///
    /// A short name is where the top rung is the one that fits, and it fits
    /// further down than the middle one can: the middle rung asks for 40 pt of
    /// name whatever the name is, the top rung asks for the name's own width.
    /// Measured against `p`, the count survives down to 156 pt with one digit,
    /// 162 with two, 170 with three; the longest name loses a one-digit count
    /// already at 188. So the width here is between those two, halfway, with
    /// 16 pt of drift in either direction before the test stops meaning what it
    /// says — and both halves are asserted, because "the count is drawn" alone
    /// would also pass if the middle rung had somehow reached down here.
    func testAShortNameKeepsItsCountWhereTheFloorWouldNotFit() throws {
        let width = 172.0
        let labelWidth = try inkWidthOfLabel(count: 5)
        let short = try nameInkBesideTheCount(width: width, count: 5, name: "p", labelWidth: labelWidth)
        XCTAssertNotNil(short, "a one-character name lost its count at \(width) pt")
        let long = try nameInkBesideTheCount(width: width,
                                             count: 5,
                                             name: Self.longestName,
                                             labelWidth: labelWidth)
        XCTAssertNil(long, "the middle rung reached \(width) pt, so the count there proves nothing")
    }

    /// And the floor holds all the way down to where the rung gives out, not
    /// merely at the widths named above.
    ///
    /// This is the assertion that pins `nameFloorWidth` to a number. At 200 pt
    /// and up the floor is not binding — the name is offered the rest of the
    /// line and takes 44.75 pt of ink or more — so those widths draw the same
    /// row whatever the floor is set to, and a floor of 5 pt passed them all.
    /// What a lower floor really does is keep the count alive further down, on
    /// rows where the name is already a stump: measured at 20 pt, the count
    /// still draws at 178 pt beside 24.25 pt of name (`wi…`) and at 169 pt
    /// beside 9.50 pt (the ellipsis alone, no name at all). Sweeping every
    /// width down to the narrow panel of the next test is what catches that.
    ///
    /// One digit, because the shortest label is the one that survives furthest
    /// down and squeezes the name hardest.
    func testTheNameKeepsItsFloorWhereverTheCountIsDrawn() throws {
        // From just above the three-digit line — the widths above it are the
        // test before this one — down to the panel of the narrow-panel test.
        var width = 205.0
        var widthsWithACount = 0
        let labelWidth = try inkWidthOfLabel(count: 5)
        while width >= 150 {
            if try countIsDrawnAboveTheNameFloor(width: width,
                                                 count: 5,
                                                 name: Self.longestName,
                                                 labelWidth: labelWidth) {
                widthsWithACount += 1
            }
            width -= 1
        }
        // And the sweep is not a sweep over rows that all dropped the count,
        // which would assert nothing at all. One digit reaches 188 pt, so
        // eighteen of these widths draw it — and the assertion is deliberately
        // far below that. Like the badge-slot check (§4) this is a canary rather
        // than the requirement itself, and there the resemblance ends: that one
        // is deliberately tight, a quarter of a point, so that glyph drift is
        // what trips it. This one is deliberately loose. What it guards against
        // is a sweep gone empty (a floor of 60 pt draws no count at any of these
        // widths at all), not the exact place the rung gives out, which an OS
        // metrics change may move by a point or two on its own.
        XCTAssertGreaterThanOrEqual(widthsWithACount, 8)
    }

    /// One rung of the ladder at one width: is the count still drawn whole, and
    /// if it is, how much ink is the name in front of it left with? `nil` when
    /// the row dropped the count altogether.
    ///
    /// Whether the count is drawn is decided against the same row without one,
    /// because a row that dropped it draws exactly what a count-less row draws.
    /// The name is measured between the colour bar and the label, so that what
    /// the floor promises — the *name*, not the row — is what is counted.
    ///
    /// The label's own ink is passed in rather than measured here: it does not
    /// depend on the width, and rendering it again at every step of the sweep
    /// was a third of the whole suite's running time.
    private func nameInkBesideTheCount(width: Double,
                                       count: Int,
                                       name: String,
                                       labelWidth: Double) throws -> Double? {
        let rendered = try renderRow(status: .blocked, count: count, name: name, topic: nil, width: width)
        let bare = try renderRow(status: .blocked, count: 0, name: name, topic: nil, width: width)
        guard rendered.ink != bare.ink else { return nil }

        let slot = badgeSlot(inRowOfWidth: width)
        let text = try XCTUnwrap(rendered.span(leftOf: slot.lowerBound - 3), "no title drawn")
        // Half a point of slack: the label starts at a fractional x in the row
        // and the antialiasing of its first stem can fall either side of a
        // quarter-point column.
        let labelStart = text.upperBound - labelWidth - 0.5
        XCTAssertTrue(rendered.isBlank(from: labelStart - 2.5, to: labelStart - 0.5),
                      "the name ran into the label — width=\(width) count=\(count)")
        let nameInk = try XCTUnwrap(rendered.span(from: Self.colourBar.upperBound + 0.25,
                                                  to: labelStart - 2.5),
                                    "no name drawn — width=\(width) count=\(count)")
        return nameInk.upperBound - nameInk.lowerBound
    }

    /// The same thing where the floor is what is being asked about: the count is
    /// drawn *and* the name in front of it is not a stump.
    private func countIsDrawnAboveTheNameFloor(width: Double,
                                               count: Int,
                                               name: String,
                                               labelWidth: Double) throws -> Bool {
        guard let nameInk = try nameInkBesideTheCount(width: width,
                                                      count: count,
                                                      name: name,
                                                      labelWidth: labelWidth) else { return false }
        XCTAssertGreaterThanOrEqual(nameInk, Self.nameSpanFloor,
                                    "the name is down to a stump — width=\(width) count=\(count)")
        return true
    }

    /// Below that floor the count is what goes, and it goes whole.
    ///
    /// A 150 pt panel cannot hold a long name and `(agents: N)` at once, and the
    /// half that has to survive is the name: a row that reads `(agents: 124)` and
    /// nothing else identifies no project, the same objection §2.2.1 makes to a
    /// row parked at the bottom of a 93-row list. So the row is asked to draw
    /// exactly what the same row without a count draws — not a truncated label,
    /// which is what a minimum width on the name gives instead (measured: the
    /// same 25.75 pt stump for 5 as for 124, a count that lies about its number).
    ///
    /// The equality is over the whole row, indicator included, so an overflow
    /// would fail it too: `fixedSize` alone pushed the colour bar 5.5 pt out of
    /// the row's own frame here.
    func testANarrowPanelDropsTheCountAndKeepsTheName() throws {
        let width = 150.0
        let bare = try renderRow(status: .blocked, count: 0, name: Self.longestName, topic: nil, width: width)
        // Not two empty rows being compared — and the row's own span cannot say
        // so, because the colour bar and the indicator hold both its ends: with
        // no name at all it measures the same 121.50 pt (13.00…134.50) as with
        // the longest one. So the name's own ink is what is asked for, between
        // the bar and the badge: 68.25 pt of it here, 26.25…94.50, which is the
        // name truncated to `wirenboa…` (68.25 pt rendered on its own). The
        // whole `wirenboard/node-…` would be 123.50 pt and has no room here.
        let bareName = try XCTUnwrap(bare.span(from: Self.colourBar.upperBound + 0.25,
                                               to: badgeSlot(inRowOfWidth: width).lowerBound - 3),
                                     "the bare row drew no name to compare against")
        XCTAssertGreaterThan(bareName.upperBound - bareName.lowerBound, 60)

        for count in [5, 123] {
            let rendered = try renderRow(status: .blocked,
                                         count: count,
                                         name: Self.longestName,
                                         topic: nil,
                                         width: width)
            XCTAssertEqual(rendered.ink, bare.ink, "count=\(count) still drew something at 150 pt")
            // And the label is nowhere in the row: its ink would have to end
            // somewhere, and the title line ends where the name's ellipsis does.
            let labelWidth = try inkWidthOfLabel(count: count)
            let slot = badgeSlot(inRowOfWidth: width)
            let text = try XCTUnwrap(rendered.span(leftOf: slot.lowerBound - 3))
            XCTAssertFalse(rendered.isBlank(from: text.upperBound - labelWidth - 3,
                                            to: text.upperBound - labelWidth - 0.5),
                           "there is a label-shaped gap in the title — count=\(count)")
        }
    }

    /// Every measurement above starts its band at the right-hand edge of
    /// `colourBar`, a range written down by hand, and reads whatever is left of
    /// the badge as the name. Both halves of that are worth one cheap render: a
    /// row with no name at all draws the bar exactly where the constant says,
    /// and nothing whatever between it and the indicator. If a future row grows
    /// something in that band — a second bar, a leading icon — the assertions
    /// that ask "is the name still there" would start passing on its ink
    /// instead, which is the very hole this constant was introduced to close.
    func testNothingButTheNameLivesBetweenTheBarAndTheSlot() throws {
        let width = 150.0
        let rendered = try renderRow(status: .blocked, count: 0, name: "", topic: nil, width: width)
        let bar = try XCTUnwrap(rendered.span(leftOf: Self.colourBar.upperBound + 3),
                                "the row drew no colour bar")
        XCTAssertEqual(bar.lowerBound, Self.colourBar.lowerBound, accuracy: 0.01)
        XCTAssertEqual(bar.upperBound, Self.colourBar.upperBound, accuracy: 0.01)
        // Measured: the bar ends at 16.75 and the next ink in the row is the
        // indicator at 125.75.
        XCTAssertNil(rendered.span(from: Self.colourBar.upperBound + 0.25,
                                   to: badgeSlot(inRowOfWidth: width).lowerBound - 3),
                     "a nameless row drew something between the bar and the slot")
    }

    // MARK: - Spend on the second line

    /// The spend the tests are run against: complete, and 3.40M
    /// input-equivalent — 1M in, 200k out at five times, 400k of cache writes at
    /// 1.25 and 9M of cache reads at a tenth.
    private static let spend = TokenCounts(input: 1_000_000,
                                           output: 200_000,
                                           cacheCreation: 400_000,
                                           cacheRead: 9_000_000)

    /// A row whose title line draws nothing, so that every column of ink between
    /// the colour bar and the indicator belongs to the second line.
    ///
    /// The columns of a render are collapsed over the whole height of the row,
    /// so the name and the topic would otherwise be measured as one thing —
    /// which is the same reason `testNothingButTheNameLivesBetweenTheBarAndTheSlot`
    /// renders a nameless row.
    private func renderSecondLine(topic: String?,
                                  usage: TokenCounts?,
                                  width: Double) throws -> Rendered {
        try renderRow(status: .blocked, count: 0, name: "", topic: topic, usage: usage, width: width)
    }

    /// The number's own ink, rendered alone in the font the second line draws it
    /// in.
    private func inkWidthOfSpend(_ label: String) throws -> Double {
        let alone = try measure(Text(label)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(Self.pad))
        let ink = try XCTUnwrap(alone.span)
        return ink.upperBound - ink.lowerBound
    }

    /// The spend is at the right-hand end of the second line, not wherever the
    /// topic happens to stop. Measured against a topic short enough that the two
    /// cannot be confused: if the number simply followed the topic it would be
    /// tens of points to the left of where it is.
    func testTheSpendStandsAtTheRightEndOfTheSecondLine() throws {
        let width = Config.default.panelWidth
        let label = try XCTUnwrap(SwitcherRowView.usageLabel(for: makeRow(status: .blocked,
                                                                         count: 0,
                                                                         usage: Self.spend)))
        XCTAssertEqual(label, "3.40M")
        let labelWidth = try inkWidthOfSpend(label)

        let rendered = try renderSecondLine(topic: "тема", usage: Self.spend, width: width)
        let slot = badgeSlot(inRowOfWidth: width)
        let line = try XCTUnwrap(rendered.span(from: Self.colourBar.upperBound + 0.25,
                                               to: slot.lowerBound - 3),
                                 "the second line drew nothing")
        // The line ends where the text block ends, which is 24 pt short of the
        // indicator: 9 pt of `HStack` spacing on either side of the 6 pt spacer.
        XCTAssertEqual(line.upperBound, slot.lowerBound - 24, accuracy: 1.5,
                       "the number is not flush with the end of the line")
        // And what stands there is the whole number: that much ink, with blank
        // in front of it where the 6 pt gap is.
        let start = line.upperBound - labelWidth - 0.5
        XCTAssertTrue(rendered.isBlank(from: start - 3.5, to: start - 1),
                      "the topic ran into the number")
        let number = try XCTUnwrap(rendered.span(from: start, to: line.upperBound))
        XCTAssertEqual(number.upperBound - number.lowerBound, labelWidth, accuracy: 0.5)

        // The topic is where it always was, at the left-hand end of the line.
        let topic = try XCTUnwrap(rendered.span(from: Self.colourBar.upperBound + 0.25,
                                                to: start - 3.5),
                                  "the topic went away")
        // Measured: the topic's first glyph starts at 26.25, which is the bar's
        // 16.75 plus the 9 pt of `HStack` spacing behind it.
        XCTAssertLessThan(topic.lowerBound, Self.colourBar.upperBound + 11)
    }

    /// The number never gives way; the topic does. `fixedSize` is what says so,
    /// and 150 pt is where it starts to matter — the panel width is a setting,
    /// and at the default there is room for both.
    ///
    /// Held by measurement rather than by belief: the number's ink is compared
    /// against the same string rendered on its own, so a truncated `3.4…` fails
    /// even though it is still "drawn". Proved by removing the modifier — the
    /// number came out 12.75 pt narrower at 150 pt, and this fails.
    func testTheSpendIsNeverCutWhileTheTopicIs() throws {
        let label = try XCTUnwrap(SwitcherRowView.usageLabel(for: makeRow(status: .blocked,
                                                                         count: 0,
                                                                         usage: Self.spend)))
        let labelWidth = try inkWidthOfSpend(label)
        var topicWidths: [Double] = []

        for width in [Config.default.panelWidth, 240.0, 150.0] {
            let rendered = try renderSecondLine(topic: "тема чата, тоже подлиннее строки",
                                                usage: Self.spend,
                                                width: width)
            let slot = badgeSlot(inRowOfWidth: width)
            let line = try XCTUnwrap(rendered.span(from: Self.colourBar.upperBound + 0.25,
                                                   to: slot.lowerBound - 3),
                                     "nothing drawn at \(width) pt")
            let start = line.upperBound - labelWidth - 0.5
            let number = try XCTUnwrap(rendered.span(from: start, to: line.upperBound),
                                       "no number at \(width) pt")
            XCTAssertEqual(number.upperBound - number.lowerBound, labelWidth, accuracy: 0.5,
                           "the number was cut at \(width) pt")
            XCTAssertTrue(rendered.isBlank(from: start - 3.5, to: start - 1),
                          "the topic ran into the number at \(width) pt")
            let topic = try XCTUnwrap(rendered.span(from: Self.colourBar.upperBound + 0.25,
                                                    to: start - 3.5),
                                      "the topic vanished entirely at \(width) pt")
            topicWidths.append(topic.upperBound - topic.lowerBound)
        }
        // The topic is what shrank, all the way down.
        XCTAssertGreaterThan(topicWidths[0], topicWidths[1])
        XCTAssertGreaterThan(topicWidths[1], topicWidths[2])
    }

    /// A row with spend and no chat is the number alone, still on the right.
    func testARowWithSpendAndNoTopicIsJustTheNumber() throws {
        let width = Config.default.panelWidth
        let label = try XCTUnwrap(SwitcherRowView.usageLabel(for: makeRow(status: .blocked,
                                                                         count: 0,
                                                                         usage: Self.spend)))
        let labelWidth = try inkWidthOfSpend(label)
        let rendered = try renderSecondLine(topic: nil, usage: Self.spend, width: width)
        let slot = badgeSlot(inRowOfWidth: width)
        let line = try XCTUnwrap(rendered.span(from: Self.colourBar.upperBound + 0.25,
                                               to: slot.lowerBound - 3),
                                 "the number went away with the topic")
        XCTAssertEqual(line.upperBound - line.lowerBound, labelWidth, accuracy: 0.5,
                       "something other than the number is on the line")
        XCTAssertEqual(line.upperBound, slot.lowerBound - 24, accuracy: 1.5)
    }

    /// And a row with neither grows no second line at all — the row keeps the
    /// single-line height it has always had, which is what "looks exactly like
    /// today" means for the ninety-odd rows of the projects section.
    func testARowWithNeitherTopicNorSpendGrowsNoSecondLine() throws {
        let width = Config.default.panelWidth
        let bare = try renderRow(status: .blocked, count: 0, name: "имя",
                                 topic: nil, usage: nil, width: width)
        XCTAssertEqual(bare.size.height, 38, accuracy: 0.01,
                       "a row with nothing to say is not the minimum height any more")
        let variants: [(topic: String?, usage: TokenCounts?)] = [
            ("тема", nil), (nil, Self.spend), ("тема", Self.spend)
        ]
        for second in variants {
            let rendered = try renderRow(status: .blocked, count: 0, name: "имя",
                                         topic: second.topic, usage: second.usage, width: width)
            XCTAssertGreaterThan(rendered.size.height, bare.size.height,
                                 "no second line for topic=\(second.topic as Any)")
        }
    }

    /// The count's own ink, rendered on its own in the font the row draws it in.
    private func inkWidthOfLabel(count: Int) throws -> Double {
        let label = try XCTUnwrap(SwitcherRowView.countLabel(for: makeRow(status: .blocked, count: count)))
        let alone = try measure(Text(label)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(Self.pad))
        let ink = try XCTUnwrap(alone.span)
        return ink.upperBound - ink.lowerBound
    }
}

/// The row carries exactly one tooltip, and it has to say everything the row
/// itself stopped saying: what each icon means, and the context and model of
/// each individual chat.
@MainActor
final class RowTooltipTests: XCTestCase {

    private func session(_ id: String,
                         _ state: AgentState,
                         topic: String?,
                         used: Int? = nil,
                         limit: Int? = nil,
                         model: String? = "claude-opus-5") -> ClaudeSessionInfo {
        ClaudeSessionInfo(sessionId: id,
                          pid: 1,
                          cwd: "/tmp/home-network",
                          name: nil,
                          aiTitle: topic,
                          lastPrompt: nil,
                          state: state,
                          stateSource: .hook,
                          model: model,
                          contextUsedTokens: used,
                          contextLimitTokens: limit,
                          activeSubagents: 0,
                          subagents: [],
                          lastActivity: nil)
    }

    private func row(_ sessions: [ClaudeSessionInfo],
                     kind: SwitcherRowKind = .window,
                     subagents: [String] = []) -> SwitcherRow {
        let aggregate = DataSource.aggregate(sessions)
        return SwitcherRow(id: "window:1:w1",
                           kind: kind,
                           displayName: "home-network",
                           colorHex: "#1857a4",
                           project: nil,
                           window: nil,
                           sessions: sessions,
                           state: aggregate.state,
                           activeSubagents: subagents.count,
                           subagentDescriptions: subagents,
                           chatTopic: sessions.first?.topic,
                           model: sessions.first?.model,
                           contextUsedTokens: sessions.first?.contextUsedTokens,
                           contextLimitTokens: sessions.first?.contextLimitTokens,
                           lastActivity: nil)
    }

    func testEveryChatIsNamedWithItsStateContextAndModel() {
        let text = SwitcherRowView.tooltipText(for: row([
            session("a", .permission, topic: "Перенести CI/CD на Gitea", used: 168_000, limit: 200_000),
            session("b", .working, topic: "Маршрутизация Docker", used: 116_000, limit: 200_000),
        ]))

        XCTAssertTrue(text.contains("Waiting for permission · Перенести CI/CD на Gitea · 84% · opus-5"), text)
        XCTAssertTrue(text.contains("Working · Маршрутизация Docker · 58% · opus-5"), text)
        XCTAssertTrue(text.contains("home-network"))
    }

    /// Every icon the row can draw is spelled out in words somewhere in the
    /// tooltip — that is the whole legend for the chips.
    func testTheStateOfEveryChatIsSpelledOutInWords() {
        let sessions = AgentState.allCases.enumerated().map { index, state in
            session("s\(index)", state, topic: "тема \(index)")
        }
        let text = SwitcherRowView.tooltipText(for: row(sessions))
        for state in AgentState.allCases {
            XCTAssertTrue(text.contains(SwitcherRowView.stateLabel(for: state)), "missing \(state)")
        }
    }

    /// The percentage is what the data layer could prove, so a chat with no
    /// known window shows tokens and no percentage — same rule as the row had.
    func testAnUnknownWindowShowsTokensInsteadOfAPercentage() {
        let text = SwitcherRowView.tooltipText(for: row([
            session("a", .working, topic: "тема", used: 194_000, limit: nil),
        ]))
        XCTAssertTrue(text.contains("194k"), text)
        XCTAssertFalse(text.contains("%"), text)
    }

    /// A chat with no `ai-title` falls back to the last prompt, which can be a
    /// whole paragraph; the tooltip is a list, not an essay.
    func testALongTopicIsCutDown() {
        let long = String(repeating: "длинная тема ", count: 40)
        let text = SwitcherRowView.tooltipText(for: row([session("a", .working, topic: long)]))
        let chatLine = try? XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("• ") })
        XCTAssertNotNil(chatLine)
        XCTAssertLessThan(chatLine?.count ?? .max, 100)
        XCTAssertTrue(text.contains("…"))
    }

    func testSubagentsAndThePathAreStillThere() {
        var built = row([session("a", .working, topic: "тема")], kind: .project, subagents: ["Round 6 fixes"])
        built.sessions = [session("a", .working, topic: "тема")]
        let text = SwitcherRowView.tooltipText(for: built)
        XCTAssertTrue(text.contains("Background agents:"), text)
        XCTAssertTrue(text.contains("Round 6 fixes"), text)
        XCTAssertTrue(text.contains("/tmp/home-network"), text)
    }

    func testARowWithNoChatsHasNoChatSection() {
        let text = SwitcherRowView.tooltipText(for: row([]))
        XCTAssertFalse(text.contains("Chats:"), text)
    }
}

/// The picture in the menu bar, measured off the bitmap it actually draws —
/// the same technique as `RowLayoutTests`, because the requirement is the same
/// kind: a column that does not hold still.
@MainActor
final class MenuBarIconTests: XCTestCase {

    /// One drawn icon, read back as ink.
    private struct Rendered {
        var width: Double
        var height: Double
        /// Every inked pixel, in points from the left and the *bottom* edges —
        /// the picture is drawn `flipped: false`, so a larger y is higher up, and
        /// that is the coordinate system the icon's own geometry is stated in.
        var ink: [(x: Double, y: Double)]

        /// Columns carrying ink inside a band of rows: the way the number is told
        /// from the bar now that they are stacked rather than side by side.
        func columns(in band: ClosedRange<CGFloat>) -> [Double] {
            rows(in: band).map(\.x)
        }

        func rows(in band: ClosedRange<CGFloat>) -> [(x: Double, y: Double)] {
            ink.filter { $0.y >= Double(band.lowerBound) && $0.y <= Double(band.upperBound) }
        }

        /// How much was drawn inside a band, in pixels — the fill of a bar is an
        /// area, not a span, so a proportion has to be counted rather than
        /// measured.
        func pixels(in band: ClosedRange<CGFloat>) -> Int { rows(in: band).count }

        /// The bands of rows that carry ink, split wherever half a point of the
        /// picture is blank.
        ///
        /// Found in the rendering rather than taken from the icon's own geometry,
        /// and that is the whole point of it: a check that only looks inside the
        /// two declared bands cannot see the number drawn *into* the bar's rows —
        /// verified by drawing it there, which passed such a check and fails this
        /// one.
        var inkedBands: [ClosedRange<Double>] {
            var bands: [ClosedRange<Double>] = []
            for row in Set(ink.map(\.y)).sorted() {
                if let last = bands.last, row - last.upperBound <= 0.5 {
                    bands[bands.count - 1] = last.lowerBound...row
                } else {
                    bands.append(row...row)
                }
            }
            return bands
        }
    }

    /// The rows the bar may draw in, as the icon declares them.
    private static var barBand: ClosedRange<CGFloat> {
        MenuBarIcon.barRect.minY...MenuBarIcon.barRect.maxY
    }

    private static let scale = 4.0

    private func render(_ percent: Int?) throws -> Rendered {
        let image = MenuBarIcon.image(forPercent: percent)
        XCTAssertTrue(image.isTemplate, "the status item picture is not a template")

        let width = Int(image.size.width * Self.scale)
        let height = Int(image.size.height * Self.scale)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels,
                                              width: width,
                                              height: height,
                                              bitsPerComponent: 8,
                                              bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: Double(width), height: Double(height)))
        NSGraphicsContext.restoreGraphicsState()

        var ink: [(x: Double, y: Double)] = []
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                // Row 0 of a bitmap context's buffer is the top of the image,
                // whichever way the context's own coordinate system runs.
                ink.append((x: Double(x) / Self.scale, y: Double(height - 1 - y) / Self.scale))
            }
        }
        return Rendered(width: image.size.width, height: image.size.height, ink: ink)
    }

    /// The whole point of a fixed column: the item never changes width, so the
    /// items to the left of it never shuffle. Not just across digits — across
    /// the presence of a figure at all, which is the second way a status item
    /// can be made to twitch, once a minute, whenever a tunnel goes down.
    func testThePictureIsTheSameWidthWhateverTheFigure() throws {
        let widths = try [nil, 0, 5, 42, 100].map { try render($0).width }
        for width in widths {
            XCTAssertEqual(width, widths[0], accuracy: 0.001, "widths: \(widths)")
        }
        // And that width is the one the column arithmetic says, not whatever a
        // 5% string happened to need.
        XCTAssertEqual(widths[0], Double(MenuBarIcon.width), accuracy: 0.001)
        XCTAssertEqual(MenuBarIcon.numberColumnWidth,
                       ceil(NSAttributedString(string: "100%",
                                               attributes: [.font: MenuBarIcon.font]).size().width),
                       accuracy: 0.001)
    }

    /// And with the number under the bar rather than beside it, that width is the
    /// number's column and nothing else — which is the whole reason the layout
    /// changed. Side by side the picture was 57 points wide and took a visible
    /// slice of the menu bar; stacked it is 27.
    ///
    /// The width is laid out here rather than compared against the icon's own
    /// arithmetic. The check used to read `width == max(barWidth,
    /// numberColumnWidth)` — the expression the property was written as — so
    /// replacing that property with anything at all failed nothing. What the
    /// picture has to be as wide as is the widest string it can ever hold, and
    /// that is a thing this test can measure for itself.
    func testThePictureIsExactlyTheNumbersColumnWide() throws {
        let widest = ceil(NSAttributedString(string: "100%",
                                             attributes: [.font: MenuBarIcon.font]).size().width)
        XCTAssertEqual(MenuBarIcon.width, widest, accuracy: 0.001)
        XCTAssertEqual(try render(100).width, Double(widest), accuracy: 0.001)
        XCTAssertLessThan(MenuBarIcon.width, 30,
                          "the item is back to taking a row of the menu bar: \(MenuBarIcon.width) pt")
        // And the stack fills the height a status item is drawn at, exactly.
        // Not "fits": a stack shorter than the picture is bar fill thrown away
        // — the fill is the reading, and `insetBy(dy: 1.5)` leaves it 3 points
        // of the bar's 6 — while a taller one is clipped.
        XCTAssertEqual(MenuBarIcon.contentHeight, MenuBarIcon.height, accuracy: 0.001,
                       "bar \(MenuBarIcon.barHeight) + gap \(MenuBarIcon.gap) "
                       + "+ number \(MenuBarIcon.numberHeight) is not the 18 pt of the picture")
        XCTAssertEqual(try render(42).height, Double(MenuBarIcon.height), accuracy: 0.001)
    }

    /// Drawn, and not merely declared: the number's ink is below the bar's, the
    /// two do not touch, and the bar is drawn across the whole width of the
    /// picture rather than in a column of its own.
    func testTheNumberIsDrawnUnderTheBarAndNothingOverlaps() throws {
        let rendered = try render(42)
        // Two clusters of ink with clear picture between them, found in the
        // bitmap: this is what "under" means, and asking the declared bands
        // instead is a question that cannot come out wrong (checked by drawing the
        // number on the bar's row — the band version passed, this fails).
        let bands = rendered.inkedBands
        // A guard rather than an assertion, so a picture with the two run together
        // fails this test instead of crashing the run on the next line.
        guard bands.count == 2 else {
            return XCTFail("the number and the bar are not two separated bands of ink: \(bands)")
        }
        let number = bands[0]
        let bar = bands[1]
        XCTAssertLessThan(number.upperBound, bar.lowerBound)
        // And the two of them together are inside the 18 points a status item
        // gets — which the stack now fills exactly, so nothing is clipped off
        // either end.
        XCTAssertGreaterThanOrEqual(number.lowerBound, 0)
        XCTAssertLessThanOrEqual(bar.upperBound, Double(MenuBarIcon.height))
        // And each cluster is where the icon says it draws.
        XCTAssertGreaterThanOrEqual(number.lowerBound,
                                    Double(MenuBarIcon.numberRows.lowerBound) - 0.3)
        XCTAssertLessThanOrEqual(number.upperBound,
                                 Double(MenuBarIcon.numberRows.upperBound) + 0.3)
        XCTAssertGreaterThanOrEqual(bar.lowerBound, Double(MenuBarIcon.barRect.minY) - 0.3)
        XCTAssertLessThanOrEqual(bar.upperBound, Double(MenuBarIcon.barRect.maxY) + 0.3)
        // The bar spans the picture: it is the width, rather than sitting in a
        // 20 pt column with the number's column empty beside it.
        let barColumns = rendered.columns(in: Self.barBand)
        XCTAssertEqual(try XCTUnwrap(barColumns.min()), 0, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(barColumns.max()), Double(MenuBarIcon.width) - 0.25,
                       accuracy: 0.5)
    }

    /// The number sits flush with the right edge of the picture, so the `%` stays
    /// in one place while the digits in front of it come and go — and the widest
    /// figure still fits the width that was measured for it.
    func testEveryFigureEndsAtTheSameEdgeAndFitsItsColumn() throws {
        var rightEdges: [Double] = []
        for percent in [0, 5, 42, 100] {
            let columns = try render(percent).columns(in: MenuBarIcon.numberRows)
            XCTAssertFalse(columns.isEmpty, "nothing drawn for \(percent)%")
            rightEdges.append(try XCTUnwrap(columns.max()))
        }
        for edge in rightEdges {
            XCTAssertEqual(edge, rightEdges[0], accuracy: 0.5, "right edges: \(rightEdges)")
        }
        // Nothing is clipped on the left, either: the picture is exactly as wide
        // as the widest string it can hold.
        XCTAssertLessThanOrEqual(MenuBarIcon.label(forPercent: 100).size().width,
                                 MenuBarIcon.width)
    }

    /// No reading, no number. Not `0%` — a poll that failed carries the previous
    /// figures and a percentage in the menu bar has no room to say "as of a
    /// while ago" (§2.4: a confidently wrong figure is worse than a missing
    /// one). A genuine zero *is* drawn, which is the other half of the same
    /// rule: the two states have to look different.
    func testWithoutAReadingNoNumberIsDrawnAtAll() throws {
        let blank = try render(nil)
        XCTAssertTrue(blank.rows(in: MenuBarIcon.numberRows).isEmpty,
                      "something was drawn in the number's rows with no reading")
        XCTAssertFalse(blank.rows(in: Self.barBand).isEmpty,
                       "the dashed bar is missing too: the measurement is not about the number")
        XCTAssertFalse(try render(0).rows(in: MenuBarIcon.numberRows).isEmpty,
                       "a genuine 0% drew no number")
    }

    /// And what decides that is the snapshot, not the drawing: a failed poll
    /// keeps its previous numbers on purpose, so `fleetSevenDayMean` alone is
    /// not enough to say there is a reading.
    ///
    /// The half that failed is what decides it, though — the figure comes from
    /// `/gw/usage` and from nowhere else. Blanking it on any failure meant that
    /// `/gw/sessions`, which feeds the per-project spend and has nothing to do
    /// with quotas, wiped a quota reading that had arrived in the same pass,
    /// intact and a second old.
    func testOnlyAFailureOfTheQuotaHalfTakesTheFigureAway() {
        var snapshot = UsageSnapshot.empty
        snapshot.fleetSevenDayMean = 47.4
        XCTAssertEqual(MenuBarIcon.percent(for: snapshot), 47)
        snapshot.sessionsFailure = "/gw/sessions: unreachable"
        XCTAssertEqual(MenuBarIcon.percent(for: snapshot), 47,
                       "the sessions endpoint knows nothing about quotas")
        snapshot.quotaFailure = "/gw/usage: unreachable"
        XCTAssertNil(MenuBarIcon.percent(for: snapshot))
        snapshot.quotaFailure = nil
        snapshot.fleetSevenDayMean = nil
        XCTAssertNil(MenuBarIcon.percent(for: snapshot))
    }

    /// The bar says the same thing the number does. Measured as area, because
    /// the outline spans the whole bar in every state and a span would not tell
    /// an empty bar from a full one.
    func testTheBarFillsUpWithTheFigure() throws {
        let inked = try [nil, 0, 50, 100].map { try render($0).pixels(in: Self.barBand) }
        // Dashed and empty is the least ink of all; a bar drawn 0% full is a
        // solid outline and already more.
        XCTAssertLessThan(inked[0], inked[1], "the dashed empty bar is not the emptiest: \(inked)")
        XCTAssertLessThan(inked[1], inked[2], "0% is not emptier than 50%: \(inked)")
        XCTAssertLessThan(inked[2], inked[3], "50% is not emptier than 100%: \(inked)")
    }

    /// Above the top of the scale the quota is spent, and the picture says so
    /// rather than growing a column for a fourth digit.
    func testAFigureAboveTheScaleIsDrawnAsAFullBar() throws {
        let full = try render(100)
        let over = try render(140)
        XCTAssertEqual(over.width, full.width, accuracy: 0.001)
        XCTAssertEqual(MenuBarIcon.label(forPercent: 140).string, "100%")
        XCTAssertEqual(MenuBarIcon.label(forPercent: -20).string, "0%")
    }
}

/// `NSApp.hide` has four states of this app's own that make it destructive
/// (§4). Two of them were found by probing; the third arrived with the popover
/// and the fourth with the menu the popover has to make room for.
@MainActor
final class HideSafetyTests: XCTestCase {

    func testHidingIsSafeOnlyWhenNothingOfOursIsUp() {
        XCTAssertTrue(PanelController.canHideApp(modal: false, menuTrackingDepth: 0,
                                                 menuOpening: false, popoverOpen: false))
        XCTAssertFalse(PanelController.canHideApp(modal: true, menuTrackingDepth: 0,
                                                  menuOpening: false, popoverOpen: false))
        XCTAssertFalse(PanelController.canHideApp(modal: false, menuTrackingDepth: 1,
                                                  menuOpening: false, popoverOpen: false))
        // `hide` takes every window of the app down, the popover among them, and
        // the auto-hide fires 400 ms after the pointer leaves the panel — with
        // the popover still open under the menu bar.
        XCTAssertFalse(PanelController.canHideApp(modal: false, menuTrackingDepth: 0,
                                                  menuOpening: false, popoverOpen: true))
    }

    /// The fourth state is the only one that is not about what is on screen but
    /// about what is one instruction away from it.
    ///
    /// Putting the status menu up begins by closing the popover, and that close
    /// hands the keyboard back: with the menu asked for but not yet tracked,
    /// nothing answered no, and the hide landed in the gap — cancelling a
    /// tracking that had not started, so the menu collapsed under the pointer
    /// that asked for it. The order of the two lines is not a defence; it holds
    /// only while AppKit delivers the close synchronously, which is nobody's
    /// promise.
    func testAMenuOnItsWayUpCountsAsAMenuAlreadyUp() {
        XCTAssertFalse(PanelController.canHideApp(modal: false, menuTrackingDepth: 0,
                                                  menuOpening: true, popoverOpen: false))
        // And it is the flag alone that says so: nothing else about that instant
        // is different from the safe state above.
        XCTAssertTrue(PanelController.canHideApp(modal: false, menuTrackingDepth: 0,
                                                 menuOpening: false, popoverOpen: false))
    }

    /// The rule above is a pure function and was held as one; the pair of calls
    /// that puts it into that state was held by nothing. Both halves were probed
    /// by breaking them, and either break went green through the whole suite as
    /// it then stood.
    ///
    /// The clearing half is the dangerous one, and it is the one state of
    /// `canHideApp` with no way back: the tracking count is reconciled with
    /// reality before every retry and a modal is asked of the system anew, but a
    /// flag left set answers "no, do not hide" for the rest of the run. The
    /// keyboard is then never handed back again — §4's "typing into nowhere",
    /// silently and permanently — while the retry timer goes on waking the
    /// process five times a second forever.
    ///
    /// No AppKit state of any kind is needed for it, which is the other half of
    /// why it went unheld: it looked like it would.
    func testTheMenuFlagIsBothSetAndCleared() {
        let controller = PanelController(config: .default, store: SnapshotStore(config: .default))
        XCTAssertFalse(controller.menuOpening, "a fresh controller is already standing in for a menu")
        controller.menuWillOpen()
        XCTAssertTrue(controller.menuOpening, "the gap before the tracking begins is not covered")
        controller.menuOpeningDidFinish()
        XCTAssertFalse(controller.menuOpening, "the flag stuck: the keyboard is never handed back again")
    }
}

/// The left click on the status item, and the press it must not answer twice.
@MainActor
final class StatusItemClickTests: XCTestCase {

    private let closed = Date(timeIntervalSince1970: 1_786_800_000)

    /// A transient popover is dismissed on the mouse-*down*, while the status
    /// item's action is sent on the mouse-*up* of the same press — so the click
    /// that closed it could open it again, and the user would see a blink where
    /// they had asked for a close. Nothing identifies the two halves as one
    /// press; what marks them is that the button was still down at the close.
    func testTheClickThatDismissedThePopoverDoesNotReopenIt() {
        var dismissal = PopoverDismissal()
        dismissal.popoverClosed(at: closed, midPress: true)
        XCTAssertTrue(dismissal.shouldIgnoreClick(at: closed.addingTimeInterval(0.01)),
                      "the second half of the press that closed it opened it again")
    }

    /// And what the window measures is not the length of that press. On the
    /// measured path the dismissing press never reaches the action at all (see
    /// `toggleUsagePopover`), so the mark it leaves is spent by the *next*
    /// click — which makes the interval bounded here the pause between two
    /// clicks, and the window's price a deliberate second click swallowed.
    ///
    /// An ordinary double click on the status item is `down#1 → up#2`, 200–350
    /// ms end to end. At the 0.4 s this window used to be, the whole of that
    /// range was inside it: the popover closed on the first click and did not
    /// come back on the second.
    func testADeliberateDoubleClickIsAnswered() {
        var dismissal = PopoverDismissal()
        dismissal.popoverClosed(at: closed, midPress: true)
        XCTAssertFalse(dismissal.shouldIgnoreClick(at: closed.addingTimeInterval(0.3)),
                       "the second click of an ordinary double click was swallowed")
    }

    /// One press, one answer. Asking spends the mark, so the click after it —
    /// however soon — is somebody's first half and gets its popover.
    ///
    /// Which is what bounds the cost of the window to a single click: on the
    /// measured path the mark is spent by the next click rather than by the
    /// press that left it, and that one click is the whole of what a window set
    /// too wide can swallow.
    func testTheMarkIsSpentByTheClickItAnswersFor() {
        var dismissal = PopoverDismissal()
        dismissal.popoverClosed(at: closed, midPress: true)
        XCTAssertTrue(dismissal.shouldIgnoreClick(at: closed.addingTimeInterval(0.01)))
        XCTAssertFalse(dismissal.shouldIgnoreClick(at: closed.addingTimeInterval(0.02)),
                       "the same close was answered for twice")
    }

    /// A close with no button down is not a press at all: Esc, a click that
    /// landed elsewhere and finished there, `showStatusMenu`'s own
    /// `performClose`. Nothing is armed, so the very next click opens the
    /// popover — the old window swallowed it if it came quickly enough.
    func testACloseThatWasNotAPressArmsNothing() {
        var dismissal = PopoverDismissal()
        dismissal.popoverClosed(at: closed, midPress: false)
        XCTAssertFalse(dismissal.shouldIgnoreClick(at: closed.addingTimeInterval(0.01)),
                       "a dismissal by Esc swallowed the click after it")
    }

    /// And it does more than arm nothing: it disarms. A close with no button
    /// down clears a mark an earlier press left, rather than leaving it to be
    /// spent by a click that has nothing to do with it.
    ///
    /// Unreachable in practice, and pinned all the same. Two closes with no
    /// click between them need the popover reopened in between, and reopening it
    /// *is* a click — the one that spends the mark. But the type takes the state
    /// directly, so holding the `: nil` half costs three lines, and every other
    /// clause of this rule is held by name rather than by a comment saying it
    /// cannot happen.
    func testACloseThatWasNotAPressClearsAMarkAlreadyArmed() {
        var dismissal = PopoverDismissal()
        dismissal.popoverClosed(at: closed, midPress: true)
        dismissal.popoverClosed(at: closed.addingTimeInterval(0.01), midPress: false)
        XCTAssertFalse(dismissal.shouldIgnoreClick(at: closed.addingTimeInterval(0.02)),
                       "a mark left by an earlier press outlived the close that should have cleared it")
    }

    /// The window is the backstop for a second half that never arrives, and both
    /// its sides are the constant's.
    ///
    /// A millisecond off either edge rather than on it: a `Date` this far from
    /// its epoch resolves to a fraction of a microsecond, so the difference of
    /// two of them a nominal window apart comes back a hair short of it (0.4 s
    /// measured as 0.39999997, while that was the constant) — the exact boundary
    /// is not a thing a test can stand on, and standing on it made this
    /// assertion fail while the rule was right.
    func testBothSidesOfTheWindow() {
        let window = PopoverDismissal.suppressionWindow
        var inside = PopoverDismissal()
        inside.popoverClosed(at: closed, midPress: true)
        XCTAssertTrue(inside.shouldIgnoreClick(at: closed.addingTimeInterval(window - 0.001)))

        var outside = PopoverDismissal()
        outside.popoverClosed(at: closed, midPress: true)
        XCTAssertFalse(outside.shouldIgnoreClick(at: closed.addingTimeInterval(window + 0.001)))

        // And the constant is bounded on the side the measurement moved it to.
        // What it bounds is the pause between two clicks, so its cost is a
        // second click swallowed — and an ordinary double click on the icon has
        // its two ends 200–350 ms apart. At the 0.4 s it used to be, all of
        // that was inside; the band left has to be narrower than the gesture it
        // can eat.
        XCTAssertLessThan(window, 0.35, "an ordinary double click is swallowed whole")
        // Not nothing, either: the case it stands for is a press whose action
        // does arrive, and a window shorter than a brisk press catches none.
        XCTAssertGreaterThan(window, 0.2, "the window is too short for the press it stands for")
    }

    /// Never closed, nothing to suppress: the first click of all opens it.
    func testTheFirstClickOfAllOpensIt() {
        var dismissal = PopoverDismissal()
        XCTAssertFalse(dismissal.shouldIgnoreClick(at: closed))
    }
}

/// The other half of §4's hand-back: not *may* the app hide, but *does it owe*
/// anyone the keyboard. Every step below is a call the app makes in that order.
final class ActivationDebtTests: XCTestCase {

    /// The sequence the popover's activation used to be lost in, and the reason
    /// the debt is one account rather than one flag per activator.
    ///
    /// Reachable by hand in seconds: click the status item (the app activates
    /// for the popover), take the pointer to the left edge (the panel comes up),
    /// dismiss the popover with Esc. The popover's own hand-back declines —
    /// rightly, the panel is on screen — and the panel's hand-back used to know
    /// nothing about an activation it had not performed itself. The panel then
    /// slid away and left the app frontmost with no window at all: §4's defect,
    /// the one where the user's typing goes nowhere until they click something.
    func testAnActivationForThePopoverIsHandedBackWhenThePanelGoesAway() {
        var debt = ActivationDebt()
        debt.activated()
        XCTAssertEqual(debt.settle(panelVisible: true, appActive: true, canHide: true), .nothing,
                       "the panel is up: the app is in front for its sake")
        XCTAssertTrue(debt.isOwed, "the debt was written off while the panel stood in for it")
        XCTAssertEqual(debt.settle(panelVisible: false, appActive: true, canHide: true), .hide)
        XCTAssertEqual(debt.settle(panelVisible: false, appActive: true, canHide: true), .nothing,
                       "hidden twice for one activation")
    }

    /// Nothing owed, nothing given back — the panel that never activated (no
    /// search, no popover) must not hide the app when it goes away.
    func testAPanelThatNeverActivatedOwesNothing() {
        var debt = ActivationDebt()
        XCTAssertFalse(debt.isOwed)
        XCTAssertEqual(debt.settle(panelVisible: false, appActive: true, canHide: true), .nothing)
    }

    /// A row click hands the front slot to the editor by itself. Hiding after
    /// that would be hiding somebody else's window, so the debt is written off
    /// instead of being paid.
    func testTheFrontSlotGoneElsewhereSettlesTheDebtWithoutHiding() {
        var debt = ActivationDebt()
        debt.activated()
        XCTAssertEqual(debt.settle(panelVisible: false, appActive: false, canHide: true), .nothing)
        XCTAssertFalse(debt.isOwed)
    }

    /// Something of ours in the way — a modal, a menu being tracked, the popover
    /// itself — postpones the hand-back rather than dropping it. Dropped, the
    /// app stays frontmost with nothing to type into and nothing left to notice.
    func testAnObstacleOnlyPostponesTheHandBack() {
        var debt = ActivationDebt()
        debt.activated()
        XCTAssertEqual(debt.settle(panelVisible: false, appActive: true, canHide: false), .retry)
        XCTAssertTrue(debt.isOwed)
        XCTAssertEqual(debt.settle(panelVisible: false, appActive: true, canHide: true), .hide)
    }
}

/// The row's second number: what it says, and what it says when it does not
/// know. The layout of it is `RowLayoutTests`; this is the text.
@MainActor
final class RowSpendTests: XCTestCase {

    private func row(_ usage: TokenCounts?, topic: String? = "тема") -> SwitcherRow {
        SwitcherRow(id: "project:/tmp/p",
                    kind: .project,
                    displayName: "vscode-switcher",
                    colorHex: "#000000",
                    project: nil,
                    window: nil,
                    sessions: [],
                    state: nil,
                    activeSubagents: 0,
                    subagentDescriptions: [],
                    chatTopic: topic,
                    model: nil,
                    contextUsedTokens: nil,
                    contextLimitTokens: nil,
                    lastActivity: nil,
                    usage: usage)
    }

    /// The same figure the dump prints, rounded the same way — one formatter,
    /// because a dump that rounds differently describes a row the panel does not
    /// draw.
    func testTheNumberIsTheOneTheDumpPrints() {
        let complete = TokenCounts(input: 1_000_000, output: 200_000,
                                   cacheCreation: 400_000, cacheRead: 9_000_000)
        XCTAssertEqual(SwitcherRowView.usageLabel(for: row(complete)), "3.40M")
        XCTAssertEqual(ConsoleDump.usageCell(for: row(complete)), "3.40M")
        XCTAssertEqual(SwitcherRowView.usageLabel(for: row(TokenCounts(input: 900, output: 0,
                                                                      cacheCreation: 0,
                                                                      cacheRead: 0))), "900")
    }

    /// A number with an unnamed counter behind it is a lower bound, and the row
    /// has to say so — `≥` here, `>=` in the dump, the same fact either way.
    func testALowerBoundWearsItsMark() {
        let partial = TokenCounts(input: 1_000_000, output: nil, cacheCreation: nil, cacheRead: nil)
        XCTAssertEqual(SwitcherRowView.usageLabel(for: row(partial)), "≥1.00M")
        XCTAssertTrue(ConsoleDump.usageCell(for: row(partial)).hasPrefix(">="))
        // And a complete one does not wear it.
        let complete = TokenCounts(input: 1_000_000, output: 0, cacheCreation: 0, cacheRead: 0)
        XCTAssertEqual(SwitcherRowView.usageLabel(for: row(complete)), "1.00M")
    }

    /// No figure at all, and a figure in which the gateway named nothing, both
    /// draw nothing. The second is the one worth a test: `weighted()` folds an
    /// unnamed counter in as zero, so such a row would otherwise show a
    /// confident `0` where the honest answer is "no idea" (§2.4).
    func testNothingKnownDrawsNothingRatherThanAZero() {
        XCTAssertNil(SwitcherRowView.usageLabel(for: row(nil)))
        let blank = TokenCounts(input: nil, output: nil, cacheCreation: nil, cacheRead: nil)
        XCTAssertNil(SwitcherRowView.usageLabel(for: row(blank)))
        XCTAssertEqual(SwitcherRowView.usageLabel(for: row(.zero)), nil)
    }

    /// The one number in the row is input-equivalent — four counters folded at
    /// four different prices — so the tooltip carries the four the gateway
    /// actually named. An unnamed one is `?`, never 0.
    func testTheTooltipBreaksTheNumberIntoTheFourCounters() {
        let text = SwitcherRowView.tooltipText(for: row(TokenCounts(input: 1_000_000,
                                                                   output: 200_000,
                                                                   cacheCreation: 400_000,
                                                                   cacheRead: 9_000_000)))
        XCTAssertTrue(text.contains("Tokens (input-equivalent): 3.40M"), text)
        XCTAssertTrue(text.contains("• in 1.00M"), text)
        XCTAssertTrue(text.contains("• out 200k"), text)
        XCTAssertTrue(text.contains("• cache write 400k"), text)
        XCTAssertTrue(text.contains("• cache read 9.00M"), text)

        let partial = SwitcherRowView.tooltipText(for: row(TokenCounts(input: 50, output: nil,
                                                                      cacheCreation: nil,
                                                                      cacheRead: 5_401_028)))
        XCTAssertTrue(partial.contains("• out ?"), partial)
        XCTAssertTrue(partial.contains("• cache write ?"), partial)
        XCTAssertTrue(partial.contains("Tokens (input-equivalent): ≥540k"), partial)
    }

    /// And a row with no spend says nothing about spend, rather than saying zero.
    func testTheTooltipSaysNothingWhenThereIsNothingToSay() {
        XCTAssertFalse(SwitcherRowView.tooltipText(for: row(nil)).contains("Tokens"))
        let blank = TokenCounts(input: nil, output: nil, cacheCreation: nil, cacheRead: nil)
        XCTAssertFalse(SwitcherRowView.tooltipText(for: row(blank)).contains("Tokens"))
    }

    /// The path stays the last line of a project row (§4) — the counters go in
    /// front of it, not after.
    func testThePathIsStillTheLastLine() {
        var built = row(TokenCounts(input: 10, output: 10, cacheCreation: 10, cacheRead: 10))
        built.project = TestFixtures.project(path: "/tmp/home-network", rootName: "home-network")
        let lines = SwitcherRowView.tooltipText(for: built).split(separator: "\n")
        XCTAssertEqual(lines.last, "/tmp/home-network")
    }
}

/// A gateway that answers each account it knows with one flat line at the level
/// it is handed, ten samples a minute apart.
///
/// Flat, so where ink lands in the picture is a fact about the chart rather than
/// about the fixture. Shared by the two classes that draw one: `UsageHistoryTests`
/// weighs the ink of the plot, `UsagePopoverPaintTests` reads its colour.
///
/// `silentOnUnknown` is the difference between the two. Off, an account nobody
/// named a level for answers a flat zero, which is what a test about where a line
/// sits wants for the accounts it is not asking about. On, the request for it
/// fails — and that is how an account comes to be named by the quota poll and
/// missing from the chart, one of the two states the colours are told apart in.
private func flatHistoryClient(readings: [String: Double],
                               silentOnUnknown: Bool = false) -> UsageClient {
    UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
        let url = request.url ?? Config.default.resolvedUsageBaseURL
        // .../gw/usage/<label>/history
        let label = url.pathComponents.dropLast().last ?? ""
        guard let value = readings[label] ?? (silentOnUnknown ? nil : 0) else {
            throw UsageError.unreachable("no history for \(label)")
        }
        let points = (0..<10).map { index in
            "{\"ts\": \(1_786_700_000 + index * 60), \"util_7d\": \(value)}"
        }
        let body = "{\"label\": \"\(label)\", \"since\": 1786700000,"
            + " \"points\": [\(points.joined(separator: ","))]}"
        guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                             httpVersion: nil, headerFields: nil) else {
            throw UsageError.unreachable("no test response")
        }
        return (Data(body.utf8), response)
    }
}

/// The popover's chart: what it fetches, when it fetches it, and what it does
/// with a hole in the data.
@MainActor
final class UsageHistoryTests: XCTestCase {

    /// Counts the requests a stub transport was handed, and remembers their URLs.
    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []
        var urls: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func record(_ url: URL?) {
            guard let url else { return }
            lock.lock()
            stored.append(url)
            lock.unlock()
        }
    }

    /// One suite for the whole class, wiped around every test.
    ///
    /// A suite name is a file in the user's preferences, and a fresh name per
    /// test would leave one behind on every run — the machine these tests are
    /// written on is somebody's working machine. Wiping the domain is what makes
    /// each test start clean.
    ///
    /// It does not make the run leave nothing behind, and the promise was
    /// trimmed to what it actually keeps: `removePersistentDomain` empties the
    /// domain, and `~/Library/Preferences/<suite>.plist` stays as an empty
    /// 42-byte file. Deleting the file here would be writing behind `cfprefsd`'s
    /// back, which holds the domain in memory and may write it out again after
    /// the last test — so one empty file per machine is the cost, and no value
    /// of ours survives in it.
    private static let suiteName = "xyz.vvzvlad.vscode-switcher.tests"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    /// Whether the stub gateway is answering at the moment. The interesting
    /// cases here are all changes of that partway through: a gateway is not up
    /// or down for a whole test, it goes away under an open popover.
    private final class Gateway: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = true
        var answers: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }

    /// Answers every history request from the fixture, and counts them.
    private func client(_ counter: RequestCounter, gateway: Gateway = Gateway()) -> UsageClient {
        UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            counter.record(request.url)
            guard gateway.answers else { throw UsageError.unreachable("the gateway is not there") }
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(UsageFixtures.history.utf8), response)
        }
    }

    private func model(_ counter: RequestCounter,
                       defaults: UserDefaults) -> UsageHistoryModel {
        UsageHistoryModel(client: client(counter), defaults: defaults)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName) ?? .standard
    }

    /// The whole reason this schedule is separate from `UsageStore`'s: a closed
    /// popover costs nothing. Not "almost nothing" — no request at all, whatever
    /// is poked at it.
    ///
    /// Poked *after* an open, on purpose. A model that has never been opened
    /// knows no accounts, so it asks for nothing however broken its guard is:
    /// the first version of this test passed with the guard deleted. The
    /// accounts have to be in hand for the guard to be the only thing stopping
    /// the requests.
    func testAClosedPopoverAsksForNothing() async {
        let counter = RequestCounter()
        let history = model(counter, defaults: freshDefaults())
        // Nothing before the first open either.
        history.fetch()
        await history.fetchTask?.value
        XCTAssertEqual(counter.urls.count, 0, "asked before ever being opened: \(counter.urls)")

        history.open(labels: ["acc1", "acc2"])
        await history.fetchTask?.value
        let asked = counter.urls.count
        XCTAssertEqual(asked, 2)

        history.close()
        history.fetch()
        history.update(labels: ["acc1", "acc2", "acc3"])
        history.period = .month
        await history.fetchTask?.value
        XCTAssertEqual(counter.urls.count, asked, "asked while closed: \(counter.urls)")
    }

    /// Opening asks once for each account, on the account's own endpoint, for
    /// the chosen window.
    func testOpeningAsksOnceForEveryAccount() async {
        let counter = RequestCounter()
        let history = model(counter, defaults: freshDefaults())
        history.period = .hour
        history.open(labels: ["acc1", "acc2"])
        await history.fetchTask?.value
        defer { history.close() }

        XCTAssertEqual(Set(counter.urls.map(\.path)),
                       ["/gw/usage/acc1/history", "/gw/usage/acc2/history"])
        XCTAssertEqual(counter.urls.count, 2)
        XCTAssertEqual(history.series.map(\.label), ["acc1", "acc2"])
        // The window asked for is the period, to the second.
        let since = try? XCTUnwrap(counter.urls.first?.query?
            .split(separator: "=").last.flatMap { Double($0) })
        XCTAssertEqual(Date().timeIntervalSince1970 - (since ?? 0),
                       HistoryPeriod.hour.seconds, accuracy: 5)
    }

    /// And closing it stops the schedule: a tick after the close asks for
    /// nothing more.
    func testClosingStopsTheSchedule() async {
        let counter = RequestCounter()
        let history = model(counter, defaults: freshDefaults())
        history.open(labels: ["acc1"])
        await history.fetchTask?.value
        let asked = counter.urls.count
        history.close()
        history.fetch()
        await history.fetchTask?.value
        XCTAssertEqual(counter.urls.count, asked)
        XCTAssertFalse(history.isOpen)
    }

    /// A new period is a new chart, so it is asked for at once — and remembered,
    /// because the popover is not the panel: its state is a preference, not a
    /// fresh question at every appearance (§4).
    func testThePeriodIsRefetchedAndRemembered() async {
        let counter = RequestCounter()
        let defaults = freshDefaults()
        let history = model(counter, defaults: defaults)
        XCTAssertEqual(history.period, .day, "the default period is not the documented one")
        history.open(labels: ["acc1"])
        await history.fetchTask?.value
        history.period = .month
        await history.fetchTask?.value
        history.close()

        XCTAssertEqual(counter.urls.count, 2, "changing the period did not refetch")
        XCTAssertEqual(UsageHistoryModel(client: UsageClient(baseURL: Config.default.resolvedUsageBaseURL),
                                         defaults: defaults).period,
                       .month,
                       "the period did not outlive the model")
    }

    /// The pass must not need the main thread — the same rule as
    /// `UsageStore.poll` (§6) and the same trap under it: everything `load`
    /// touches is declared on a `@MainActor` class, so one read of a `static let`
    /// that lost its `nonisolated`, or the loss of `nonisolated` on `load`
    /// itself, silently moves the whole thing onto the main thread. There is no
    /// diagnostic for it under `-strict-concurrency=complete`; it was found in
    /// the store by sampling a `--dump` that never returned.
    ///
    /// Here it would be quieter still: two to five HTTP requests, each up to five
    /// seconds, run from a popover that is open at that very moment — the app
    /// would simply stop redrawing while the user looked at it.
    ///
    /// A timed wait rather than an open one, so a regression is a failed test
    /// and not a run that hangs. Checked by breaking: reading
    /// `UsageHistoryModel.refreshSeconds` (a `static let` on the `@MainActor`
    /// class) inside `load` fails it after the timeout instead of passing in
    /// milliseconds.
    func testLoadDoesNotNeedTheMainThread() {
        let counter = RequestCounter()
        let client = client(counter)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await UsageHistoryModel.load(client: client, labels: ["acc1", "acc2"],
                                             since: Date().addingTimeInterval(-3600))
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success,
                       "the pass waited for a main thread that is standing right here")
        XCTAssertEqual(counter.urls.count, 2, "the pass finished without asking for anything")
    }

    /// A `null` sample is a hole, not a reading of zero: the line breaks there.
    /// Joining across it — which is what dropping the sample does — draws a
    /// straight line through a stretch nobody measured.
    func testAHoleBreaksTheLineInsteadOfBeingJoinedAcross() throws {
        // Decoded rather than constructed: `HistoryPoint` has only the wire
        // format's initialiser, and the wire format is where a hole comes from.
        func points(_ readings: [Double?]) throws -> [HistoryPoint] {
            let body = readings.enumerated().map { index, value in
                "{\"ts\": \(1_786_700_000 + index * 60), \"util_7d\": \(value.map { "\($0)" } ?? "null")}"
            }
            return try UsageFixtures.decode("[\(body.joined(separator: ","))]", as: [HistoryPoint].self)
        }
        let series = AccountSeries.make(label: "acc1", points: try points([10, 12, nil, 20, 22]))
        XCTAssertEqual(series.segments.count, 2, "the hole did not break the line")
        XCTAssertEqual(series.segments.map(\.readings.count), [2, 2])
        XCTAssertEqual(Set(series.segments.map(\.id)).count, 2, "two runs share a series key")
        XCTAssertFalse(series.isEmpty)

        // A series of nothing but holes has nothing to draw, and says so rather
        // than drawing a flat line at zero.
        XCTAssertTrue(AccountSeries.make(label: "acc1", points: try points([nil, nil])).isEmpty)
    }

    /// A pass that finished and a pass that brought lines are two facts, and the
    /// chart is entitled to be told which one happened.
    ///
    /// One stamp for both said "the answer is in" after a pass in which every
    /// account failed, and the chart then announced that the period held no
    /// data — a statement the gateway had not made and could not have, having
    /// made none. The schedule still needs the other fact, or a first pass that
    /// failed would stop the refresh dead for as long as the popover stays open.
    func testAPassNobodyAnsweredIsNotAnAnswer() async throws {
        let counter = RequestCounter()
        let gateway = Gateway()
        gateway.answers = false
        let history = UsageHistoryModel(client: client(counter, gateway: gateway),
                                        defaults: freshDefaults())
        history.open(labels: ["acc1", "acc2"])
        await history.fetchTask?.value
        defer { history.close() }

        XCTAssertEqual(counter.urls.count, 2, "the pass never reached the gateway")
        XCTAssertNil(history.fetchedAt, "a pass nobody answered dated the lines all the same")
        XCTAssertNotNil(history.checkedAt, "the attempt left no clock for the refresh to run on")
        XCTAssertNotNil(history.failure)

        // And this is what the popover then writes under the empty plot.
        var snapshot = UsageSnapshot.empty
        snapshot.quotaFetchedAt = Date()
        snapshot.accounts = try UsageFixtures.decode(UsageFixtures.usage, as: UsageReport.self).accounts
        XCTAssertEqual(UsagePopoverView.plotEmptyLabel(snapshot: snapshot,
                                                       seriesFetchedAt: history.fetchedAt,
                                                       seriesPeriod: history.seriesPeriod,
                                                       period: history.period,
                                                       historyFailure: history.failure),
                       "Gateway did not answer")
    }

    /// The other side of it: a failed pass leaves the lines it did not replace
    /// exactly as they were, stamp included. Slightly stale beats blank — but a
    /// stamp that moved would call them fresh.
    func testAFailedPassKeepsTheLinesAndTheirAge() async {
        let counter = RequestCounter()
        let gateway = Gateway()
        let history = UsageHistoryModel(client: client(counter, gateway: gateway),
                                        defaults: freshDefaults())
        history.open(labels: ["acc1"])
        await history.fetchTask?.value
        let landed = history.fetchedAt
        XCTAssertNotNil(landed)

        gateway.answers = false
        history.fetch()
        await history.fetchTask?.value
        defer { history.close() }

        XCTAssertEqual(history.series.map(\.label), ["acc1"], "the failed pass blanked the chart")
        XCTAssertEqual(history.fetchedAt, landed, "the failed pass re-dated lines it did not bring")
        XCTAssertNotNil(history.failure)
    }

    /// And it goes on asking. The refresh is keyed on the attempt, not on the
    /// lines: keyed on the lines it would stop dead precisely when the gateway
    /// is down — the first failed pass leaves none — and the chart would then
    /// sit unrefreshed for as long as the popover is open, a transient failure
    /// quietly becoming a permanent one.
    func testTheRefreshGoesOnAskingAfterAPassThatBroughtNothing() async {
        let counter = RequestCounter()
        let gateway = Gateway()
        gateway.answers = false
        let history = UsageHistoryModel(client: client(counter, gateway: gateway),
                                        defaults: freshDefaults())
        history.open(labels: ["acc1"])
        await history.fetchTask?.value
        defer { history.close() }
        let asked = counter.urls.count
        XCTAssertEqual(asked, 1)
        XCTAssertNil(history.fetchedAt, "the failed pass dated lines that never came")

        // Not on every tick, though: the clock behind the wording runs four
        // times a minute, the pass once.
        history.tick(now: Date().addingTimeInterval(UsageHistoryModel.refreshSeconds / 2))
        await history.fetchTask?.value
        XCTAssertEqual(counter.urls.count, asked, "asked again before the interval was up")

        history.tick(now: Date().addingTimeInterval(UsageHistoryModel.refreshSeconds + 1))
        await history.fetchTask?.value
        XCTAssertGreaterThan(counter.urls.count, asked,
                             "a chart whose first pass failed never asked again")
    }

    /// Unless the question changed under them. The picker moves first and the
    /// answer lands after: a pass started for `30d` that fails leaves `1d` lines
    /// on screen with `30d` selected above them — a chart lying about its own
    /// axis, and the one case where blank beats stale.
    func testAFailedPassAfterAChangeOfPeriodDropsTheOldLines() async {
        let counter = RequestCounter()
        let gateway = Gateway()
        let history = UsageHistoryModel(client: client(counter, gateway: gateway),
                                        defaults: freshDefaults())
        history.open(labels: ["acc1"])
        await history.fetchTask?.value
        XCTAssertFalse(history.series.isEmpty)
        XCTAssertEqual(history.seriesPeriod, .day)

        gateway.answers = false
        history.period = .month
        await history.fetchTask?.value
        defer { history.close() }

        XCTAssertTrue(history.series.isEmpty, "lines from another window survived under the new label")
        XCTAssertNil(history.fetchedAt, "the footer went on dating lines that are not there")
        XCTAssertNil(history.seriesPeriod)
    }

    /// And on the pass that *succeeds*, the same lines are just as wrong for the
    /// seconds before it lands.
    ///
    /// `period.didSet` only refetches; it does not touch the series, and the
    /// answer is up to five seconds away through the tunnel. So between the tap
    /// on `30d` and the lines for it there is a whole chart of `1d` data sitting
    /// under the `30d` tab — the same picture lying about its own axis that
    /// `apply` refuses to keep one moment later, shown for as long as the
    /// gateway takes. The drawing site has to ask `seriesPeriod`, which is the
    /// only thing that knows.
    ///
    /// Held at the request the view makes rather than through the view itself:
    /// what the chart draws is a `Charts` tree with no ink of its own to count,
    /// so what is checked is the pair the view branches on and the words it puts
    /// up instead.
    func testTheLinesOfTheOldPeriodAreNotDrawnUnderTheNewOne() async throws {
        let counter = RequestCounter()
        let gateway = Gateway()
        let history = UsageHistoryModel(client: client(counter, gateway: gateway),
                                        defaults: freshDefaults())
        history.open(labels: ["acc1"])
        await history.fetchTask?.value
        defer { history.close() }
        XCTAssertFalse(history.series.isEmpty)
        XCTAssertEqual(history.seriesPeriod, history.period, "the lines answer the period asked for")

        // The picker moves. Nothing else has happened yet: the request is in
        // flight and the lines in hand are the previous window's.
        history.period = .month
        XCTAssertFalse(history.series.isEmpty, "the model blanked the lines by itself")
        XCTAssertNotEqual(history.seriesPeriod, history.period,
                          "the lines on hand answer the period being asked about")

        var snapshot = UsageSnapshot.empty
        snapshot.quotaFetchedAt = Date()
        snapshot.accounts = try UsageFixtures.decode(UsageFixtures.usage, as: UsageReport.self).accounts
        XCTAssertEqual(UsagePopoverView.plotEmptyLabel(snapshot: snapshot,
                                                       seriesFetchedAt: history.fetchedAt,
                                                       seriesPeriod: history.seriesPeriod,
                                                       period: history.period,
                                                       historyFailure: history.failure),
                       "Loading…",
                       "the chart answered for a period nobody has asked the gateway about yet")

        // And the footer must not date lines that are not on screen. The stamp in
        // hand is the previous window's and has not moved; told from it alone, the
        // footer dated a chart the plot above it had replaced with "Loading…".
        // Asked of the model rather than of hand-made arguments, because what is
        // under test here is that the state is reachable at all — it is, on every
        // change of period. Asked far enough in the future for an answer to be
        // audible: inside `footerStaleSeconds` the footer is silent for the
        // ordinary reason and would pass with the rule broken.
        XCTAssertNotNil(history.fetchedAt, "the model left no stamp for the footer to misuse")
        XCTAssertNil(UsagePopoverView.footerAgeLabel(quotaFetchedAt: nil,
                                                     quotaFailed: false,
                                                     chartFetchedAt: history.fetchedAt,
                                                     seriesPeriod: history.seriesPeriod,
                                                     period: history.period,
                                                     chartFailed: false,
                                                     now: history.now.addingTimeInterval(600)),
                      "the footer dated the previous window's lines under the new tab")

        // And when the answer lands the pair agrees again, which is what puts
        // the lines back on screen.
        await history.fetchTask?.value
        XCTAssertEqual(history.seriesPeriod, history.period)
        XCTAssertFalse(history.series.isEmpty)
    }

    /// The same rule at the place that draws, because that is where it was
    /// missing: `plotEmptyLabel` had every input it needed and was never asked,
    /// the chart branching on `series.allSatisfy(\.isEmpty)` alone.
    ///
    /// Ink from a bitmap, the way the row's ladder is measured: between the tap
    /// on `30d` and its answer this section must draw what it draws when it has
    /// nothing — one short line of text — and not a chart of the window before.
    func testTheChartItselfDrawsNoLinesUntilTheyAnswerTheNewPeriod() async throws {
        let counter = RequestCounter()
        let history = UsageHistoryModel(client: client(counter), defaults: freshDefaults())
        let usage = UsageStore(config: .default, cache: UsageCache())
        history.open(labels: ["acc1"])
        await history.fetchTask?.value
        defer { history.close() }

        let withLines = try ink(UsagePopoverView(usage: usage, history: history).plot)
        history.period = .month
        let midChange = try ink(UsagePopoverView(usage: usage, history: history).plot)
        await history.fetchTask?.value
        let answered = try ink(UsagePopoverView(usage: usage, history: history).plot)

        XCTAssertGreaterThan(withLines, 0, "the chart drew nothing at all — the measurement is empty")
        XCTAssertLessThan(midChange, withLines / 3,
                          "the lines of the previous window were drawn under the new tab "
                          + "(\(midChange) inked against \(withLines))")
        XCTAssertGreaterThan(answered, withLines / 3,
                             "the lines never came back once they answered the new period")
    }

    /// A chart of the given flat accounts, drawn and read back.
    private func plotInk(flat readings: [String: Double],
                         band: ClosedRange<Double> = 0...1) async throws -> (inked: Int, coverage: Double) {
        let history = UsageHistoryModel(client: flatHistoryClient(readings: readings),
                                        defaults: freshDefaults())
        let usage = UsageStore(config: .default, cache: UsageCache())
        history.open(labels: readings.keys.sorted())
        await history.fetchTask?.value
        defer { history.close() }
        return try rendered(UsagePopoverView(usage: usage, history: history).plot, band: band)
    }

    /// The band the mean of 100 and 20 runs through, and nothing else does.
    ///
    /// Measured off the rendering rather than reasoned about, and re-measured
    /// after the legend was hidden (§4) — the two rows it used to take went back
    /// to the plot and moved every line in this picture. With the y scale pinned
    /// to 0…100 the plot area now runs from 0% of the picture's height (the 100
    /// grid line) to 84% (the 0 one) and the x labels take the rest, so 60% of the
    /// quota lands at 34%. The row profile, in 2% steps: 1190 and 2368 inked in
    /// the two steps from 32%, against 10 and 4 with the mean line moved out of
    /// the band. The account lines are at 0% and 68%, the 50 grid line at 42% —
    /// none of them is inside.
    private static let meanBand = 0.32...0.36

    /// The band the lower of the two accounts (20) runs through: 1780 inked
    /// against 6 with that account moved up to 100.
    private static let accountBand = 0.67...0.70

    /// The mean line is on the chart, and it is drawn where the mean is.
    ///
    /// Read off a bitmap, the way the row's ladder is measured (§4): a `Charts`
    /// tree has no ink of its own to inspect, and "the line is in the view
    /// hierarchy" is not the claim — the claim is that it is visible. Two flat
    /// accounts at 100 and 20 put their own lines at the top and the middle of
    /// the plot and their mean between them, in a band nothing else crosses;
    /// moving both accounts to 100 takes the mean out of that band with the rest
    /// of the picture unchanged, and what is left is the difference the mean
    /// line makes.
    func testTheMeanLineIsDrawnWhereTheMeanIs() async throws {
        let apart = try await plotInk(flat: ["acc1": 100, "acc2": 20], band: Self.meanBand)
        let together = try await plotInk(flat: ["acc1": 100, "acc2": 100], band: Self.meanBand)
        XCTAssertGreaterThan(apart.inked, 1000,
                             "nothing was drawn between the two accounts: the mean line is missing "
                             + "(\(apart.inked) inked against \(together.inked) with the mean elsewhere)")
        XCTAssertLessThan(together.inked, 100,
                          "something other than the mean draws in the band: the measurement is not "
                          + "about the mean line at all (\(together.inked) inked)")
    }

    /// And it is the one line drawn at full strength: wider than the accounts
    /// and not dimmed, so the eye lands on it first.
    ///
    /// The same picture, one band lower: the mean's band against the band the
    /// second account's own line runs through. Weighed by coverage rather than
    /// counted as ink, because both halves of "heavier" have to be in the
    /// measurement — a line at 55% alpha covers exactly as many pixels as one at
    /// full strength, so counting pixels alone would hold the width and let the
    /// dimming go.
    ///
    /// The threshold is set between the three measurements, not guessed:
    /// re-measured in the taller plot the hidden legend left (§4), 2494.3 of
    /// coverage against 650.5, which is 3.83 times. With the mean's width taken
    /// back down to an account's, 1.54; with the accounts undimmed and the width
    /// kept, 2.11. Both halves fail it, which is what makes both of them
    /// load-bearing rather than one plus a decoration.
    func testTheMeanIsHeavierThanTheLinesItIsTheMeanOf() async throws {
        let readings = ["acc1": 100.0, "acc2": 20.0]
        let mean = try await plotInk(flat: readings, band: Self.meanBand)
        // 20% of the quota lands at 68% of the picture — one account line, drawn
        // the way an account is drawn.
        let account = try await plotInk(flat: readings, band: Self.accountBand)
        XCTAssertGreaterThan(account.coverage, 100,
                             "the account's own band is empty: the two are not being compared")
        XCTAssertGreaterThan(mean.coverage, account.coverage * 3,
                             "the mean is drawn no heavier than the accounts behind it "
                             + "(\(mean.coverage) against \(account.coverage))")
    }

    /// An account that did not answer the history request must not shift the
    /// colours of the ones that did.
    ///
    /// The colours are handed out twice over — to the lines here and to the dots
    /// beside the account names upstairs — from two lists that are the same list
    /// only while every account answers. Keyed on its own list, each side counted
    /// from a different place: with the middle account silent, `acc3`'s line took
    /// `acc2`'s colour while the dot beside its name kept its own, and the dot
    /// then pointed at somebody else's line.
    ///
    /// Asked of the scale rather than of a picture, because that is the whole
    /// mechanism: `styleRange` is where a line's colour is decided, and
    /// `accountColor` is what the dots are drawn with.
    func testAnAccountThatDidNotAnswerDoesNotShiftTheOtherColours() {
        let named = ["acc1", "acc2", "acc3"]
        let answered = [AccountSeries(label: "acc1", segments: []),
                        AccountSeries(label: "acc3", segments: [])]
        let range = UsagePopoverView.styleRange(answered, labels: named)
        XCTAssertEqual(range.count, answered.count + 1, "the scale left part of its domain unstyled")
        XCTAssertEqual(range.first, UsagePopoverView.fleetColor, "the mean lost its place at the head")
        // Each line wears the colour it gets when everybody answers: the silence
        // of `acc2` moved nothing. Asking `accountColor` for each entry instead
        // was no question at all — `styleRange` is `series.map { accountColor(…) }`,
        // so the loop compared the function with itself.
        let whole = UsagePopoverView.styleRange(named.map { AccountSeries(label: $0, segments: []) },
                                                labels: named)
        XCTAssertEqual(range[2], whole[3], "acc3's line changed colour because acc2 went silent")
        XCTAssertEqual(range[1], whole[1])

        // An account the poll no longer names has no place in the palette.
        XCTAssertEqual(UsagePopoverView.accountColor(for: "gone", in: named), .gray)
        // The palette is cycled, so a fleet larger than it has no unstyled tail.
        let many = (0..<(UsagePopoverView.accountColors.count + 2)).map { "acc\($0)" }
        XCTAssertEqual(UsagePopoverView.accountColor(for: many[0], in: many),
                       UsagePopoverView.accountColor(for: many[UsagePopoverView.accountColors.count],
                                                     in: many))
    }

    /// Inked pixels, over an area the size the popover gives the plot.
    private func ink(_ view: some View) throws -> Int {
        try rendered(view).inked
    }

    /// What a rendering put down, over all of the plot or a horizontal band of
    /// it given as fractions of the height from the top edge.
    ///
    /// Two numbers, because the chart says two things with them. `inked` counts
    /// pixels that carry anything at all, which is where a line is and how wide;
    /// `coverage` adds up how much of each, which is the only one of the two a
    /// change of opacity moves — a line at 55% alpha is as "inked" as one at
    /// 100% and half as heavy.
    private func rendered(_ view: some View,
                          band: ClosedRange<Double> = 0...1) throws -> (inked: Int, coverage: Double) {
        let renderer = ImageRenderer(content: view.frame(width: UsagePopoverView.width, height: 130))
        renderer.scale = 2
        let bitmap = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced nothing")
        var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels,
                                              width: bitmap.width,
                                              height: bitmap.height,
                                              bitsPerComponent: 8,
                                              bytesPerRow: bitmap.width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        // Row 0 of a bitmap context's buffer is the top of the image, whichever
        // way the context's own coordinate system runs.
        let first = Int(band.lowerBound * Double(bitmap.height))
        let last = min(bitmap.height, Int((band.upperBound * Double(bitmap.height)).rounded(.up)))
        guard first < last else { return (0, 0) }
        var inked = 0
        var coverage = 0.0
        for offset in stride(from: first * bitmap.width * 4 + 3, to: last * bitmap.width * 4, by: 4) {
            guard pixels[offset] > 8 else { continue }
            inked += 1
            coverage += Double(pixels[offset]) / 255
        }
        return (inked, coverage)
    }
}

/// The chart's main line: the mean of the accounts, and the arithmetic that has
/// to agree with the number over it.
@MainActor
final class FleetMeanTests: XCTestCase {

    /// A moment, `index` minutes into the window the fixtures use.
    private func moment(_ index: Int) -> Date {
        Date(timeIntervalSince1970: 1_786_700_000 + Double(index) * 60)
    }

    /// One account's samples as the gateway sends them: a moment and a reading
    /// that may be missing. Decoded rather than constructed, because
    /// `HistoryPoint` has only the wire format's initialiser — and a hole is a
    /// thing only the wire format can say.
    private func samples(_ readings: [(Int, Double?)]) throws -> [HistoryPoint] {
        let body = readings.map { index, value in
            "{\"ts\": \(1_786_700_000 + index * 60), \"util_7d\": \(value.map { "\($0)" } ?? "null")}"
        }
        return try UsageFixtures.decode("[\(body.joined(separator: ","))]", as: [HistoryPoint].self)
    }

    /// The accounts are not sampled at the same moments, and between its samples
    /// an account is worth the last reading taken of it: utilisation moves when
    /// the gateway looks, not in between.
    func testEachAccountsLastReadingIsCarriedForward() throws {
        let fleet = FleetSeries.make(from: [try samples([(0, 10)]), try samples([(1, 20)])])
        XCTAssertEqual(fleet.points.map(\.timestamp), [moment(0), moment(1)])
        XCTAssertEqual(fleet.points.map(\.accounts), [1, 2])
        XCTAssertEqual(try XCTUnwrap(fleet.points.first).value, 10, accuracy: 0.001)
        // 15, and not the 20 of the account that happened to be sampled last:
        // skipping the accounts with no sample at this exact moment would make
        // the line jump about with the gateway's polling order.
        XCTAssertEqual(try XCTUnwrap(fleet.points.last).value, 15, accuracy: 0.001)
    }

    /// Carried forward, never backwards. An account nobody has read yet has no
    /// value to average in, and a zero in its place is a reading that was never
    /// taken — the same rule `FleetWindow` and `UsageWindow` follow one type up.
    func testAnAccountNobodyHasReadYetIsLeftOutRatherThanCountedAsZero() throws {
        let fleet = FleetSeries.make(from: [try samples([(0, 60), (2, 60)]), try samples([(2, 0)])])
        let first = try XCTUnwrap(fleet.points.first)
        XCTAssertEqual(first.value, 60, accuracy: 0.001,
                       "an account with no reading yet was averaged in as a zero")
        XCTAssertEqual(first.accounts, 1, "the point claims accounts it has no reading for")

        // And once it has been read it counts, zero and all: 0 is a reading here.
        let last = try XCTUnwrap(fleet.points.last)
        XCTAssertEqual(last.value, 30, accuracy: 0.001)
        XCTAssertEqual(last.accounts, 2)
    }

    /// The picture the user pointed at: a week rolls over, one account drops
    /// from a full quota to an empty one, and the mean falls by its share. The
    /// account beside it is not sampled at that moment at all — a reset must not
    /// take the others out of the mean along with it.
    func testAQuotaResetIsCarriedLikeAnyOtherReading() throws {
        let fleet = FleetSeries.make(from: [try samples([(0, 100), (2, 0.5)]),
                                            try samples([(1, 50)])])
        XCTAssertEqual(fleet.points.map(\.timestamp), [moment(0), moment(1), moment(2)],
                       "the reset left a hole in the line")
        XCTAssertEqual(fleet.points.map(\.accounts), [1, 2, 2])
        for (point, expected) in zip(fleet.points, [100.0, 75.0, 25.25]) {
            XCTAssertEqual(point.value, expected, accuracy: 0.001)
        }
    }

    /// A moment nobody has a reading for is no point at all — the line starts
    /// where the measurements start. Drawn as a zero it would state a full quota
    /// where the gateway had said nothing.
    func testAMomentWithNoReadingAtAllIsAGapAndNotAZero() throws {
        let fleet = FleetSeries.make(from: [try samples([(0, nil), (1, 40)]),
                                            try samples([(0, nil), (2, 60)])])
        XCTAssertEqual(fleet.points.map(\.timestamp), [moment(1), moment(2)],
                       "the line began at a moment nobody had a reading for")
        XCTAssertFalse(fleet.points.contains { $0.value == 0 }, "the gap was drawn as a zero")
        XCTAssertNil(FleetSeries.mean(of: []), "the mean of nothing is not zero")
        XCTAssertTrue(FleetSeries.make(from: []).isEmpty)
        XCTAssertTrue(FleetSeries.make(from: [try samples([(0, nil), (1, nil)])]).isEmpty,
                      "nothing but holes drew a line")

        // A hole *after* a reading is not a hole in this line: it says the
        // gateway took no reading at that moment, not that the account's quota
        // changed. The account line breaks there — that one is about what was
        // measured — and the mean carries on at the last measurement.
        let carried = FleetSeries.make(from: [try samples([(0, 40), (1, nil), (2, 40)])])
        XCTAssertEqual(carried.points.map(\.timestamp), [moment(0), moment(1), moment(2)])
        XCTAssertEqual(carried.points.map(\.accounts), [1, 1, 1])
        XCTAssertEqual(AccountSeries.make(label: "acc1",
                                          points: try samples([(0, 40), (1, nil), (2, 40)])).segments.count,
                       2,
                       "the account's own line stopped breaking at a hole")
    }

    /// The end of the line and the number over it are one quantity, and this is
    /// what holds them together.
    ///
    /// They cannot be one call: the headline is `fleet.seven_day.mean` from
    /// `/gw/usage`, the line is built from `/gw/usage/{label}/history`. So what
    /// is held is the rule — the mean of the last known reading of every account
    /// — computed by the one function both sides of it go through. Two accounts
    /// here were last sampled before the third, which is what makes carrying the
    /// difference between agreeing and not.
    func testTheLastPointOfTheMeanIsTheHeadlineFigure() throws {
        let accounts = [try samples([(0, 99), (9, 100)]),
                        try samples([(1, 5)]),
                        try samples([(4, 71), (7, 71.5)])]
        let fleet = FleetSeries.make(from: accounts)
        let last = try XCTUnwrap(fleet.points.last)
        XCTAssertEqual(last.accounts, 3, "the last point is not a mean of the whole fleet")

        // What the gateway averages for the headline: the reading each account
        // currently stands at, which is the last one taken of it.
        let current = accounts.compactMap { $0.compactMap(\.sevenDay).last }
        XCTAssertEqual(current, [100, 5, 71.5])
        var snapshot = UsageSnapshot.empty
        snapshot.fleetSevenDayMean = FleetSeries.mean(of: current)
        XCTAssertEqual(UsagePopoverView.headlinePercent(for: snapshot), 59)
        XCTAssertEqual(UsagePopoverView.headlinePercent(for: snapshot), Int(last.value.rounded()),
                       "the end of the line and the figure above it are two different statements")
    }

    /// The legend gets its entry for the mean from the account list, so a chart
    /// with account lines and no mean line would name a line that is not there.
    /// It cannot happen — both are built from the same samples — and this is the
    /// invariant that makes the empty case unreachable rather than handled.
    func testALineOnTheChartAlwaysHasAMeanOverIt() throws {
        let drawable = try samples([(0, nil), (1, 42)])
        XCTAssertFalse(AccountSeries.make(label: "acc1", points: drawable).isEmpty)
        XCTAssertFalse(FleetSeries.make(from: [drawable]).isEmpty)

        // And the other way about: what draws no account line draws no mean
        // either, which is the state the plot puts its "no data" words up for.
        let holes = try samples([(0, nil), (1, nil)])
        XCTAssertTrue(AccountSeries.make(label: "acc1", points: holes).isEmpty)
        XCTAssertTrue(FleetSeries.make(from: [holes]).isEmpty)
    }
}

/// The sawtooth the two measuring sources put on the chart, and the median that
/// takes it off without touching anything the quota actually did.
@MainActor
final class DespikeTests: XCTestCase {

    /// Samples a minute apart, as the gateway sends them. Decoded rather than
    /// constructed, because a hole is a thing only the wire format can say.
    private func samples(_ readings: [Double?]) throws -> [HistoryPoint] {
        let body = readings.enumerated().map { index, value in
            "{\"ts\": \(1_786_700_000 + index * 60), \"util_7d\": \(value.map { "\($0)" } ?? "null")}"
        }
        return try UsageFixtures.decode("[\(body.joined(separator: ","))]", as: [HistoryPoint].self)
    }

    private func filtered(_ readings: [Double?]) throws -> [Double?] {
        UsageHistoryModel.despiked(try samples(readings)).map(\.sevenDay)
    }

    /// The tooth itself: one sample a point above both of its neighbours, which
    /// agree with each other. 259 of these over three accounts in a week, every
    /// one of amplitude 1 — a `poll` sample standing between two `headers` ones,
    /// most of the time.
    func testASingleToothIsFlattened() throws {
        XCTAssertEqual(try filtered([40, 41, 40]), [40, 40, 40])
        // Downwards as well: 31 of the 259 pointed that way.
        XCTAssertEqual(try filtered([40, 39, 40]), [40, 40, 40])
    }

    /// A step is not a tooth. The quota goes up in ones all day long, and a median
    /// of three keeps every one of those: the difference is whether the neighbours
    /// agree.
    func testAGenuineStepSurvivesWhole() throws {
        XCTAssertEqual(try filtered([40, 41, 41]), [40, 41, 41])
        XCTAssertEqual(try filtered([40, 40, 41, 41, 42, 42]), [40, 40, 41, 41, 42, 42])
    }

    /// And the largest step there is — a week rolling over — survives to the
    /// sample. A filter that took the corner off this would be lying about the one
    /// event the chart exists to show.
    func testAQuotaResetIsNotSmoothedAway() throws {
        XCTAssertEqual(try filtered([87, 87, 3, 3]), [87, 87, 3, 3])
        XCTAssertEqual(try filtered([100, 100, 0, 0, 1]), [100, 100, 0, 0, 1])
    }

    /// The window never reaches across a hole. A `null` says the gateway took no
    /// reading at that moment (§4), and a median through one would invent a
    /// reading out of two on either side of a gap of unknown length.
    func testTheWindowDoesNotReachAcrossAHole() throws {
        XCTAssertEqual(try filtered([40, nil, 80]), [40, nil, 80])
        // The samples either side of a hole are left as they are too — each of
        // them has a window with a `null` in it.
        XCTAssertEqual(try filtered([10, 40, nil, 80, 90]), [10, 40, nil, 80, 90])
        // And a sample that *looks* like a tooth against the reading on the far
        // side of the hole keeps its value: this is where a window that closed
        // over the gap instead of stopping at it would show, and the two cases
        // are the tooth before the hole and the tooth after it.
        XCTAssertEqual(try filtered([40, 41, nil, 40, 40]), [40, 41, nil, 40, 40])
        XCTAssertEqual(try filtered([10, 40, nil, 39, 40]), [10, 40, nil, 39, 40])
        // A tooth on the far side of a hole is still flattened: the hole stops the
        // window, it does not stop the pass.
        XCTAssertEqual(try filtered([10, nil, 40, 41, 40, nil, 10]),
                       [10, nil, 40, 40, 40, nil, 10])
    }

    /// The ends of the series are never touched, and that is a requirement rather
    /// than an omission: the last sample is the "last known value" the end of the
    /// bold line is built from, and that end has to be the figure in the headline
    /// (§4).
    ///
    /// This test is the one that holds it. Not
    /// `testTheLastPointOfTheMeanIsTheHeadlineFigure`, which said so here and in
    /// §4 until it was checked: that one builds `FleetSeries.make` straight out of
    /// samples and never goes through the filter at all.
    func testTheEndsOfTheSeriesAreNeverMoved() throws {
        // Both ends are teeth by shape, and both stay.
        XCTAssertEqual(try filtered([41, 40, 40, 40, 41]), [41, 40, 40, 40, 41])
        XCTAssertEqual(try filtered([0, 50, 50, 50, 100]), [0, 50, 50, 50, 100])
    }

    /// And the *last reading* is never moved either, which is not the same
    /// sentence: a series can end in holes, and then its last reading is not the
    /// last element of the array.
    ///
    /// This is the invariant the end of the bold line rests on, so it is asked
    /// directly rather than left to follow from the two exemptions. It does follow
    /// from them — the last reading either sits at the end of the array, out of the
    /// window's range, or is followed by a `null`, which stops the window — and
    /// that is exactly why no third rule is needed. Checked by breaking both
    /// halves: a window extended over the last element (median of the last three
    /// samples) flattens the first case, and a missing right-hand neighbour filled
    /// in with the reading before it — carrying forward across a hole, the way the
    /// mean legitimately does — flattens the second.
    func testTheLastKnownReadingIsNeverMoved() throws {
        // A tooth by shape at the very end of the array. The window does not reach
        // it.
        XCTAssertEqual(try filtered([40, 40, 40, 41]), [40, 40, 40, 41])
        // The same tooth with nothing but holes after it. Now it is inside the
        // window's range, and what saves it is the hole on its right.
        XCTAssertEqual(try filtered([40, 40, 41, nil]), [40, 40, 41, nil])
        XCTAssertEqual(try filtered([40, 40, 41, nil, nil]), [40, 40, 41, nil, nil])
        // A reset is the case that matters, being the largest step there is: the
        // headline says 3% and the line has to end at 3, however many samples the
        // gateway took no reading for afterwards.
        for holes in 1...4 {
            let readings: [Double?] = [87, 87, 3] + Array(repeating: nil, count: holes)
            XCTAssertEqual(try filtered(readings).compactMap { $0 }.last, 3,
                           "the last reading moved with \(holes) hole(s) after it")
        }
    }

    /// A series too short to have a middle comes back as it was, rather than
    /// coming back empty.
    func testAVeryShortSeriesIsLeftAlone() throws {
        XCTAssertEqual(try filtered([]), [])
        XCTAssertEqual(try filtered([41]), [41])
        XCTAssertEqual(try filtered([41, 40]), [41, 40])
    }

    /// The picture the user pointed at: `poll` samples standing one point per cent
    /// above the `headers` ones around them, over and over. After the filter the
    /// line has no teeth left in it at all.
    ///
    /// The teeth in the live data are *isolated* — a `poll` sample between two
    /// `headers` ones that agree — and that is not an assumption but a
    /// measurement: the filter changed exactly as many samples as the census had
    /// counted teeth (96, 134, 29 against 259 in total, §4). A strict alternation,
    /// every sample disagreeing with the one before it, is the one shape a median
    /// of three does *not* flatten — it moves the phase instead — and its absence
    /// is what those equal counts say, since a run of it would have had the filter
    /// touching samples the census never counted.
    func testTheCombOfTheTwoSourcesComesOutFlat() throws {
        let comb: [Double?] = [38, 39, 38, 38, 39, 38, 38, 39, 38]
        let smooth = try filtered(comb)
        XCTAssertEqual(smooth, [38, 38, 38, 38, 38, 38, 38, 38, 38])
        for index in 1..<(smooth.count - 1) {
            let previous = try XCTUnwrap(smooth[index - 1])
            let value = try XCTUnwrap(smooth[index])
            let next = try XCTUnwrap(smooth[index + 1])
            XCTAssertFalse(value != previous && value != next && previous == next,
                           "a tooth survived at \(index): \(smooth)")
        }

        // And whatever the shape, the filter only ever picks one of the three
        // readings in front of it: it cannot invent a level the gateway never
        // measured, which is what an averaging filter here would do.
        let alternating: [Double?] = [38, 39, 38, 39, 38, 39]
        for value in try filtered(alternating) {
            XCTAssertTrue([38, 39].contains(try XCTUnwrap(value)),
                          "the filter produced a reading nobody measured")
        }

        // Which is also the shape that says where the medians are taken from, and
        // it has to be asked as the whole array. Every median is over the samples
        // as they *arrived*: reading the left neighbour out of the output instead
        // makes the filter creep, each pass carrying its own last answer forward
        // — and the two agree on "38 or 39" at every position, which is all the
        // loop above can see. Strict alternation is the one shape a median of
        // three does not flatten, so it is the one shape the two disagree over:
        // the creeping filter flattens it to a line, having smoothed its own
        // smoothing.
        XCTAssertEqual(try filtered(alternating), [38, 38, 39, 38, 39, 39],
                       "the medians were taken over readings the filter had already moved")
    }

    /// `util_5h` is not filtered and the timestamps are not moved: the filter is
    /// about the one quantity this chart draws, and a sample that changed its
    /// moment would move the line sideways.
    func testNothingButTheSevenDayReadingIsTouched() throws {
        let body = (0..<3).map { index in
            "{\"ts\": \(1_786_700_000 + index * 60), \"util_5h\": \(index == 1 ? 91 : 4),"
                + " \"util_7d\": \(index == 1 ? 41 : 40)}"
        }
        let points = try UsageFixtures.decode("[\(body.joined(separator: ","))]",
                                              as: [HistoryPoint].self)
        let filtered = UsageHistoryModel.despiked(points)
        XCTAssertEqual(filtered.map(\.sevenDay), [40, 40, 40])
        XCTAssertEqual(filtered.map(\.fiveHour), [4, 91, 4], "the five-hour window was filtered too")
        XCTAssertEqual(filtered.map(\.timestamp), points.map(\.timestamp))
    }

    /// And the filter is on the path the popover actually uses: the lines and the
    /// mean are both built from the filtered samples, so the two describe the same
    /// data. Applied on one path only, the bold line would run through teeth the
    /// lines under it no longer have.
    func testBothTheLinesAndTheMeanAreBuiltFromFilteredSamples() async throws {
        // A gateway answering with the comb of the two sources, on one account.
        let client = UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            let points = [38, 39, 38, 38, 38].enumerated().map { index, value in
                "{\"ts\": \(1_786_700_000 + index * 60), \"util_7d\": \(value)}"
            }
            let body = "{\"label\": \"acc1\", \"since\": 1786700000,"
                + " \"points\": [\(points.joined(separator: ","))]}"
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(body.utf8), response)
        }
        // The same suite `UsageHistoryTests` uses: a model that wrote to the
        // standard domain would leave a preference on somebody's working machine.
        let history = UsageHistoryModel(client: client,
                                        defaults: UserDefaults(suiteName: Self.suiteName) ?? .standard)
        history.open(labels: ["acc1"])
        await history.fetchTask?.value
        defer { history.close() }

        let readings = try XCTUnwrap(history.series.first).segments.flatMap { $0.readings.map(\.value) }
        XCTAssertEqual(readings, [38, 38, 38, 38, 38], "the account's line kept its teeth")
        XCTAssertEqual(history.fleet.points.map(\.value), [38, 38, 38, 38, 38],
                       "the mean was folded from unfiltered samples")
    }

    /// One suite for the class, wiped around every test — the reasoning is in
    /// `UsageHistoryTests`, whose suite this is.
    private static let suiteName = "xyz.vvzvlad.vscode-switcher.tests"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }
}

/// The popover's words. Every one of them has a "no reading" case, and none of
/// them is allowed to answer it with a zero.
@MainActor
final class UsagePopoverLabelTests: XCTestCase {

    func testAMissingReadingIsADashAndNotAZero() {
        XCTAssertEqual(UsagePopoverView.percentLabel(58.667), "59%")
        XCTAssertEqual(UsagePopoverView.percentLabel(0), "0%")
        XCTAssertEqual(UsagePopoverView.percentLabel(nil), "—")
    }

    /// The reset time is told to the hour, all the way up: whole days do not
    /// answer the question the row is asked. `in 1d` covers everything from 24
    /// hours to 48 of them — the user's own objection, "19 hours? 26?" — so the
    /// hours are printed beside the days, and printed even when there are none of
    /// them, because a bare `in 5d` is exactly the ambiguity being removed.
    func testTheResetTimeIsToldToTheHourAndAbsentWhenUnknown() {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        func label(_ seconds: TimeInterval) -> String {
            UsagePopoverView.resetLabel(now.addingTimeInterval(seconds), now: now)
        }
        XCTAssertEqual(label(15 * 60), "in 15m")
        // Minutes round up: half a minute left is not "in 0m".
        XCTAssertEqual(label(30), "in 1m")
        XCTAssertEqual(label(3 * 3600), "in 3h")
        // Hours go down, because this is a countdown: 3h 59m has not turned into
        // four hours yet.
        XCTAssertEqual(label(3 * 3600 + 59 * 60), "in 3h")
        // Where the two rules meet. The minutes round up to 60 of them here, and
        // `in 60m` is an hour written the long way — while the hours branch on its
        // own floors this to `in 0h`.
        XCTAssertEqual(label(3599), "in 1h", "the last minute below an hour is not an hour")
        XCTAssertEqual(label(3540), "in 59m", "the minute before that was carried too")
        XCTAssertEqual(label(3541), "in 1h")
        XCTAssertEqual(label(3 * 86_400 + 7 * 3600), "in 3d 7h")
        XCTAssertEqual(label(5 * 86_400 + 20 * 60), "in 5d 0h",
                       "a whole number of days dropped the hours and became ambiguous again")
        XCTAssertEqual(label(86_400 + 23 * 3600 + 59 * 60), "in 1d 23h",
                       "the last hour before two days was rounded up into them")
        // And the carry above stops at that one seam: the hour before a day is
        // still floored, or every countdown would round up all the way.
        XCTAssertEqual(label(86_399), "in 23h")
        XCTAssertEqual(label(0), "resets now")
        XCTAssertEqual(label(-60), "resets now")
        XCTAssertEqual(UsagePopoverView.resetLabel(nil, now: now), "")
    }

    /// What `resetLabel` writes is drawn whole in its slot.
    ///
    /// Measured rather than asserted: a claim about layout with no rendering
    /// behind it is a guess (§4), and this one has teeth — a truncated `in 5d 0h`
    /// is an hour count reading as a day count, the very defect the hours were
    /// added for. Two renderings of the same string, one in the slot the row gives
    /// it and one with no width at all: equal ink means nothing was cut.
    ///
    /// Not "the longest string the function can produce", which is what this said
    /// while `in 30d 23h` stood at the head of the list: the 30 days are the
    /// chart's widest period and cap nothing here, and `resetLabel` prints as many
    /// days as the gateway names. Hence the last probe — a reset 56 years out,
    /// which is the same call and still inside the slot.
    func testTheResetTimeFitsItsSlotWhole() throws {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        XCTAssertEqual(UsagePopoverView.resetLabel(now.addingTimeInterval(1_786_800_000), now: now),
                       "in 20680d 13h",
                       "the days are capped somewhere after all")
        for string in ["in 30d 23h", "resets now", "in 5d 0h", "in 15m", "in 20680d 13h"] {
            let text = Text(string).font(.system(size: 10)).lineLimit(1)
            let free = try XCTUnwrap(inkWidth(text.fixedSize()),
                                     "\"\(string)\" drew nothing at all")
            XCTAssertLessThanOrEqual(free, Double(UsagePopoverView.resetColumnWidth),
                                     "\"\(string)\" is wider than its slot")
            let slotted = try XCTUnwrap(inkWidth(text.frame(width: UsagePopoverView.resetColumnWidth,
                                                            alignment: .trailing)),
                                        "\"\(string)\" drew nothing inside the slot")
            XCTAssertEqual(slotted, free, accuracy: 0.5,
                           "\"\(string)\" was truncated in its slot: \(slotted) pt of ink "
                           + "against \(free) drawn free")
        }
    }

    /// How wide the ink of a rendered view is, in points — or `nil` when it drew
    /// nothing. The instrument the row's ladder is measured with (§4): a claim
    /// about layout with no rendering behind it is a guess.
    private func inkWidth(_ view: some View) throws -> Double? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        let image = try XCTUnwrap(renderer.nsImage, "ImageRenderer produced nothing")
        let bitmap = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels,
                                              width: bitmap.width,
                                              height: bitmap.height,
                                              bitsPerComponent: 8,
                                              bytesPerRow: bitmap.width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        let scale = Double(bitmap.width) / Double(image.size.width)
        var columns: [Int] = []
        for x in 0..<bitmap.width {
            for y in 0..<bitmap.height where pixels[(y * bitmap.width + x) * 4 + 3] > 8 {
                columns.append(x)
                break
            }
        }
        guard let first = columns.min(), let last = columns.max() else { return nil }
        return Double(last - first + 1) / scale
    }

    /// One age line, and silence when there is nothing to say about it.
    ///
    /// Two lines stood here — the quota's age and the chart's — and with both
    /// halves polled once a minute under an open popover they moved together and
    /// said the same thing twice. What is left is the older of the two, and only
    /// once it is older than two polling intervals: below that, the line would be
    /// a permanent "everything is fine" redrawn four times a minute.
    func testTheFooterSaysNothingWhileTheDataIsFresh() {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        func label(quota: TimeInterval?, chart: TimeInterval? = nil,
                   quotaFailed: Bool = false, chartFailed: Bool = false) -> String? {
            UsagePopoverView.footerAgeLabel(quotaFetchedAt: quota.map { now.addingTimeInterval(-$0) },
                                            quotaFailed: quotaFailed,
                                            chartFetchedAt: chart.map { now.addingTimeInterval(-$0) },
                                            seriesPeriod: chart == nil ? nil : .day,
                                            period: .day,
                                            chartFailed: chartFailed,
                                            now: now)
        }
        // Fresh: the poll is simply running.
        XCTAssertNil(label(quota: 30, chart: 30))
        XCTAssertNil(label(quota: UsagePopoverView.footerStaleSeconds - 1))
        // Old enough to be worth saying.
        XCTAssertEqual(label(quota: 180, chart: 180), "as of 3m ago")
        XCTAssertEqual(label(quota: 3600, chart: 3600), "as of 1h ago")
        XCTAssertEqual(label(quota: 2 * 86_400, chart: 2 * 86_400), "as of 2d ago")
        // Nothing fetched at all is not a matter of age: the sections above say
        // "Loading…" or name the gateway's failure themselves.
        XCTAssertNil(label(quota: nil))
        XCTAssertNil(label(quota: nil, quotaFailed: true, chartFailed: true))
    }

    /// The age of the screen is the age of the oldest thing on it, and a chart
    /// that answers another period is not on it at all.
    func testTheFooterDatesTheOldestOfTheTwoHalves() {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        func label(quota: TimeInterval, chart: TimeInterval,
                   seriesPeriod: HistoryPeriod? = .day) -> String? {
            UsagePopoverView.footerAgeLabel(quotaFetchedAt: now.addingTimeInterval(-quota),
                                            quotaFailed: false,
                                            chartFetchedAt: now.addingTimeInterval(-chart),
                                            seriesPeriod: seriesPeriod,
                                            period: .day,
                                            chartFailed: false,
                                            now: now)
        }
        // A stale half is enough on its own, whichever one it is, and it is the
        // half that speaks: the age of a screen is the age of the oldest thing on
        // it.
        XCTAssertEqual(label(quota: 20, chart: 600), "as of 10m ago",
                       "the fresher half spoke for the whole screen")
        XCTAssertEqual(label(quota: 600, chart: 20), "as of 10m ago")
        // The control on those two: with neither half stale the same call says
        // nothing at all, so what the line above answers for is the staleness and
        // not merely the presence of two stamps.
        XCTAssertNil(label(quota: 20, chart: 20))
        // The chart's stamp belongs to the window it was fetched for. After a tap
        // on `30d` the lines in hand are the previous one's, the plot says
        // "Loading…" about them, and their age is nobody's business — told from
        // the stamp alone, an hour-old `1d` chart would date a `30d` tab.
        XCTAssertNil(label(quota: 20, chart: 3600, seriesPeriod: .month),
                     "the footer dated lines the chart above it is not drawing")
    }

    /// A failed check shows the age at any freshness. With the numbers standing
    /// still and the checks failing, how old they are is the only thing that tells
    /// live figures from frozen ones — and the threshold would hide exactly that
    /// for the first two minutes of every outage.
    func testAFailedCheckBreaksTheSilence() {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        func label(quotaFailed: Bool, chartFailed: Bool) -> String? {
            UsagePopoverView.footerAgeLabel(quotaFetchedAt: now.addingTimeInterval(-30),
                                            quotaFailed: quotaFailed,
                                            chartFetchedAt: now.addingTimeInterval(-30),
                                            seriesPeriod: .day,
                                            period: .day,
                                            chartFailed: chartFailed,
                                            now: now)
        }
        XCTAssertNil(label(quotaFailed: false, chartFailed: false))
        XCTAssertEqual(label(quotaFailed: true, chartFailed: false), "as of less than a minute ago")
        XCTAssertEqual(label(quotaFailed: false, chartFailed: true), "as of less than a minute ago")
    }

    /// And a footer with neither line in it takes the divider above it with it: a
    /// rule across the bottom of the popover with nothing under it is worse than
    /// no rule.
    func testAnEmptyFooterDrawsNoDividerEither() {
        XCTAssertTrue(UsagePopoverView.footerIsSilent(age: nil, failure: nil))
        XCTAssertFalse(UsagePopoverView.footerIsSilent(age: "as of 3m ago", failure: nil))
        XCTAssertFalse(UsagePopoverView.footerIsSilent(age: nil, failure: "/gw/usage: HTTP 500"))
    }

    /// "We have not asked yet" is not "we asked and there is nothing". Before
    /// the first answer the popover stated things about the gateway that the
    /// gateway had never said — that it had named no accounts, that a period it
    /// was never asked about held no data — with the footer beside it truthfully
    /// saying nothing had been fetched at all.
    func testNothingYetAskedIsNotNothingFound() {
        XCTAssertEqual(UsagePopoverView.emptyLabel(landed: false, failed: false,
                                                   nothing: "The gateway named no accounts"),
                       "Loading…")
        XCTAssertEqual(UsagePopoverView.emptyLabel(landed: true, failed: false,
                                                   nothing: "The gateway named no accounts"),
                       "The gateway named no accounts")
        XCTAssertEqual(UsagePopoverView.emptyLabel(landed: true, failed: false,
                                                   nothing: "No data for this period"),
                       "No data for this period")
        // And a "loading" that can never end is a lie of its own: a gateway that
        // was down at launch lands no first answer, ever.
        XCTAssertEqual(UsagePopoverView.emptyLabel(landed: false, failed: true,
                                                   nothing: "The gateway named no accounts"),
                       "Gateway did not answer")
        // A failure after an answer has landed changes nothing here: the
        // accounts are known, and the reason is in the footer.
        XCTAssertEqual(UsagePopoverView.emptyLabel(landed: true, failed: true,
                                                   nothing: "The gateway named no accounts"),
                       "The gateway named no accounts")
    }

    /// The big number and the menu bar picture are one reading, rounded in one
    /// place (`UsageSnapshot.fleetSevenDayPercent`): two ways of working it out
    /// would drift apart the day one of them changed.
    ///
    /// They differ in exactly one thing, and it is not the arithmetic. The menu
    /// bar drops a figure whose last pass failed, because up there is no room to
    /// say "as of an hour ago" and a bare percentage reads as the truth right
    /// now (§2.4). The popover keeps it: the footer under it gives the age, and
    /// the account rows below go on showing their stored percentages — gated the
    /// same way, the headline was a dash over live numbers, and the dash was the
    /// false statement of the two.
    func testTheHeadlineAndTheIconComputeTheSameFigure() {
        var snapshot = UsageSnapshot.empty
        snapshot.fleetSevenDayMean = 58.667
        XCTAssertEqual(snapshot.fleetSevenDayPercent, 59)
        XCTAssertEqual(UsagePopoverView.headlinePercent(for: snapshot), MenuBarIcon.percent(for: snapshot),
                       "two surfaces, two figures")
        XCTAssertEqual(UsagePopoverView.percentLabel(snapshot.fleetSevenDayMean), "59%")

        // The one difference, in both directions.
        snapshot.quotaFailure = "/gw/usage: unreachable"
        XCTAssertNil(MenuBarIcon.percent(for: snapshot), "the menu bar showed a figure it cannot caveat")
        XCTAssertEqual(UsagePopoverView.headlinePercent(for: snapshot), 59,
                       "the headline blanked a reading it has, over rows that are showing it")

        // And a reading nobody ever took is a dash on both surfaces.
        XCTAssertNil(UsagePopoverView.headlinePercent(for: .empty))
        XCTAssertNil(MenuBarIcon.percent(for: .empty))
    }

    /// The accounts section speaks for the poll it draws — `/gw/usage`, which is
    /// where the list itself comes from — and for nothing else.
    func testTheAccountsSectionSpeaksForTheQuotaPollAlone() {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        func snapshot(fetched: Date? = nil, quota: String? = nil, sessions: String? = nil) -> UsageSnapshot {
            var value = UsageSnapshot.empty
            value.quotaFetchedAt = fetched
            value.quotaFailure = quota
            value.sessionsFailure = sessions
            return value
        }
        // Both arguments of the call site are load-bearing: the first line moves
        // with `quotaFetchedAt`, the second with `quotaFailure`.
        XCTAssertEqual(UsagePopoverView.accountsEmptyLabel(snapshot()), "Loading…")
        XCTAssertEqual(UsagePopoverView.accountsEmptyLabel(snapshot(quota: "/gw/usage: HTTP 500")),
                       "Gateway did not answer")
        XCTAssertEqual(UsagePopoverView.accountsEmptyLabel(snapshot(fetched: now)),
                       "The gateway named no accounts")

        // And `/gw/sessions` moves nothing here at all — the endpoint has not a
        // figure on this surface. Pinned as an invariant over the three states
        // rather than demonstrated in one of them: the only combination in which
        // reading `failureText` instead would say something different (a
        // sessions failure while the quota half has neither landed nor been
        // blamed) is one the poll cannot produce, because every pass either
        // fills in `quotaFetchedAt` or fills in `quotaFailure`.
        for state in [snapshot(), snapshot(quota: "/gw/usage: HTTP 500"), snapshot(fetched: now)] {
            var withSessions = state
            withSessions.sessionsFailure = "/gw/sessions: HTTP 502"
            XCTAssertEqual(UsagePopoverView.accountsEmptyLabel(withSessions),
                           UsagePopoverView.accountsEmptyLabel(state),
                           "the accounts section answered for an endpoint it does not draw")
        }
    }

    /// And the chart speaks for the lines. The whole meaning of its label lives
    /// in the arguments it is given, which is where the defect sat while the
    /// function itself was under test: told from the last *finished* pass, the
    /// chart called a silent gateway an empty period.
    func testTheChartDoesNotCallSilenceAnEmptyPeriod() throws {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        let accounts = try UsageFixtures.decode(UsageFixtures.usage, as: UsageReport.self).accounts
        XCTAssertFalse(accounts.isEmpty)
        func snapshot(fetched: Date? = nil, quota: String? = nil,
                      accounts: [AccountUsage] = []) -> UsageSnapshot {
            var value = UsageSnapshot.empty
            value.quotaFetchedAt = fetched
            value.quotaFailure = quota
            value.accounts = accounts
            return value
        }
        func label(_ snapshot: UsageSnapshot, landed: Date?, failure: String?,
                   seriesPeriod: HistoryPeriod? = .day, period: HistoryPeriod = .day) -> String {
            UsagePopoverView.plotEmptyLabel(snapshot: snapshot,
                                            seriesFetchedAt: landed,
                                            seriesPeriod: seriesPeriod,
                                            period: period,
                                            historyFailure: failure)
        }

        // The defect: accounts in hand, every history request failed, no lines.
        XCTAssertEqual(label(snapshot(fetched: now, accounts: accounts),
                             landed: nil, failure: "acc2: unreachable"),
                       "Gateway did not answer")
        // Which is also where the history's own failure earns its place in
        // `failed:`: with the quota half perfectly healthy, it is the only thing
        // that can tell "the gateway said nothing" from "still loading".
        XCTAssertEqual(label(snapshot(fetched: now, accounts: accounts), landed: nil, failure: nil),
                       "Loading…")
        // Nothing asked of anybody yet.
        XCTAssertEqual(label(snapshot(), landed: nil, failure: nil), "Loading…")
        // The quota poll is the chart's supplier of accounts, so its failure is
        // the chart's reason too.
        XCTAssertEqual(label(snapshot(quota: "/gw/usage: HTTP 500"), landed: nil, failure: nil),
                       "Gateway did not answer")
        // The lines arrived and have nothing in them: now the period really is
        // empty, and the popover may say so.
        XCTAssertEqual(label(snapshot(fetched: now, accounts: accounts), landed: now, failure: nil),
                       "No data for this period")
        // Nobody to ask is an answer as well — but only once the poll that names
        // the accounts has landed. That half of `landed` needs no period of its
        // own: an empty account list is an empty list for every window.
        XCTAssertEqual(label(snapshot(fetched: now), landed: nil, failure: nil),
                       "No data for this period")
        XCTAssertEqual(label(snapshot(fetched: now), landed: nil, failure: nil,
                             seriesPeriod: nil, period: .month),
                       "No data for this period")
        // But lines that landed for another window are not an answer about this
        // one: until the pass for it comes back there is nothing landed at all.
        XCTAssertEqual(label(snapshot(fetched: now, accounts: accounts), landed: now,
                             failure: nil, seriesPeriod: .day, period: .month),
                       "Loading…",
                       "the chart called a period empty on the strength of another one's lines")
    }

    /// The footer explains what this view draws, and both halves of it when both
    /// failed.
    ///
    /// `UsageSnapshot.failureText` is the wrong source here: it also carries
    /// `/gw/sessions`, whose figures are in the panel's rows and not on this
    /// surface at all. Standing first, it explained a number the user cannot see
    /// while the empty chart beside it had its own reason shown nowhere.
    func testTheFooterExplainsTheHalvesThisViewDraws() {
        XCTAssertNil(UsagePopoverView.failureText(quota: nil, history: nil))
        XCTAssertEqual(UsagePopoverView.failureText(quota: "/gw/usage: HTTP 500", history: nil),
                       "/gw/usage: HTTP 500")
        XCTAssertEqual(UsagePopoverView.failureText(quota: nil, history: "acc2: unreachable"),
                       "acc2: unreachable")
        XCTAssertEqual(UsagePopoverView.failureText(quota: "/gw/usage: HTTP 500",
                                                    history: "acc2: unreachable"),
                       "/gw/usage: HTTP 500; acc2: unreachable",
                       "one reason stood in for the other")

        // The endpoint this view has no figure from is not in it at all — while
        // the snapshot's own line, which the dump prints, still carries it.
        var snapshot = UsageSnapshot.empty
        snapshot.sessionsFailure = "/gw/sessions: HTTP 502"
        XCTAssertEqual(snapshot.failureText, "/gw/sessions: HTTP 502")
        XCTAssertNil(UsagePopoverView.failureText(quota: snapshot.quotaFailure,
                                                  history: nil))
    }

}

/// The popover as pixels. Three of its rules are about colour and about what is
/// drawn at all, and no pure function can be asked any of them.
///
/// Each of the three used to hold nothing: removing the colour scale, keying the
/// dots off the wrong list and drawing the footer's divider unconditionally all
/// left the suite green. The tests below fail on each, which is checked by making
/// each change.
@MainActor
final class UsagePopoverPaintTests: XCTestCase {

    /// The same suite `UsageHistoryTests` uses, and for its reasons: a model
    /// writing to the standard domain would leave a preference behind on
    /// somebody's working machine.
    private static let suiteName = "xyz.vvzvlad.vscode-switcher.tests"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: Self.suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName) ?? .standard
    }

    // MARK: - Reading a rendering

    /// A rendering, read back as colour rather than as ink.
    ///
    /// Colour is why this exists at all: `rendered` in `UsageHistoryTests` weighs
    /// alpha, which is where a line is and how heavy — and a hue swapped for
    /// another hue moves neither of those by a pixel.
    private struct Canvas {
        var width: Int
        var height: Int
        /// Pixels per point.
        var scale: Double
        /// Premultiplied RGBA, row 0 at the top.
        var bytes: [UInt8]

        func alpha(_ x: Int, _ y: Int) -> Double { Double(bytes[(y * width + x) * 4 + 3]) / 255 }

        /// Hue, saturation and alpha at a pixel, or `nil` where nothing was drawn.
        ///
        /// Un-premultiplied, which is the whole point: an account line is drawn at
        /// 55% opacity and its edges at less still, and only the colour divided
        /// back out by its own alpha is the colour the palette handed it. Weighing
        /// the stored bytes instead would report every faint edge as a pale
        /// unsaturated something.
        func colour(_ x: Int, _ y: Int) -> (hue: Double, saturation: Double, alpha: Double)? {
            let base = (y * width + x) * 4
            let alpha = Double(bytes[base + 3]) / 255
            // Below this the division amplifies the rounding of a single byte
            // into a hue of its own.
            guard alpha > 0.05 else { return nil }
            let red = Double(bytes[base]) / 255 / alpha
            let green = Double(bytes[base + 1]) / 255 / alpha
            let blue = Double(bytes[base + 2]) / 255 / alpha
            let high = max(red, green, blue)
            let low = min(red, green, blue)
            let delta = high - low
            guard high > 0 else { return (0, 0, alpha) }
            var hue = 0.0
            if delta > 0 {
                if high == red { hue = (green - blue) / delta }
                else if high == green { hue = 2 + (blue - red) / delta }
                else { hue = 4 + (red - green) / delta }
                hue = (hue / 6).truncatingRemainder(dividingBy: 1)
                if hue < 0 { hue += 1 }
            }
            return (hue, delta / high, alpha)
        }
    }

    private static let scale = 2.0

    /// Renders a view at the popover's own width, or in a box of a given height
    /// where the view has no height of its own (the plot).
    private func canvas(_ view: some View, height: CGFloat? = nil) throws -> Canvas {
        let sized = height.map { AnyView(view.frame(width: UsagePopoverView.width, height: $0)) }
            ?? AnyView(view)
        let renderer = ImageRenderer(content: sized)
        renderer.scale = Self.scale
        let bitmap = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced nothing")
        var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels,
                                              width: bitmap.width,
                                              height: bitmap.height,
                                              bitsPerComponent: 8,
                                              bytesPerRow: bitmap.width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        return Canvas(width: bitmap.width, height: bitmap.height, scale: Self.scale, bytes: pixels)
    }

    /// Anything drawn in a colour of its own — a hue, as against the ink and the
    /// greys everything else on this surface is drawn in.
    private func isChromatic(_ pixel: (hue: Double, saturation: Double, alpha: Double)?) -> Bool {
        guard let pixel else { return false }
        return pixel.saturation > 0.3
    }

    /// One patch of colour found in the rendering.
    private struct Blob {
        var pixels: Int
        var hue: Double
        var saturation: Double
        var box: (minX: Int, maxX: Int, minY: Int, maxY: Int)

        var width: Int { box.maxX - box.minX + 1 }
        var height: Int { box.maxY - box.minY + 1 }
    }

    /// Every connected patch of pixels the caller's rule admits, found by flood
    /// fill. What the two callers below differ in is that rule and the size they
    /// then keep.
    private func blobs(in canvas: Canvas,
                       where include: ((hue: Double, saturation: Double, alpha: Double)) -> Bool)
        -> [Blob] {
        var seen = [Bool](repeating: false, count: canvas.width * canvas.height)
        var found: [Blob] = []
        func admits(_ x: Int, _ y: Int) -> Bool {
            guard let pixel = canvas.colour(x, y) else { return false }
            return include(pixel)
        }
        for y in 0..<canvas.height {
            for x in 0..<canvas.width where admits(x, y) && !seen[y * canvas.width + x] {
                var stack = [(x, y)]
                seen[y * canvas.width + x] = true
                var blob = Blob(pixels: 0, hue: 0, saturation: 0, box: (x, x, y, y))
                while let (cx, cy) = stack.popLast() {
                    blob.pixels += 1
                    blob.hue += canvas.colour(cx, cy)?.hue ?? 0
                    blob.saturation += canvas.colour(cx, cy)?.saturation ?? 0
                    blob.box.minX = min(blob.box.minX, cx)
                    blob.box.maxX = max(blob.box.maxX, cx)
                    blob.box.minY = min(blob.box.minY, cy)
                    blob.box.maxY = max(blob.box.maxY, cy)
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let nx = cx + dx
                        let ny = cy + dy
                        guard nx >= 0, ny >= 0, nx < canvas.width, ny < canvas.height,
                              !seen[ny * canvas.width + nx], admits(nx, ny) else { continue }
                        seen[ny * canvas.width + nx] = true
                        stack.append((nx, ny))
                    }
                }
                blob.hue /= Double(blob.pixels)
                blob.saturation /= Double(blob.pixels)
                found.append(blob)
            }
        }
        return found
    }

    /// Whether a patch is the size of a frame the view asked for, to a pixel on
    /// each side.
    ///
    /// The size comes from the view, and that is the half that carries the weight:
    /// a copy of the number here is what failed both colour tests with "the
    /// popover drew 0 dots" when the dot went from 7 points to 8 — pure
    /// decoration, and a message about the palette. Asked of the view's own
    /// constant, plain equality survives that change: measured, a whole number of
    /// points is a whole number of pixels at this scale, 16 for 8 as 14 for 7.
    ///
    /// The pixel of slack earns its place on the other patch. `fleetMarkerSize` is
    /// 2.5 points tall, which is not a whole number of pixels at every scale —
    /// checked by raising this class's `scale` to 3, where the marker is 7.5 px
    /// tall: with equality no patch can be that and the headline's test fails with
    /// "0 patches", with the slack the class stays green.
    private func isSized(_ blob: Blob, _ size: CGSize, in canvas: Canvas) -> Bool {
        abs(Double(blob.width) - Double(size.width) * canvas.scale) <= 1
            && abs(Double(blob.height) - Double(size.height) * canvas.scale) <= 1
    }

    /// The account dots, in the order they are drawn down the popover.
    ///
    /// Found as patches rather than at coordinates worked out from the layout: a
    /// dot is a `Circle` of `accountDotSize` points filled at full strength, and
    /// nothing else in the picture is both. The one other opaque colour a
    /// rendering of this view has in it is the segmented picker's background,
    /// which comes out as a single patch 292 by 22 points — sorted out by size and
    /// by nothing finer. The size is the view's own constant, not a copy of it.
    private func dots(in canvas: Canvas) -> [Blob] {
        let side = UsagePopoverView.accountDotSize
        return blobs(in: canvas) { isChromatic($0) && $0.alpha > 0.9 }
            .filter { isSized($0, CGSize(width: side, height: side), in: canvas) }
            .sorted { $0.box.minY < $1.box.minY }
    }

    /// The hues the account lines are drawn in, one per line.
    ///
    /// Read inside the chart's own rows, and that is the whole difficulty here:
    /// the popover draws hues outside the plot, and one of them is the very hue a
    /// test below asserts is *not* among the lines. Measured over the whole picture
    /// instead, the orange bucket carries 50 px of the footer's warning symbol —
    /// four times under the threshold, but the symbol is drawn exactly when an
    /// account failed its history request, which is that test's own fixture. And
    /// with the accounts' readings known, the ordinary state of a live popover, the
    /// rims of the bars a reading fills take the same bucket to 258 px, which is
    /// over it. Inside the band the lines are alone: 1073 and 1072 px against
    /// nothing else at all. The dots' rims are outside it too, so nothing has to be
    /// cut out by position any more.
    ///
    /// The upper bound on alpha stays, and it is not about the dots: the segmented
    /// picker's background is inside these rows, opaque, and chromatic enough to
    /// count — 24982 px of it in one group, which is a line the chart never drew.
    /// An account's line carries `accountOpacity` and cannot reach that band.
    ///
    /// The hues are grouped by proximity rather than dropped into a fixed grid of
    /// buckets, and that is not tidiness either: one line's antialiased pixels
    /// spread by under 0.01 while the palette's own hues are 0.2 apart, so a grid
    /// boundary landing inside that spread reports one line as two. It did — in
    /// dark appearance the blue line sits at 0.5837 and a boundary of the grid was
    /// at 0.58333, which had `lines.count` come out 3 for two accounts and a
    /// message about the palette. Grouped by proximity, the same rendering answers
    /// 2. What is left is thresholded by area, a line being four figures of pixels
    /// against a stray edge's two.
    private func lineHues(in canvas: Canvas) throws -> [Double] {
        var hues: [Double] = []
        for y in try plotRows(in: canvas) {
            for x in 0..<canvas.width {
                guard let pixel = canvas.colour(x, y), isChromatic(pixel),
                      pixel.alpha > 0.2, pixel.alpha < 0.9 else { continue }
                hues.append(pixel.hue)
            }
        }
        var groups: [[Double]] = []
        for hue in hues.sorted() {
            if let last = groups.last, let highest = last.last, hue - highest <= 0.02 {
                groups[groups.count - 1].append(hue)
            } else {
                groups.append([hue])
            }
        }
        return groups.filter { $0.count >= 200 }
            .map { $0.reduce(0, +) / Double($0.count) }
            .sorted()
    }

    /// The rows the chart occupies: from the rule that divides it from the
    /// accounts down to the footer's rule, or to the bottom of the picture when
    /// the footer has nothing to say and draws no rule of its own.
    ///
    /// Taken from the picture rather than worked out from the layout, so that a
    /// change of inset or of a font size moves the band along with the chart
    /// instead of leaving this reader pointed at the wrong rows.
    private func plotRows(in canvas: Canvas) throws -> Range<Int> {
        let rules = rules(in: canvas)
        let top = try XCTUnwrap(rules.count >= 2 ? rules[1] : nil,
                                "the popover drew \(rules.count) rule(s), so the one above the "
                                + "chart is not among them: \(rules)")
        return top..<(rules.count >= 3 ? rules[2] : canvas.height)
    }

    /// The rules across the popover, top to bottom, as rows of the bitmap.
    ///
    /// A `Divider` is the only thing here that is one point tall and runs from one
    /// padding edge to the other — so it is measured against the width of the
    /// *content*, not of the picture. Against the picture no rule can ever reach
    /// more than `(width - 2 * padding) / width`, which is 0.9125 at today's
    /// figures: a threshold of 0.9 there sat 1.25% from the working point and
    /// moved with every change of the inset. `padding` 18 brings it to 0.8875 and
    /// `width` 240 to 0.8833 — checked by making both changes over the old
    /// threshold, which found no rules at all and failed the footer's test below
    /// with a message about the footer.
    ///
    /// Against the content a rule is 1.000 whatever the inset, and both thresholds
    /// still sit between the figures: the headline's bar is the same 1.000 but
    /// 8 pt tall, the segmented picker 22, and the chart's grid lines are thin but
    /// start after the y axis labels, which leaves them at 0.918…0.949 of the
    /// content (0.916…0.947 at `padding` 18). The closest anything came to 0.98
    /// across the three widths measured is that bar's own end row — 0.976 at
    /// `width` 240, a shorter row losing more of itself to the capsule's curve —
    /// and it sits inside an 8 pt run, so the height filter has it either way.
    private func rules(in canvas: Canvas) -> [Int] {
        let content = Double(canvas.width) - 2 * Double(UsagePopoverView.padding) * canvas.scale
        var runs: [(first: Int, last: Int)] = []
        for y in 0..<canvas.height {
            var inked = 0
            for x in 0..<canvas.width where canvas.alpha(x, y) > 0.03 { inked += 1 }
            guard Double(inked) / content >= 0.98 else { continue }
            if let last = runs.last, last.last == y - 1 {
                runs[runs.count - 1] = (last.first, y)
            } else {
                runs.append((y, y))
            }
        }
        return runs.filter { Double($0.last - $0.first + 1) / canvas.scale <= 1.5 }.map(\.first)
    }

    // MARK: - Fixtures

    /// A landed quota poll naming these accounts, with no reading for either of
    /// anybody's windows.
    ///
    /// No readings on purpose. A known utilisation fills the row's `QuotaBar` in
    /// green, orange or red — three more hues in a picture whose whole subject is
    /// which hue went where — while an unknown one leaves the bar as its track,
    /// which is ink at 12%. Same for the headline: with no fleet mean there is a
    /// dash over an empty track, and every colour left in the rendering belongs
    /// either to a dot or to a line.
    private func snapshot(labels: [String], fetched: Date = Date()) throws -> UsageSnapshot {
        let body = labels.map {
            "\"\($0)\": {\"five_hour\": {\"known\": false}, \"seven_day\": {\"known\": false}}"
        }
        let report = try UsageFixtures.decode("{\"accounts\": {\(body.joined(separator: ","))}}",
                                              as: UsageReport.self)
        var value = UsageSnapshot.empty
        value.accounts = report.accounts
        value.quotaFetchedAt = fetched
        return value
    }

    /// A store whose quota poll has already landed, naming these accounts.
    ///
    /// Seeded through the cache, which is where a store takes its first published
    /// value from. `UsageStore.apply` is private and stays that way: it releases
    /// the `pollInFlight` latch as its third act, so a caller from outside the
    /// pass could let two passes run at once. The only other way a snapshot
    /// reaches the type is a gateway answering over the network, which is a live
    /// network for a question about which pixel is which colour.
    private func store(named labels: [String], fetched: Date = Date()) throws -> UsageStore {
        let cache = UsageCache()
        cache.store(try snapshot(labels: labels, fetched: fetched))
        return UsageStore(config: .default, cache: cache)
    }

    /// A popover over a landed poll and a chart that has been fetched once.
    ///
    /// The two lists are separate arguments because the tests below are about them
    /// disagreeing: `named` is the quota poll's, which the dots are drawn from, and
    /// `asked` is the chart's. An account in `asked` with no level in `readings`
    /// fails its history request, which is the other way they come apart.
    private func popover(named: [String],
                         asked: [String],
                         readings: [String: Double],
                         fetched: Date = Date()) async throws -> (UsagePopoverView, UsageStore, UsageHistoryModel) {
        let history = UsageHistoryModel(client: flatHistoryClient(readings: readings,
                                                                  silentOnUnknown: true),
                                        defaults: freshDefaults())
        let store = try store(named: named, fetched: fetched)
        history.open(labels: asked)
        await history.fetchTask?.value
        return (UsagePopoverView(usage: store, history: history), store, history)
    }

    // MARK: - The mean line is ink

    /// The mean is drawn in ink, and no account may be handed that colour.
    ///
    /// Which is the whole reason the chart declares its own colour scale: without
    /// `chartForegroundStyleScale` the mean is a series like any other and Charts
    /// hands it a hue out of its palette, at which point the one line this popover
    /// exists to show is a colour among colours and the marker beside the headline
    /// — a `Capsule` of `fleetColor` — points at nothing in the picture.
    ///
    /// The rule held nothing after the legend was hidden: the test that had
    /// covered it named the legend's first entry, and it went with the legend. The
    /// tests that stayed weigh alpha, which a hue does not move.
    ///
    /// Read in the two bands `UsageHistoryTests` calibrated (§4): with two flat
    /// accounts at 100 and 20 the mean's band holds the mean's line and nothing
    /// else, and the lower band holds the second account's. Saturation is
    /// averaged over the band's ink and weighted by its alpha, so the grey of a
    /// grid line cannot be answered for by a stray pixel either way — and neither
    /// band contains one.
    func testTheMeanLineIsInkAndTheAccountsAreNot() async throws {
        let (view, _, history) = try await popover(named: ["acc1", "acc2"],
                                                   asked: ["acc1", "acc2"],
                                                   readings: ["acc1": 100, "acc2": 20])
        defer { history.close() }
        let picture = try canvas(view.plot, height: 130)

        let mean = colour(in: picture, band: 0.32...0.36)
        let account = colour(in: picture, band: 0.67...0.70)
        XCTAssertGreaterThan(mean.coverage, 1000,
                            "nothing was drawn in the mean's band: the measurement is empty")
        XCTAssertLessThan(mean.saturation, 0.1,
                          "the mean line is a hue rather than ink (saturation \(mean.saturation))")
        XCTAssertGreaterThan(account.coverage, 100,
                             "nothing was drawn in the account's band: the two are not compared")
        XCTAssertGreaterThan(account.saturation, 0.5,
                             "the account lines are ink too, so the mean being ink says nothing "
                             + "(saturation \(account.saturation))")
    }

    /// And it stays ink when an account is called what the mean's key used to be
    /// called.
    ///
    /// `styleDomain` puts the mean's key at the head and the accounts after it, so
    /// a key an account can also hold puts the same string in the domain twice.
    /// Charts keeps the last colour for a repeated key, and the mean is then drawn
    /// in that account's hue while the marker beside the headline points at
    /// nothing. Measured with the key spelled `average`, over the accounts
    /// `["average", "acc2"]`: the domain came out `["average", "acc2", "average"]`,
    /// the range `[primary, orange, blue]`, and the mean's line took the blue.
    ///
    /// Which is why every other test on this palette stays green through it: both
    /// lines are chromatic, and each dot still matches a line of its own hue. Only
    /// the mean's own band can tell, and only by saturation.
    ///
    /// Same arrangement as the test above — the account that collides is the one at
    /// 100, so the mean is still 60 and the two calibrated bands (§4) still hold
    /// one line each.
    func testAnAccountNamedLikeTheMeanCannotTakeItsColour() async throws {
        let colliding = "average"
        let (view, _, history) = try await popover(named: [colliding, "acc2"],
                                                   asked: [colliding, "acc2"],
                                                   readings: [colliding: 100, "acc2": 20])
        defer { history.close() }
        let picture = try canvas(view.plot, height: 130)

        let mean = colour(in: picture, band: 0.32...0.36)
        let account = colour(in: picture, band: 0.67...0.70)
        XCTAssertGreaterThan(mean.coverage, 1000,
                             "nothing was drawn in the mean's band: the measurement is empty")
        XCTAssertLessThan(mean.saturation, 0.1,
                          "an account called \"\(colliding)\" took the mean's colour "
                          + "(saturation \(mean.saturation))")
        XCTAssertGreaterThan(account.coverage, 100,
                             "nothing was drawn in the account's band: the two are not compared")
        XCTAssertGreaterThan(account.saturation, 0.5,
                             "the account lines lost their hues, so the mean being ink says "
                             + "nothing (saturation \(account.saturation))")
    }

    /// How saturated the ink in a horizontal band of the plot is, weighted by how
    /// much of it there is. The band is given as fractions of the height from the
    /// top, the way `UsageHistoryTests` states its own.
    private func colour(in canvas: Canvas,
                        band: ClosedRange<Double>) -> (coverage: Double, saturation: Double) {
        let first = Int(band.lowerBound * Double(canvas.height))
        let last = min(canvas.height, Int((band.upperBound * Double(canvas.height)).rounded(.up)))
        var coverage = 0.0
        var saturation = 0.0
        for y in first..<last {
            for x in 0..<canvas.width {
                // The faint edges of a line are the line, but below this the
                // un-premultiplied colour is one byte of rounding.
                guard let pixel = canvas.colour(x, y), pixel.alpha > 0.2 else { continue }
                coverage += pixel.alpha
                saturation += pixel.saturation * pixel.alpha
            }
        }
        return (coverage, coverage == 0 ? 0 : saturation / coverage)
    }

    // MARK: - The dot beside a name and the line it names

    /// A dot beside an account's name is the colour of that account's line, and
    /// stays it when the two lists the colours are handed out from disagree.
    ///
    /// They disagree exactly when an account is named by the quota poll and
    /// missing from the chart's answers, or the other way about — and both
    /// happen: an account that failed its history request is in the poll and not
    /// on the chart, an account that has just left the poll is on the chart and
    /// not in the list. Keyed on `history.series` the dots would then be counted
    /// off a list one shorter than their own, and the dot beside a name would
    /// point at somebody else's line.
    ///
    /// Asked of the pixels, because the pure functions were already under test
    /// and neither call site was: `styleRange` and `accountColor` answered
    /// correctly all along while the view handed one of them the wrong list.
    ///
    /// Here the poll names an account whose history request failed: its dot is in
    /// the picture and its line is not, and the accounts after it must not shift a
    /// hue for it. Counted off the chart's list, the silent account is not on that
    /// list at all and its dot falls out of the palette into grey.
    func testAnAccountThatDidNotAnswerStillHasItsOwnColour() async throws {
        let (view, _, history) = try await popover(named: ["acc1", "acc2", "acc3"],
                                                   asked: ["acc1", "acc2", "acc3"],
                                                   readings: ["acc1": 90, "acc3": 20])
        defer { history.close() }
        XCTAssertEqual(history.series.map(\.label), ["acc1", "acc3"],
                       "the middle account answered after all: the two lists are the same list")
        let picture = try canvas(view)
        let marks = dots(in: picture)
        let lines = try lineHues(in: picture)
        XCTAssertEqual(marks.count, 3,
                       "the popover drew \(marks.count) dots of colour for three accounts — an "
                       + "account counted off the chart's list falls out of the palette entirely")
        XCTAssertEqual(lines.count, 2, "the chart drew \(lines.count) coloured lines for two answers")
        guard marks.count == 3 else { return }
        XCTAssertTrue(lines.contains { abs($0 - marks[0].hue) < 0.02 },
                      "the first account's dot (hue \(marks[0].hue)) names none of the lines \(lines)")
        XCTAssertTrue(lines.contains { abs($0 - marks[2].hue) < 0.02 },
                      "the third account's dot (hue \(marks[2].hue)) names none of the lines \(lines)")
        XCTAssertFalse(lines.contains { abs($0 - marks[1].hue) < 0.02 },
                       "the account that did not answer has a line on the chart")
    }

    /// The same rule from the other side, and this is the arrangement in which
    /// nothing but a colour changes: an account the poll has stopped naming is
    /// still on the chart, so the list of lines is the longer of the two. The
    /// popover draws a dot for every account it *does* name, and each of those
    /// dots has to be the colour of that account's line. Counted off the chart's
    /// list they come out one place along — and the count is the same either way,
    /// so nothing but the hue can say which happened.
    ///
    /// The account that left keeps a line, drawn grey: it has no place in a
    /// palette handed out by the poll, which is `accountColor`'s answer for a
    /// label the poll does not name. Grey is not a hue, so it is not among the
    /// lines counted here.
    func testEveryDotIsTheColourOfItsOwnLine() async throws {
        // The poll names two accounts, the chart answered for three: `acc2` has
        // left the poll and its line is still in hand.
        let (view, _, history) = try await popover(named: ["acc1", "acc3"],
                                                   asked: ["acc1", "acc2", "acc3"],
                                                   readings: ["acc1": 90, "acc2": 55, "acc3": 20])
        defer { history.close() }
        XCTAssertEqual(history.series.map(\.label), ["acc1", "acc2", "acc3"],
                       "the chart forgot the account before the test could ask about it")
        let picture = try canvas(view)
        let marks = dots(in: picture)
        let lines = try lineHues(in: picture)
        XCTAssertEqual(marks.count, 2,
                       "the poll names two accounts and the popover drew \(marks.count) dots")
        XCTAssertEqual(lines.count, 2,
                       "the chart drew \(lines.count) coloured lines: the account that left the "
                       + "poll was handed a hue that belongs to somebody")
        for dot in marks {
            XCTAssertTrue(lines.contains { abs($0 - dot.hue) < 0.02 },
                          "a dot of hue \(dot.hue) names none of the lines \(lines)")
        }
    }

    // MARK: - The sample of the bold line beside the headline

    /// The headline carries a sample of the chart's bold line, and it is drawn in
    /// ink rather than in a colour out of the palette.
    ///
    /// It is the only thing left tying that line to the number above it: the
    /// chart's legend is hidden and the caption that used to spell the rule out
    /// under the plot is gone (§4). And nothing held it — deleting the `Capsule`
    /// failed not one test of the suite, and filling it with `Color.pink`, which is
    /// the marker pointing at an account's line instead of at the mean's, failed
    /// none either.
    ///
    /// Found as one opaque patch the size of `fleetMarkerSize`: everything else in
    /// the headline is either text, whose strokes are nothing like 10 by 2.5
    /// points, or the bar under it, which with no reading to show is a track at
    /// 12%. The hue is not asked for — `Color.primary` has none, and that is the
    /// whole assertion.
    func testTheHeadlineCarriesAnInkSampleOfTheBoldLine() async throws {
        let (view, _, history) = try await popover(named: ["acc1"],
                                                   asked: ["acc1"],
                                                   readings: ["acc1": 90])
        defer { history.close() }
        let picture = try canvas(view.headline)
        // Half strength, not "opaque": `Color.primary` is `labelColor`, which is
        // black at 85% — measured, and at a threshold of 0.9 this rendering has no
        // opaque patch in it at all. The caption beside the marker is
        // `.secondary`, and its glyphs sit under this line.
        let markers = blobs(in: picture) { $0.alpha > 0.5 }
            .filter { isSized($0, UsagePopoverView.fleetMarkerSize, in: picture) }
        XCTAssertEqual(markers.count, 1,
                       "the headline holds \(markers.count) patches the size of the line's sample: "
                       + "the marker that explains the bold line is not there")
        guard let marker = markers.first else { return }
        XCTAssertLessThan(marker.saturation, 0.1,
                          "the sample beside the caption is a hue (saturation \(marker.saturation)) "
                          + "rather than ink: it points at an account's line, not at the mean's")
    }

    // MARK: - The divider over a silent footer

    /// A footer with nothing to say takes the rule above it with it.
    ///
    /// `footerIsSilent` was under test and `body` was not, so drawing the divider
    /// unconditionally — a rule hanging across the bottom of the popover with
    /// nothing under it — failed nothing at all. Counted in the bitmap: the same
    /// popover over the same chart, with the quota's stamp fresh and then older
    /// than `footerStaleSeconds`, and the silent one has one rule fewer.
    func testASilentFooterDrawsNoRuleAboveItself() async throws {
        let (view, landed, history) = try await popover(named: ["acc1"],
                                                        asked: ["acc1"],
                                                        readings: ["acc1": 90])
        defer { history.close() }
        // The state has to be one where the footer really would speak, or a
        // popover that says nothing either way proves nothing. Both halves are
        // asked here, in the wording the view asks them in.
        XCTAssertTrue(UsagePopoverView.footerIsSilent(age: age(landed, history), failure: history.failure),
                      "the fresh popover has something to say: the two states are the same state")
        let fresh = rules(in: try canvas(view))

        // The same chart under a second store, dated off the clock the footer
        // reads — so the wording below is the exact one rather than the one a
        // fraction of a second of test time rounded to.
        let dated = try store(named: ["acc1"], fetched: history.now.addingTimeInterval(-10 * 60))
        XCTAssertEqual(age(dated, history), "as of 10m ago",
                       "the stale popover kept quiet: nothing was added for a divider to go with")
        let stale = rules(in: try canvas(UsagePopoverView(usage: dated, history: history)))

        XCTAssertEqual(fresh.count, 2,
                       "the popover's own two rules are not two: \(fresh)")
        XCTAssertEqual(stale.count, fresh.count + 1,
                       "the footer's divider does not follow the footer (\(fresh) against \(stale))")
        XCTAssertGreaterThan(try XCTUnwrap(stale.last), try XCTUnwrap(fresh.last),
                             "the rule that appeared is not the bottom one")
    }

    /// The age line as `body` works it out, so the two states can be told apart
    /// by the same answer the view branches on.
    private func age(_ store: UsageStore, _ history: UsageHistoryModel) -> String? {
        UsagePopoverView.footerAgeLabel(quotaFetchedAt: store.snapshot.quotaFetchedAt,
                                        quotaFailed: store.snapshot.quotaFailure != nil,
                                        chartFetchedAt: history.fetchedAt,
                                        seriesPeriod: history.seriesPeriod,
                                        period: history.period,
                                        chartFailed: history.failure != nil,
                                        now: history.now)
    }
}
