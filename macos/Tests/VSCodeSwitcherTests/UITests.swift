import AppKit
import SwiftUI
import XCTest
@testable import VSCodeSwitcher

/// The loads the colour ramp is measured at, on every surface that draws it.
///
/// The owner's own list: two either side of the cold anchor, the middle of each
/// stretch, the green anchor, and two either side of the hot one. Shared by the
/// three classes below so the menu bar and the popover are asked the same
/// question — a second copy could drift into asking an easier one.
private let rampSamples: [Double] = [60, 70, 85, 100, 115, 130, 150]

/// The loads the ramp's legibility is measured at, on every surface and in both
/// appearances. Two more than `rampSamples`: 110 and 120 sit inside 100–124, the
/// band this fleet actually lives in. A separate list because `assertRamp` reads
/// its samples by position.
private let legibilityLoadSamples: [Double] = [60, 70, 85, 100, 110, 115, 120, 130, 150]

/// The WCAG contrast of an sRGB colour against an sRGB grey plate: linearise each
/// component, weigh by Rec. 709, take the ratio with 0.05 added to both sides.
/// The tests keep their own copy of this arithmetic so the check does not share a
/// mistake with the function under test.
private func wcagContrast(_ colour: (red: Double, green: Double, blue: Double),
                          against plate: Double) -> Double {
    func linear(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    func luminance(_ colour: (red: Double, green: Double, blue: Double)) -> Double {
        0.2126 * linear(colour.red) + 0.7152 * linear(colour.green) + 0.0722 * linear(colour.blue)
    }
    let background = luminance((plate, plate, plate))
    let ink = luminance(colour)
    return (max(background, ink) + 0.05) / (min(background, ink) + 0.05)
}

/// What a ramp read off a drawing has to be, whichever surface drew it: flat
/// outside the end anchors, strictly falling between them, and spanning the whole
/// way from blue to red.
///
/// Three properties because each survives the others being broken: a step at
/// capacity passes "flat at the ends" and fails the fall; hand-picked colours can
/// fall and still stand still somewhere; a ramp squeezed into greens passes both
/// and fails the span. `hues` is the drawn hue at each of `rampSamples`, in order.
private func assertRamp(_ hues: [Double], on surface: String,
                        file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(hues.count, rampSamples.count, "not every sample was read", file: file, line: line)
    XCTAssertEqual(hues[0], hues[1], accuracy: 0.005,
                   "below the cold anchor the ramp is still moving on \(surface): \(hues)",
                   file: file, line: line)
    XCTAssertEqual(hues[5], hues[6], accuracy: 0.005,
                   "past the hot anchor the ramp is still moving on \(surface): \(hues)",
                   file: file, line: line)
    for step in 1..<5 {
        XCTAssertGreaterThan(hues[step] - hues[step + 1], 0.03, """
            between \(rampSamples[step])% and \(rampSamples[step + 1])% the colour on \
            \(surface) does not move: \(hues) — a step, or a scale that stalls
            """, file: file, line: line)
    }
    XCTAssertGreaterThan(hues[1] - hues[5], 0.4,
                         "the whole ramp on \(surface) spans \(hues[1] - hues[5]) of the wheel, "
                         + "which is not blue to red: \(hues)", file: file, line: line)
}

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

    // MARK: - The bracket after the name, and the percentage at the end

    /// One row, built by hand, with only the two figures the bracket and the
    /// percentage read.
    private func row(agents: Int = 0, orphans: Int = 0, cpu: Double? = nil,
                     cpuIsLowerBound: Bool = false) -> SwitcherRow {
        var session = TestFixtures.session(id: "s", cwd: "/p", state: .working)
        session.activeSubagents = max(0, agents - 1)
        return SwitcherRow(id: "r",
                           kind: .window,
                           displayName: "vscode-switcher",
                           colorHex: "#1857a4",
                           project: nil,
                           window: nil,
                           sessions: agents > 0 ? [session] : [],
                           state: agents > 0 ? .working : nil,
                           activeSubagents: max(0, agents - 1),
                           subagentDescriptions: [],
                           chatTopic: nil,
                           model: nil,
                           contextUsedTokens: nil,
                           contextLimitTokens: nil,
                           lastActivity: nil,
                           usage: nil,
                           cpuPercent: cpu,
                           cpuIsLowerBound: cpuIsLowerBound,
                           orphanCount: orphans)
    }

    /// The bracket is what it always was when there are no orphans. This is the
    /// half of the requirement that is about *not* changing: `orphans: 0` on
    /// every row of the panel would be a column of noughts saying that nothing
    /// has happened.
    func testTheBracketIsUnchangedWithoutOrphans() {
        XCTAssertEqual(SwitcherRowView.countLabel(for: row(agents: 1)), "(agents: 1)")
        XCTAssertEqual(SwitcherRowView.countLabel(for: row(agents: 5)), "(agents: 5)")
        XCTAssertNil(SwitcherRowView.countLabel(for: row()))
    }

    /// And the orphans join it inside the same brackets, after the agents.
    func testOrphansJoinTheBracketAfterTheAgents() {
        XCTAssertEqual(SwitcherRowView.countLabel(for: row(agents: 1, orphans: 3)),
                       "(agents: 1, orphans: 3)")
    }

    /// A row can be all orphans and no agents, and that is the state worth
    /// having: an orphan is a process whose parent has exited, so three of them
    /// under a chat that has gone quiet is a thing nothing else on the row
    /// reports. The brackets appear for it alone.
    func testOrphansAloneStillGetTheBracket() {
        XCTAssertEqual(SwitcherRowView.countLabel(for: row(orphans: 2)), "(orphans: 2)")
    }

    /// A whole percent and no decimal: the number is re-read once a second, and
    /// a tenth of a core is noise given somewhere to jitter.
    func testTheCPUIsWrittenAsAWholePercent() {
        XCTAssertEqual(SwitcherRowView.cpuLabel(for: row(cpu: 38.4)), "38%")
        XCTAssertEqual(SwitcherRowView.cpuLabel(for: row(cpu: 38.6)), "39%")
        // Above one core is legitimate and is not clamped: that is several cores.
        XCTAssertEqual(SwitcherRowView.cpuLabel(for: row(cpu: 412.0)), "412%")
    }

    /// A sum the sweep could not take over every chat of the row wears `≥`, the mark
    /// the token figure uses for the same hole (§3.1). `nil` would draw a dash and
    /// understate by the whole figure.
    /// Below the one-percent threshold there is no label, and `≥` must not create one.
    func testAPartialSumWearsTheSameMarkTheTokenFigureDoes() {
        XCTAssertEqual(SwitcherRowView.cpuLabel(for: row(cpu: 38.4, cpuIsLowerBound: true)), "≥38%")
        XCTAssertEqual(SwitcherRowView.cpuLabel(for: row(cpu: 38.4)), "38%")
        XCTAssertNil(SwitcherRowView.cpuLabel(for: row(cpu: 0.4, cpuIsLowerBound: true)))
    }

    /// Two silences, and both of them deliberate. `nil` is "there has been one
    /// sweep so far"; below one percent is "measured, and idle" — without which
    /// every quiet row on the machine would carry a permanent `0%`.
    func testAnIdleOrUnmeasuredRowSaysNothingAboutCPU() {
        XCTAssertNil(SwitcherRowView.cpuLabel(for: row(cpu: nil)))
        XCTAssertNil(SwitcherRowView.cpuLabel(for: row(cpu: 0)))
        XCTAssertNil(SwitcherRowView.cpuLabel(for: row(cpu: 0.999)))
        XCTAssertEqual(SwitcherRowView.cpuLabel(for: row(cpu: 1.0)), "1%")
    }

    /// The tooltip says what the two numbers count: a share of one core (412% reads as
    /// four cores), and detached processes rather than orphaned ones, because a
    /// detached process brings everything under it into the count (SPEC §2.8).
    func testTheTooltipSpellsOutWhatTheFiguresCount() {
        XCTAssertEqual(SwitcherRowView.processLines(for: row(orphans: 2, cpu: 38.4)),
                       ["", "CPU 38% of one core · 2 processes detached from the parent chain"])
        XCTAssertEqual(SwitcherRowView.processLines(for: row(orphans: 1)),
                       ["", "1 process detached from the parent chain"])
        XCTAssertEqual(SwitcherRowView.processLines(for: row(cpu: 0.2)), [])
    }

    /// `--dump` prints the panel's own label, so the two cannot come to describe
    /// the same row differently — including on the rows the panel is silent
    /// about, which print a dash rather than a figure of their own.
    func testTheDumpPrintsThePanelsFigure() {
        XCTAssertEqual(ConsoleDump.cpuCell(for: row(cpu: 38.4)), "38%")
        XCTAssertEqual(ConsoleDump.cpuCell(for: row(cpu: 0.2)), "-")
        XCTAssertEqual(ConsoleDump.cpuCell(for: row(cpu: nil)), "-")
        // And the orphans reach the dump through the same bracket the panel
        // draws, by way of `nameCell`.
        XCTAssertTrue(ConsoleDump.nameCell(for: row(agents: 1, orphans: 3), width: 40)
            .contains("(agents: 1, orphans: 3)"))
    }
}

/// The "projects" section lists every project, in the order the data layer ranked
/// them.
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

    /// The two sides can disagree, the accepted price of keeping the second one: the
    /// newcomer trails `c` (last slot) and leads `a` (first slot), so it goes above
    /// `a`, and thus above `b` and `c`, which outrank it. The next show re-freezes.
    /// This is the executable form of the example in `merged`'s doc comment, so a
    /// repair of one side cannot change what was agreed.
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

/// Clicking an orphan row, which has neither a window nor an indexed project.
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

    /// A name SF Symbols does not know draws nothing, and nothing checks these strings
    /// at compile time. Every symbol the app names goes through here, including the
    /// popover's failure mark. The menu bar icon names none: it is drawn.
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
        let aggregate = DataSource.aggregate(sessions, cpu: [:], orphans: [:])
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

    /// The same pair in `--dump`, where the column has a width: the name is cut to what
    /// the brackets leave of the cell, so the cell is exactly as wide as its column and
    /// the count comes out whole. `column` pads without cutting, so a cell wider than
    /// 34 would shift every column to its right on that row only.
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

/// The indicator keeps the same place in every row, whatever else the row holds,
/// and the count in the title line survives a name too long for the row without
/// nudging it.
///
/// `StatusBadge` and `SwitcherRowView` are rendered for real and the ink is read
/// back off the bitmap, in points at scale 4, so a quarter of a point shows.
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

    /// A whole row at a given width, laid out as the list lays it out and built as the
    /// data layer builds one, from real chats and subagents; the row is asked to
    /// confirm it folded to what the test meant.
    ///
    /// Not every status/count pair exists (§3.1): `done` and `asleep` have count zero,
    /// `active` never does. Only `blocked` is free in both, so the count-vs-indicator
    /// checks run against it.
    private func makeRow(status: RowStatus,
                         count: Int,
                         name: String = "проект с длинным именем, которое не влезает",
                         topic: String? = "тема чата, тоже подлиннее строки",
                         usage: TokenCounts? = nil,
                         hourly: TokenCounts? = nil,
                         cpu: Double? = nil,
                         orphans: Int = 0) -> SwitcherRow {
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
        let aggregate = DataSource.aggregate([session], cpu: [:], orphans: [:])
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
                              usage: usage,
                              cpuPercent: cpu,
                              orphanCount: orphans,
                              hourlyUsage: hourly)
        XCTAssertEqual(row.status, status, "the fixture does not fold to \(status)")
        XCTAssertEqual(row.activeCount, count)
        return row
    }

    private func renderRow(status: RowStatus,
                           count: Int,
                           name: String = "проект с длинным именем, которое не влезает",
                           topic: String? = "тема чата, тоже подлиннее строки",
                           usage: TokenCounts? = nil,
                           hourly: TokenCounts? = nil,
                           cpu: Double? = nil,
                           orphans: Int = 0,
                           width: Double) throws -> Rendered {
        let row = makeRow(status: status, count: count, name: name, topic: topic,
                          usage: usage, hourly: hourly, cpu: cpu, orphans: orphans)
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

    /// The longest real project name on this machine, 38 characters and no
    /// spaces in it — the row where the name and the count fight for the line.
    private static let longestName = "wirenboard/node-red-contrib-wirenboard"

    /// The least ink the name may be left with while the count is still drawn. The span
    /// includes the ellipsis and the gap before it: at the floor the name renders
    /// `wire…`, 37.00 pt (25.75 glyphs, 1.75 gap, 9.50 dots); one character less,
    /// `wir…`, is 29.25 pt. The threshold sits between them with 3.75 pt of slack
    /// either way for OS glyph drift.
    private static let nameSpanFloor: Double = 33

    /// Where the badge lands in a whole row: the last box-width before the row's
    /// trailing padding, with the list's own padding outside that.
    private func badgeSlot(inRowOfWidth width: Double) -> ClosedRange<Double> {
        // `LazyVStack` pads the list by 6 and the row pads itself by 7.
        let slotEnd = width - 6 - 7
        return (slotEnd - Double(StatusBadge.boxWidth))...slotEnd
    }

    /// The numbers, in one place, so a change to any of them has to be deliberate. One
    /// slot on the right, the badge's own box; the count lives in the title line.
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

    /// The four glyphs sit in the same slot: each is centred in the same 14 pt box, so
    /// their ink is inside it and shares a midpoint. They differ in width, which is why
    /// the box is fixed.
    ///
    /// The containment half is a canary: `frame` does not clip, so an outgrown glyph
    /// would spill without moving the slot. It has little room (measured in the 20…34
    /// slot, `arrow.triangle.2.circlepath` inks 20.25…33.5), so an SF Symbols or macOS
    /// update can break it. If only containment fails while the midpoints agree, the OS
    /// moved: widen the box.
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

    /// The same thing in a whole row at the real panel width with the list's padding:
    /// the indicator lands in the last 14 pt before the trailing padding (353…367 in a
    /// 380 pt panel) for every status and every count that status can have.
    /// Containment alone does not say "the same place": right-aligned glyphs fit even
    /// without the fixed box, hence the midpoint check (measured within 0.125 of 360).
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

    /// The name gives way when the row runs out of width, not the count: the ellipsis
    /// lands in the name and `(agents: N)` stays whole.
    ///
    /// The label is rendered alone to learn its ink width, then looked for at the end of
    /// the title line: that much ink flush right, with a blank band before it (the
    /// `HStack` spacing). A truncated label would let the name fill that band; a dropped
    /// one leaves the name running to the edge. Both counts are checked, since a label
    /// clamped to a fixed width would pass one by accident.
    ///
    /// The name is the longest real one, 36 characters with no spaces, so a blank band
    /// inside the title line is only the gap before the label; no chat topic, whose
    /// second line would ink the same columns.
    ///
    /// Several widths: at the 380 pt default both fit; narrower (`panelWidth` takes any
    /// positive value) the name is at its floor and the count still whole, at least
    /// `nameSpanFloor` (33 pt, four characters and an ellipsis) surviving, measured
    /// without the colour bar (13.00…16.75). Against the longest name the count is drawn
    /// down to 188 pt with one digit, 193 with two, 201 with three.
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

    /// The top rung, which the test above and the sweep below never reach: the longest
    /// name does not fit whole at 380 pt, so both land on the middle rung.
    ///
    /// A short name fits on the top rung further down, since the middle rung asks for
    /// 40 pt of name and the top rung for the name's own width. Against `p` the count
    /// survives to 156 pt with one digit, 162 with two, 170 with three; the longest name
    /// loses a one-digit count at 188. The width here is halfway, and both halves are
    /// asserted.
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

    /// The floor holds all the way down to where the rung gives out, which pins
    /// `nameFloorWidth` to a number: at 200 pt and up the floor is not binding (the name
    /// takes 44.75 pt or more), so only the sweep catches a floor set too low.
    /// One digit, because the shortest label survives furthest down and squeezes the
    /// name hardest.
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
        // The sweep must not be over rows that all dropped the count. One digit reaches
        // 188 pt, so eighteen of these widths draw it; the bound is deliberately loose. It
        // guards against an empty sweep (a 60 pt floor draws no count at any of these
        // widths), not the exact edge, which OS metrics may move by a point or two.
        XCTAssertGreaterThanOrEqual(widthsWithACount, 8)
    }

    /// One rung of the ladder at one width: is the count still drawn whole, and if so,
    /// how much ink is the name left with? `nil` when the row dropped the count.
    ///
    /// Whether the count is drawn is decided against the same row without one. The name
    /// is measured between the colour bar and the label. The label's ink is passed in
    /// because it does not depend on the width and rendering it per step is slow.
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

    /// Below that floor the count goes, and it goes whole: a row reading
    /// `(agents: 124)` and nothing else identifies no project (§2.2.1). So the row must
    /// draw exactly what the same row without a count draws, not a truncated label.
    /// The equality is over the whole row, indicator included, so an overflow fails it
    /// too.
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

    /// Every measurement above starts its band at the right edge of `colourBar`, a
    /// hand-written range, and reads what is left of the badge as the name. A row with
    /// no name draws the bar exactly there and nothing between it and the indicator; if
    /// a row grows something in that band, the "is the name still there" assertions
    /// would pass on its ink instead.
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

    // MARK: - The rate on the second line

    /// The hour's spend the tests are run against: complete, and 3.40M
    /// input-equivalent — 1M in, 200k out at five times, 400k of cache writes at
    /// 1.25 and 9M of cache reads at a tenth. The line draws it as `3.40M/h`.
    private static let hourSpend = TokenCounts(input: 1_000_000,
                                               output: 200_000,
                                               cacheCreation: 400_000,
                                               cacheRead: 9_000_000)

    /// The same figure a decimal order of magnitude up, so that the two labels
    /// differ in *width*: `34.00M/h` against `3.40M/h`. What it is for is asking
    /// "is the rate on the line at all" without comparing a row against a row that
    /// has no rate to draw — the predicate §4 spells out, which a "with it and
    /// without it" comparison cannot answer.
    private static let widerHourSpend = TokenCounts(input: 10_000_000,
                                                    output: 2_000_000,
                                                    cacheCreation: 4_000_000,
                                                    cacheRead: 90_000_000)

    /// A row whose title line draws nothing, so that every column of ink between
    /// the colour bar and the indicator belongs to the second line.
    ///
    /// The columns of a render are collapsed over the whole height of the row,
    /// so the name and the topic would otherwise be measured as one thing —
    /// which is the same reason `testNothingButTheNameLivesBetweenTheBarAndTheSlot`
    /// renders a nameless row.
    private func renderSecondLine(topic: String?,
                                  hourly: TokenCounts?,
                                  width: Double) throws -> Rendered {
        try renderRow(status: .blocked, count: 0, name: "", topic: topic, hourly: hourly, width: width)
    }

    /// The number's own ink, rendered alone in the font the second line draws it
    /// in.
    private func inkWidthOfLabel(_ label: String) throws -> Double {
        let alone = try measure(Text(label)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(Self.pad))
        let ink = try XCTUnwrap(alone.span)
        return ink.upperBound - ink.lowerBound
    }

    /// The rate is at the right-hand end of the second line, not wherever the
    /// topic happens to stop. Measured against a topic short enough that the two
    /// cannot be confused: if the number simply followed the topic it would be
    /// tens of points to the left of where it is.
    func testTheRateStandsAtTheRightEndOfTheSecondLine() throws {
        let width = Config.default.panelWidth
        let label = try XCTUnwrap(SwitcherRowView.rateLabel(for: makeRow(status: .blocked,
                                                                         count: 0,
                                                                         hourly: Self.hourSpend)))
        XCTAssertEqual(label, "3.40M/h")
        let labelWidth = try inkWidthOfLabel(label)

        let rendered = try renderSecondLine(topic: "тема", hourly: Self.hourSpend, width: width)
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

    /// The number never gives way; the topic does. `fixedSize` says so, and only at
    /// 150 pt does it matter (at 240 and 380 pt both fit). The number's ink is compared
    /// with the same string rendered alone, so a truncated `3.40M/…` fails though it is
    /// still drawn.
    func testTheRateIsNeverCutWhileTheTopicIs() throws {
        let label = try XCTUnwrap(SwitcherRowView.rateLabel(for: makeRow(status: .blocked,
                                                                         count: 0,
                                                                         hourly: Self.hourSpend)))
        let labelWidth = try inkWidthOfLabel(label)
        var topicWidths: [Double] = []

        for width in [Config.default.panelWidth, 240.0, 150.0] {
            let rendered = try renderSecondLine(topic: "тема чата, тоже подлиннее строки",
                                                hourly: Self.hourSpend,
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

    /// A row with a rate and no chat is the number alone, still on the right.
    func testARowWithARateAndNoTopicIsJustTheNumber() throws {
        let width = Config.default.panelWidth
        let label = try XCTUnwrap(SwitcherRowView.rateLabel(for: makeRow(status: .blocked,
                                                                         count: 0,
                                                                         hourly: Self.hourSpend)))
        let labelWidth = try inkWidthOfLabel(label)
        let rendered = try renderSecondLine(topic: nil, hourly: Self.hourSpend, width: width)
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
    ///
    /// The week's figure is one of the variants, and it is there to fail: it is
    /// the tooltip's now, and a row that has only a week has nothing to draw on
    /// this line.
    func testARowWithNeitherTopicNorRateGrowsNoSecondLine() throws {
        let width = Config.default.panelWidth
        let bare = try renderRow(status: .blocked, count: 0, name: "имя",
                                 topic: nil, usage: nil, width: width)
        XCTAssertEqual(bare.size.height, 38, accuracy: 0.01,
                       "a row with nothing to say is not the minimum height any more")
        let variants: [(topic: String?, hourly: TokenCounts?)] = [
            ("тема", nil), (nil, Self.hourSpend), ("тема", Self.hourSpend)
        ]
        for second in variants {
            let rendered = try renderRow(status: .blocked, count: 0, name: "имя",
                                         topic: second.topic, hourly: second.hourly, width: width)
            XCTAssertGreaterThan(rendered.size.height, bare.size.height,
                                 "no second line for topic=\(second.topic as Any)")
        }
        let weekOnly = try renderRow(status: .blocked, count: 0, name: "имя",
                                     topic: nil, usage: Self.hourSpend, hourly: nil, width: width)
        XCTAssertEqual(weekOnly.size.height, bare.size.height, accuracy: 0.01,
                       "the week's total is the tooltip's; the line must not grow for it")
    }

    /// Is the rate drawn at all, asked with two rates of different width rather than a
    /// rate against no rate: two rates differ only in the label's width, so only the
    /// label can make the renders differ.
    ///
    /// A rate against no rate is two compositions of the line: `secondLine` gives the
    /// topic whatever the number does not take (`Spacer(minLength: 0)`, a tail-truncating
    /// topic), so at narrow widths the topic's own ink changes too. §4 keeps the same trap
    /// under the bracket and the percentage, but there the mechanism is `titleLine`'s
    /// `ViewThatFits`; `secondLine` has none.
    func testPROBEnaiveVerdict() throws {
        let topic = "тема чата, тоже подлиннее строки"
        for width in [150.0, 240.0, Config.default.panelWidth] {
            let withRate = try renderSecondLine(topic: topic, hourly: Self.hourSpend, width: width)
            let without = try renderSecondLine(topic: topic, hourly: nil, width: width)
            print("PROBE naive width=\(width) identical=\(withRate.ink == without.ink)"
                + " cols=\(withRate.ink.count)/\(without.ink.count)")
        }
    }

    func testPROBEwindowBreakdown() throws {
        let topic = "тема чата, тоже подлиннее строки"
        let width = 150.0
        for counts in [Self.hourSpend, Self.widerHourSpend] {
            let label = try XCTUnwrap(SwitcherRowView.rateLabel(for: makeRow(status: .blocked,
                                                                             count: 0,
                                                                             hourly: counts)))
            let width0 = try inkWidthOfLabel(label)
            let rendered = try renderSecondLine(topic: topic, hourly: counts, width: width)
            let slot = badgeSlot(inRowOfWidth: width)
            let line = try XCTUnwrap(rendered.span(from: Self.colourBar.upperBound + 0.25,
                                                   to: slot.lowerBound - 3))
            let start = line.upperBound - width0 - 0.5
            let inside = rendered.ink.filter { $0 >= start && $0 <= line.upperBound }.sorted()
            var gaps: [(Double, Double)] = []
            for i in 1..<inside.count { gaps.append((inside[i] - inside[i - 1], inside[i - 1])) }
            gaps.sort { $0.0 > $1.0 }
            let cut = gaps.first ?? (0, 0)
            let number = inside.filter { $0 > cut.1 }
            let topicInk = inside.filter { $0 <= cut.1 }
            print("PROBE brk label=\(label) alone=\(width0)"
                + " window=\((inside.last ?? 0) - (inside.first ?? 0))"
                + " gaps=\(gaps.prefix(3).map { $0.0 })"
                + " gap=\(cut.0)"
                + " number=\((number.last ?? 0) - (number.first ?? 0))"
                + " topic=\((topicInk.last ?? 0) - (topicInk.first ?? 0))")
        }
    }

    private func rateIsDrawn(width: Double, topic: String?) throws -> Bool {
        let narrow = try renderSecondLine(topic: topic, hourly: Self.hourSpend, width: width)
        let wide = try renderSecondLine(topic: topic, hourly: Self.widerHourSpend, width: width)
        return narrow.ink != wide.ink
    }

    /// The rate is whole at the default width and at 150 pt, the narrow end of
    /// `panelWidth`. A modifier that seems to change nothing at the default width
    /// is checked at that boundary, where it is load-bearing.
    ///
    /// Clipping is caught by comparing the number's ink span (`min…max` of inked
    /// columns) with the same string rendered alone. The window is taken leftwards from
    /// the line's end by the label's whole width, so a clipped number leaves the window
    /// over the gap and into the topic, and `span` returns the union. Hence the 6 pt gap
    /// in front of the number is asserted blank, as in
    /// `testTheRateIsNeverCutWhileTheTopicIs`.
    func testTheRateIsWholeAtBothEndsOfThePanelWidthRange() throws {
        let topic = "тема чата, тоже подлиннее строки"
        for width in [Config.default.panelWidth, 150.0] {
            XCTAssertTrue(try rateIsDrawn(width: width, topic: topic), "no rate at \(width) pt")

            var drawn: [Double] = []
            var alone: [Double] = []
            for (counts, expected) in [(Self.hourSpend, "3.40M/h"),
                                       (Self.widerHourSpend, "34.00M/h")] {
                let label = try XCTUnwrap(SwitcherRowView.rateLabel(for: makeRow(status: .blocked,
                                                                                 count: 0,
                                                                                 hourly: counts)))
                XCTAssertEqual(label, expected)
                let width0 = try inkWidthOfLabel(label)
                let rendered = try renderSecondLine(topic: topic, hourly: counts, width: width)
                let slot = badgeSlot(inRowOfWidth: width)
                let line = try XCTUnwrap(rendered.span(from: Self.colourBar.upperBound + 0.25,
                                                       to: slot.lowerBound - 3),
                                         "nothing drawn at \(width) pt")
                let start = line.upperBound - width0 - 0.5
                XCTAssertTrue(rendered.isBlank(from: start - 3.5, to: start - 1), """
                    \(label) was cut at \(width) pt: the window that measures it reached past \
                    the gap and into the topic, so the span below would be the two together
                    """)
                let number = try XCTUnwrap(rendered.span(from: start, to: line.upperBound),
                                           "no number at \(width) pt for \(label)")
                drawn.append(number.upperBound - number.lowerBound)
                alone.append(width0)
                XCTAssertEqual(drawn.last!, width0, accuracy: 0.5, "\(label) was cut at \(width) pt")
            }
            // Both widths having been checked against their own render, this adds
            // one thing and it is small: half a point of tolerance on the pair
            // instead of the full point the two assertions above can accumulate
            // between them. It is not what catches a clipped label — the blank gap
            // is — and it is kept because the property it states is the one the
            // reader wants: the wider label is wider by exactly its extra glyph.
            XCTAssertEqual(drawn[1] - drawn[0], alone[1] - alone[0], accuracy: 0.5,
                           "the wider rate lost a glyph at \(width) pt")
            XCTAssertGreaterThan(drawn[1], drawn[0])
        }
    }

    // MARK: - CPU on the title line

    /// The CPU figure the layout round is run against: `38%`, three characters,
    /// the ordinary shape of the number.
    private static let cpu: Double = 38.4

    /// A percentage of the same shape but wider: `412%` against `38%`.
    private static let widerCPU: Double = 412

    /// Is the percentage on the line at this width? Decided against a wider percentage,
    /// not against none: below the percentage's floor a row with one falls a rung
    /// further than a row without, so those differ while neither draws a percentage. Two
    /// figures differing only in width draw the same when dropped. The predicate is
    /// about the narrow figure; the wide one may already be dropped.
    private func cpuIsDrawn(width: Double, count: Int, name: String) throws -> Bool {
        let narrow = try renderRow(status: .blocked, count: count, name: name,
                                   topic: nil, cpu: Self.cpu, width: width)
        let wide = try renderRow(status: .blocked, count: count, name: name,
                                 topic: nil, cpu: Self.widerCPU, width: width)
        return narrow.ink != wide.ink
    }

    /// And is the count on the line? Asked the same way and for the same reason:
    /// a count of one more digit is wider while everything else about the row
    /// stays put. `beside` is the percentage the row carries, `nil` for a row
    /// that has none — the same question put to both ladders.
    private func countIsDrawn(width: Double, count: Int, name: String,
                              beside cpu: Double?) throws -> Bool {
        let narrow = try renderRow(status: .blocked, count: count, name: name,
                                   topic: nil, cpu: cpu, width: width)
        let wide = try renderRow(status: .blocked, count: count * 10 + 1, name: name,
                                 topic: nil, cpu: cpu, width: width)
        return narrow.ink != wide.ink
    }

    /// The percentage stands at the right-hand end of the title line, in the same column
    /// as the spend below it. The two are measured apart (a render collapses columns
    /// over the row's height), each row drawn with nothing else on its line, so the ink
    /// at the right-hand end is the label alone.
    func testTheCPUStandsInTheSameColumnAsTheSpendBelowIt() throws {
        let width = Config.default.panelWidth
        let slot = badgeSlot(inRowOfWidth: width)

        let onTitle = try renderRow(status: .blocked, count: 0, name: "p",
                                    topic: nil, cpu: Self.cpu, width: width)
        let title = try XCTUnwrap(onTitle.span(from: Self.colourBar.upperBound + 0.25,
                                               to: slot.lowerBound - 3),
                                  "the title line drew nothing")

        let onSecondLine = try renderSecondLine(topic: nil, hourly: Self.hourSpend, width: width)
        let second = try XCTUnwrap(onSecondLine.span(from: Self.colourBar.upperBound + 0.25,
                                                     to: slot.lowerBound - 3),
                                   "the second line drew nothing")

        // Half a point: the two labels are different strings, so their last
        // glyph has a right side bearing of its own.
        XCTAssertEqual(title.upperBound, second.upperBound, accuracy: 0.5,
                       "the percentage is not above the spend")
        // And it really is at the end of the line rather than trailing the name:
        // `p` is one character, so a percentage that simply followed it would be
        // two hundred points to the left.
        XCTAssertGreaterThan(title.upperBound - title.lowerBound, 200)
    }

    /// Both figures are drawn at the default width, and the percentage is whole
    /// beside a count of any size.
    func testTheTitleCarriesBothFiguresAtPanelWidth() throws {
        for count in [1, 123] {
            XCTAssertTrue(try cpuIsDrawn(width: Config.default.panelWidth,
                                         count: count,
                                         name: Self.longestName),
                          "no percentage at the default width — count=\(count)")
            XCTAssertTrue(try countIsDrawn(width: Config.default.panelWidth,
                                           count: count,
                                           name: Self.longestName,
                                           beside: Self.cpu),
                          "the count went away at the default width — count=\(count)")
        }
    }

    /// The degradation order the ladder encodes: as the panel narrows the percentage
    /// goes first, then the count, and the name outlives both.
    ///
    /// Swept, because an order needs both boundaries. Against the longest name the
    /// percentage is drawn down to 224 pt and the count to 186; against a one-character
    /// name 192 and 154. Both names, because only the short one stands on rung 3 (the
    /// longest reaches 186 through rung 4). The count's floor is the same with or
    /// without a percentage, since the percentage is always dropped first.
    ///
    /// The assertions are the order, that equality and each rung being reached, not the
    /// exact widths, which move with OS font metrics. The 5 pt step is enough for that.
    func testThePercentageGivesWayBeforeTheCountDoes() throws {
        for name in [Self.longestName, "p"] {
            var lastWidthWithCPU: Double?
            var lastWidthWithCount: Double?
            var lastWidthWithCountAlone: Double?
            var width = Config.default.panelWidth
            while width >= 150 {
                if try cpuIsDrawn(width: width, count: 1, name: name) {
                    lastWidthWithCPU = width
                }
                if try countIsDrawn(width: width, count: 1, name: name, beside: Self.cpu) {
                    lastWidthWithCount = width
                }
                if try countIsDrawn(width: width, count: 1, name: name, beside: nil) {
                    lastWidthWithCountAlone = width
                }
                width -= 5
            }
            let cpuFloor = try XCTUnwrap(lastWidthWithCPU,
                                         "the percentage was never drawn at all — \(name)")
            let countFloor = try XCTUnwrap(lastWidthWithCount,
                                           "the count was never drawn at all — \(name)")
            XCTAssertGreaterThan(cpuFloor, countFloor,
                                 "the count gave way before the percentage did — \(name)")
            // And both rungs are actually visited inside the swept range, so the
            // inequality is not two constants that both sit outside it.
            XCTAssertLessThan(cpuFloor, Config.default.panelWidth, name)
            XCTAssertGreaterThan(countFloor, 150, name)

            let alone = try XCTUnwrap(lastWidthWithCountAlone,
                                      "the count was never drawn without a percentage — \(name)")
            XCTAssertEqual(countFloor, alone,
                           "the percentage cost the count \(countFloor - alone) pt of panel — \(name)")
        }
    }

    /// Below all of it the name still wins: at 150 pt the row draws what it drew
    /// before either figure existed.
    ///
    /// The same rule §2.2.1 states for the count — a row that identifies no
    /// project is no better than one parked at the bottom of a 93-row list —
    /// and the percentage has even less claim on the line than the count does.
    func testANarrowPanelKeepsOnlyTheName() throws {
        let width = 150.0
        let bare = try renderRow(status: .blocked, count: 0, name: Self.longestName,
                                 topic: nil, cpu: nil, width: width)
        let loaded = try renderRow(status: .blocked, count: 5, name: Self.longestName,
                                   topic: nil, cpu: Self.cpu, orphans: 3, width: width)
        XCTAssertEqual(loaded.ink, bare.ink, "something other than the name survived 150 pt")
    }

    /// The percentage never moves the indicator, whatever it says — the badge
    /// holds the same column on every row (§4), and a figure that grew from two
    /// digits to four must not push it.
    func testTheCPUNeverMovesTheIndicator() throws {
        let width = Config.default.panelWidth
        let slot = badgeSlot(inRowOfWidth: width)
        var seen: ClosedRange<Double>?
        for cpu in [nil, 1.0, 38.4, 250.0, 1600.0] as [Double?] {
            let rendered = try renderRow(status: .blocked, count: 1, name: "p",
                                         topic: nil, cpu: cpu, width: width)
            let badge = try XCTUnwrap(rendered.span(rightOf: slot.lowerBound - 3),
                                      "no indicator drawn for cpu=\(cpu as Any)")
            if let seen {
                XCTAssertEqual(badge.lowerBound, seen.lowerBound, accuracy: 0.01, "cpu=\(cpu as Any)")
                XCTAssertEqual(badge.upperBound, seen.upperBound, accuracy: 0.01, "cpu=\(cpu as Any)")
            } else {
                seen = badge
            }
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
        let aggregate = DataSource.aggregate(sessions, cpu: [:], orphans: [:])
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
        /// One inked pixel: where it is, what colour it came out, and how strongly. The
        /// picture is not a template (§4), so its colour is something these tests ask.
        /// The components are straight, divided back out by the premultiplied alpha, so an
        /// antialiased edge reads as the same colour, only fainter.
        typealias Dot = (x: Double, y: Double,
                         red: Double, green: Double, blue: Double, alpha: Double)

        var width: Double
        var height: Double
        /// Every inked pixel, in points from the left and the *bottom* edges —
        /// the picture is drawn `flipped: false`, so a larger y is higher up, and
        /// that is the coordinate system the icon's own geometry is stated in.
        var ink: [Dot]

        /// Columns carrying ink inside a band of rows: the way the number is told
        /// from the bar now that they are stacked rather than side by side.
        func columns(in band: ClosedRange<CGFloat>) -> [Double] {
            rows(in: band).map(\.x)
        }

        func rows(in band: ClosedRange<CGFloat>) -> [Dot] {
            ink.filter { $0.y >= Double(band.lowerBound) && $0.y <= Double(band.upperBound) }
        }

        /// How light or dark the ink in a band came out, 0 for black and 1 for
        /// white. `nil` when nothing was drawn there.
        ///
        /// Only the pixels the strokes actually cover: below half alpha a pixel is
        /// an edge, and an edge of black ink on transparency is still black but
        /// its straight colour is worked out from one or two bits of information.
        func luminance(in band: ClosedRange<CGFloat>) -> Double? {
            let solid = rows(in: band).filter { $0.alpha > 0.5 }
            guard !solid.isEmpty else { return nil }
            // Rec. 709, the usual weighting: a colour test that averaged the
            // three channels flat would call full green as light as 59% grey.
            let total = solid.reduce(0.0) { $0 + 0.2126 * $1.red + 0.7152 * $1.green + 0.0722 * $1.blue }
            return total / Double(solid.count)
        }

        /// The mean colour of everything in a band that was drawn in a colour of
        /// its own — which inside the bar is the fill and nothing else, the frame
        /// around it being ink. `nil` when there is no such pixel.
        func chromaticMean(in band: ClosedRange<CGFloat>) -> (red: Double, green: Double, blue: Double)? {
            let coloured = rows(in: band).filter { dot in
                guard dot.alpha > 0.5 else { return false }
                let high = max(dot.red, dot.green, dot.blue)
                let low = min(dot.red, dot.green, dot.blue)
                return high > 0 && (high - low) / high > 0.3
            }
            guard !coloured.isEmpty else { return nil }
            let count = Double(coloured.count)
            return (coloured.reduce(0.0) { $0 + $1.red } / count,
                    coloured.reduce(0.0) { $0 + $1.green } / count,
                    coloured.reduce(0.0) { $0 + $1.blue } / count)
        }

        /// How much was drawn inside a band, in pixels — the fill of a bar is an
        /// area, not a span, so a proportion has to be counted rather than
        /// measured.
        func pixels(in band: ClosedRange<CGFloat>) -> Int { rows(in: band).count }

        /// The bands of rows that carry ink, split wherever half a point of the picture is
        /// blank. Found in the rendering rather than taken from the icon's geometry: a check
        /// inside the two declared bands cannot see the number drawn into the bar's rows.
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

    /// The rows where the bar's frame is the only thing that can be drawn: outside the
    /// fill's own bounds and inside the bar's. Anything the warning fires on has a full
    /// capsule under it, so a band holding both would measure the fill as the frame.
    ///
    /// The lower edge is measured at scale 4 with `chromaticMean`'s predicate (alpha
    /// over a half, relative chroma over 0.3) on both plates: fill colour reaches
    /// y = 16.25, nothing clears the cut at 16.50, and from 16.75 there is none until the
    /// frame. The extra quarter point is slack so the band starts on the first row with
    /// no fill colour at all.
    private static var frameBand: ClosedRange<CGFloat> {
        (MenuBarIcon.barFillBounds.maxY + 0.25)...MenuBarIcon.barRect.maxY
    }

    /// The rows the fill occupies, its own bounds. The frame's rounded ends do
    /// sweep through them at either edge of the picture, which costs nothing: on
    /// the readings where the frame is coloured at all it is the fill's own
    /// colour, and below that boundary it is ink and the chroma filter drops it.
    private static var fillBand: ClosedRange<CGFloat> {
        MenuBarIcon.barFillBounds.minY...MenuBarIcon.barFillBounds.maxY
    }

    private static let scale = 4.0

    /// A burn ratio to colour a bar by, in per cent of the week's refill rate. One
    /// number and a flag, which is all the drawing reads.
    private func ratio(_ percent: Double,
                       lowerBound: Bool = false) -> UsagePopoverView.HeadlineRatio {
        UsagePopoverView.HeadlineRatio(percent: percent, isLowerBound: lowerBound)
    }

    /// The appearance is always named: the picture is not a template, so its colour
    /// depends on this input, and inheriting the runner's appearance would make the
    /// suite depend on the time of day.
    private func render(_ ratio: UsagePopoverView.HeadlineRatio?,
                        appearance: NSAppearance? = NSAppearance(named: .aqua)) throws -> Rendered {
        let image = MenuBarIcon.image(for: ratio, appearance: try XCTUnwrap(appearance))
        XCTAssertFalse(image.isTemplate, """
            the status item picture is a template again: the system would tint the bar's fill \
            for the menu bar and the colour that says whether the week holds the demand would \
            be gone (§4)
            """)

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

        var ink: [Rendered.Dot] = []
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                let base = (y * width + x) * 4
                let alpha = Double(pixels[base + 3]) / 255
                // Row 0 of a bitmap context's buffer is the top of the image,
                // whichever way the context's own coordinate system runs.
                ink.append((x: Double(x) / Self.scale,
                            y: Double(height - 1 - y) / Self.scale,
                            red: Double(pixels[base]) / 255 / alpha,
                            green: Double(pixels[base + 1]) / 255 / alpha,
                            blue: Double(pixels[base + 2]) / 255 / alpha,
                            alpha: alpha))
            }
        }
        return Rendered(width: image.size.width, height: image.size.height, ink: ink)
    }

    /// The whole point of a fixed column: the item never changes width, so the
    /// items to the left of it never shuffle. Not just across digits — across
    /// the presence of a figure at all, which is the second way a status item
    /// can be made to twitch, once a minute, whenever a tunnel goes down.
    func testThePictureIsTheSameWidthWhateverTheFigure() throws {
        let widths = try [nil, ratio(0), ratio(5), ratio(42), ratio(100), ratio(197),
                          ratio(999), ratio(1000), ratio(1e12)].map { try render($0).width }
        for width in widths {
            XCTAssertEqual(width, widths[0], accuracy: 0.001, "widths: \(widths)")
        }
        // And that width is the one the column arithmetic says, not whatever a
        // 5% string happened to need.
        XCTAssertEqual(widths[0], Double(MenuBarIcon.width), accuracy: 0.001)
        XCTAssertEqual(MenuBarIcon.numberColumnWidth,
                       ceil(NSAttributedString(string: "\(MenuBarIcon.ceilingPercent)%",
                                               attributes: [.font: MenuBarIcon.font]).size().width),
                       accuracy: 0.001)
    }

    /// With the number under the bar, the picture's width is the number's column and
    /// nothing else: 27 points. The width is laid out here rather than compared against
    /// the icon's own arithmetic: the picture must be as wide as the widest string it
    /// can hold, which this test measures itself.
    func testThePictureIsExactlyTheNumbersColumnWide() throws {
        let widest = ceil(NSAttributedString(string: "\(MenuBarIcon.ceilingPercent)%",
                                             attributes: [.font: MenuBarIcon.font]).size().width)
        XCTAssertEqual(MenuBarIcon.width, widest, accuracy: 0.001)
        XCTAssertEqual(try render(ratio(100)).width, Double(widest), accuracy: 0.001)
        XCTAssertLessThan(MenuBarIcon.width, 30,
                          "the item is back to taking a row of the menu bar: \(MenuBarIcon.width) pt")
        // And the stack fills the height a status item is drawn at, exactly.
        // Not "fits": a stack shorter than the picture is bar fill thrown away
        // — the fill is the reading, and `insetBy(dy: 1.5)` leaves it 3 points
        // of the bar's 6 — while a taller one is clipped.
        XCTAssertEqual(MenuBarIcon.contentHeight, MenuBarIcon.height, accuracy: 0.001,
                       "bar \(MenuBarIcon.barHeight) + gap \(MenuBarIcon.gap) "
                       + "+ number \(MenuBarIcon.numberHeight) is not the 18 pt of the picture")
        XCTAssertEqual(try render(ratio(42)).height, Double(MenuBarIcon.height), accuracy: 0.001)
    }

    /// Drawn, and not merely declared: the number's ink is below the bar's, the
    /// two do not touch, and the bar is drawn across the whole width of the
    /// picture rather than in a column of its own.
    func testTheNumberIsDrawnUnderTheBarAndNothingOverlaps() throws {
        let rendered = try render(ratio(42))
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

    /// The number sits flush with the right edge of the picture, so the `%` stays in one
    /// place, and every figure the picture can draw fits the measured width (a ratio has
    /// no top, so an outgrown figure would lose its leading digit to the image bounds).
    ///
    /// The laid-out width is asked, not where the ink starts: `1000%` drawn flush right
    /// in this 27 pt picture inks from 0.25 to 26.25, the same span as `999%`. The
    /// bitmaps differ, and `testTheFigureIsCappedAtThreeDigitsAndNeverClipped` looks
    /// there.
    func testEveryFigureEndsAtTheSameEdgeAndFitsItsColumn() throws {
        var rightEdges: [Double] = []
        for percent in [0.0, 5, 42, 100, 197, 999, 1000, 1e12] {
            let columns = try render(ratio(percent)).columns(in: MenuBarIcon.numberRows)
            XCTAssertFalse(columns.isEmpty, "nothing drawn for \(percent)%")
            rightEdges.append(try XCTUnwrap(columns.max()))
            XCTAssertLessThanOrEqual(MenuBarIcon.label(for: ratio(percent)).size().width,
                                     MenuBarIcon.width,
                                     "at \(percent)% the string is wider than the column and the "
                                     + "leading digit is drawn outside the picture")
        }
        for edge in rightEdges {
            XCTAssertEqual(edge, rightEdges[0], accuracy: 0.5, "right edges: \(rightEdges)")
        }
    }

    /// No reading, no number, and the picture does not fall back to the weekly quota as
    /// the popover's headline does: the popover captions which quantity it shows, and 27
    /// points of menu bar have no room for that. A genuine zero is drawn: "nothing
    /// measured" and "spending nothing" must look different.
    func testWithoutAReadingNoNumberIsDrawnAtAll() throws {
        let blank = try render(nil)
        XCTAssertTrue(blank.rows(in: MenuBarIcon.numberRows).isEmpty,
                      "something was drawn in the number's rows with no reading")
        XCTAssertFalse(blank.rows(in: Self.barBand).isEmpty,
                       "the dashed bar is missing too: the measurement is not about the number")
        XCTAssertFalse(try render(ratio(0)).rows(in: MenuBarIcon.numberRows).isEmpty,
                       "a genuine 0% drew no number")

        // And the fallback is refused where it would be taken: a snapshot with a
        // quota to fall back on and no ratio draws exactly the same nothing.
        var snapshot = UsageSnapshot.empty
        snapshot.fleetSevenDayMean = 47.4
        XCTAssertNil(MenuBarIcon.ratio(for: snapshot),
                     "the fixture has a ratio after all and cannot say anything about the fallback")
        XCTAssertEqual(UsagePopoverView.quotaLabel(for: snapshot), "47%",
                       "the popover has a quota to lead with here, which is the whole point")
        XCTAssertTrue(try render(MenuBarIcon.ratio(for: snapshot))
            .rows(in: MenuBarIcon.numberRows).isEmpty,
                      "the menu bar fell back to the quota, in a picture with no room to say so")
    }

    /// The number is the spend ratio and not the week's mean. Both figures are in the
    /// snapshot and differ; compared against separate renderings of the two, so the ink
    /// of `126%` is the assertion and the ink of `47%` the control.
    func testTheNumberIsTheRatioAndNotTheWeeksMean() throws {
        var snapshot = UsageSnapshot.empty
        snapshot.fleetSevenDayMean = 47.4
        snapshot.fleetBurn = UsagePopoverLabelTests.burn(126)
        snapshot.historiesFetchedAt = Date()
        let drawn = try render(MenuBarIcon.ratio(for: snapshot))
            .columns(in: MenuBarIcon.numberRows)
        XCTAssertEqual(drawn, try render(ratio(126)).columns(in: MenuBarIcon.numberRows),
                       "the number is not the 126% the fleet burned against its refill")
        XCTAssertNotEqual(drawn, try render(ratio(47)).columns(in: MenuBarIcon.numberRows),
                          "the number is still the weekly mean")
        XCTAssertEqual(MenuBarIcon.label(for: try XCTUnwrap(MenuBarIcon.ratio(for: snapshot))).string,
                       "126%")
    }

    /// The bar says what the number does. Measured as area, because the outline spans
    /// the whole bar in every state. It stops at the refill rate, as the popover's lead
    /// bar does: past that the figure under it says the rest.
    func testTheBarFillsWithTheRatioAndStopsAtTheRefillRate() throws {
        let inked = try [nil, ratio(0), ratio(50), ratio(100)]
            .map { try render($0).pixels(in: Self.barBand) }
        // Dashed and empty is the least ink of all; a bar drawn 0% full is a
        // solid outline and already more.
        XCTAssertLessThan(inked[0], inked[1], "the dashed empty bar is not the emptiest: \(inked)")
        XCTAssertLessThan(inked[1], inked[2], "0% is not emptier than 50%: \(inked)")
        XCTAssertLessThan(inked[2], inked[3], "50% is not emptier than 100%: \(inked)")

        // The clamp, in points of fill rather than in pixels of band, because the
        // band carries the frame too and the frame changes colour at the anchor.
        XCTAssertEqual(MenuBarIcon.fillWidth(for: ratio(50)),
                       MenuBarIcon.barFillBounds.width / 2, accuracy: 0.001)
        for percent in [100.0, 130, 300, 1e12] {
            XCTAssertEqual(MenuBarIcon.fillWidth(for: ratio(percent)),
                           MenuBarIcon.barFillBounds.width, accuracy: 0.001,
                           "at \(percent)% the fill is not stopped at the refill rate")
        }
    }

    /// The figure is capped at three digits. The ratio has no top while the column is a
    /// constant (a status item that resizes drags every item to its left). Drawn flush
    /// right, a clipped `1000%` is pixel for pixel the drawing of `000%`, so `999%` is
    /// the top of the drawn scale and a floor rather than a reading; the accessibility
    /// description says what was measured.
    func testTheFigureIsCappedAtThreeDigitsAndNeverClipped() throws {
        XCTAssertEqual(MenuBarIcon.label(for: ratio(999)).string, "999%")
        XCTAssertEqual(MenuBarIcon.label(for: ratio(1000)).string, "999%")
        XCTAssertEqual(MenuBarIcon.label(for: ratio(1e12)).string, "999%")
        // Not a cap on the reading: the description carries the figure whole.
        XCTAssertEqual(MenuBarIcon.describe(ratio(1240)),
                       "1240% of the weekly refill rate")

        // Drawn, and identical to the drawing of the cap itself. The comparison
        // is the ink and not its span: a clipped `1000%` spans 0.25…26.25, which
        // is exactly what `999%` spans, so a test on the edges would pass over
        // the defect it is named after.
        let capped = try render(ratio(1000)).columns(in: MenuBarIcon.numberRows)
        XCTAssertEqual(capped, try render(ratio(999)).columns(in: MenuBarIcon.numberRows))
        // The column is measured on the cap and nothing else, so moving the cap
        // moves the column instead of overflowing it.
        XCTAssertEqual(MenuBarIcon.numberColumnWidth,
                       ceil(NSAttributedString(string: "\(MenuBarIcon.ceilingPercent)%",
                                               attributes: [.font: MenuBarIcon.font]).size().width),
                       accuracy: 0.001)
        // And the rounding is the popover's, so the two surfaces print the same
        // digits wherever the picture is not capped.
        XCTAssertEqual(MenuBarIcon.label(for: ratio(125.6)).string, "126%")
        XCTAssertEqual(MenuBarIcon.label(for: ratio(0)).string, "0%")
    }

    // MARK: - Colour, now that the picture owns it

    /// The fill is a ramp over the load, not a step at capacity, on a light and a dark
    /// menu bar.
    ///
    /// Read off the drawn picture as a hue. Three assertions hold together: the ends are
    /// flat (60 and 70 one colour, 130 and 150 one colour), the middle is monotone, and
    /// every sample matches the rule the popover paints with, so the two surfaces cannot
    /// drift into two ramps. A grey picture fails: saturation is asserted, and
    /// `chromaticMean` returns `nil` where nothing has a colour of its own. The fill is
    /// as long as the ratio and coloured by it, so every sample past the anchor is a
    /// full capsule.
    func testTheFillIsARampFromBlueThroughGreenToRed() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let plate = MenuBarIcon.background(for: appearance)
            var drawn: [Double] = []
            for percent in rampSamples {
                let fill = try XCTUnwrap(render(ratio(percent), appearance: appearance)
                    .chromaticMean(in: Self.barBand),
                                         "at \(percent)% of capacity the bar on a \(name.rawValue) "
                                         + "menu bar has no colour of its own at all")
                XCTAssertGreaterThan(saturation(of: fill), 0.5,
                                     "at \(percent)% the fill came out all but grey: \(fill)")
                XCTAssertEqual(hue(of: fill),
                               hue(of: UsagePopoverView.ratioColor(atPercent: percent, on: plate)),
                               accuracy: 0.01,
                               "at \(percent)% the menu bar drew a hue of its own rather than the "
                               + "one the popover paints with (\(name.rawValue))")
                drawn.append(hue(of: fill))
            }
            assertRamp(drawn, on: name.rawValue)
        }

        // And with no reading at all the bar is not painted: an unmeasured fleet
        // must be neither good news nor bad.
        XCTAssertNil(try render(nil).chromaticMean(in: Self.barBand),
                     "a bar with no reading behind it was drawn in a colour that means something")
    }

    /// The one boundary the colour rules keep: the frame and the number are ink below
    /// capacity and take the ramp above it, on both menu bars. The calm fixture is a
    /// hair under the boundary so the boundary itself is held; above, the frame is the
    /// ramp's green at capacity and its red by 130%.
    ///
    /// The frame is read off `frameBand`, not the whole bar: a sample near the anchor is
    /// an almost full capsule, so the whole bar would measure the fill. Only the stroke
    /// reaches those rows.
    func testTheFrameAndTheNumberAreInkBelowCapacityAndTakeTheRampAbove() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let plate = MenuBarIcon.background(for: appearance)
            let calm = try render(ratio(UsagePopoverView.greenRatioPercent - 0.001),
                                  appearance: appearance)
            XCTAssertNil(calm.chromaticMean(in: Self.frameBand),
                         "a hair under capacity the frame was painted on \(name.rawValue)")
            XCTAssertNil(calm.chromaticMean(in: MenuBarIcon.numberRows),
                         "a hair under capacity the number was painted on \(name.rawValue)")

            var frames: [Double] = []
            var numbers: [Double] = []
            for percent in rampSamples where percent >= UsagePopoverView.greenRatioPercent {
                let warned = try render(ratio(percent), appearance: appearance)
                let frame = try XCTUnwrap(warned.chromaticMean(in: Self.frameBand),
                                          "at \(percent)% the frame carries no warning at all")
                let number = try XCTUnwrap(warned.chromaticMean(in: MenuBarIcon.numberRows),
                                           "at \(percent)% the number carries no warning at all")
                let expected = hue(of: UsagePopoverView.ratioColor(atPercent: percent, on: plate))
                XCTAssertEqual(hue(of: frame), expected, accuracy: 0.01,
                               "at \(percent)% the frame is not the ramp's colour (\(name.rawValue))")
                XCTAssertEqual(hue(of: number), expected, accuracy: 0.01,
                               "at \(percent)% the number is not the ramp's colour (\(name.rawValue))")
                XCTAssertGreaterThan(saturation(of: frame), 0.5,
                                     "at \(percent)% the frame came out all but grey: \(frame)")
                frames.append(hue(of: frame))
                numbers.append(hue(of: number))
            }
            // Three samples from the green anchor up: 100, 115, 130 — and the
            // flat end at 150. Falling, and not one fixed red the moment the
            // boundary is crossed.
            for warned in [frames, numbers] {
                // The count is asserted before anything is indexed. The samples are `rampSamples`
                // filtered by the anchor, so moving the anchor changes their number, and indexing
                // straight would crash the process with `Index out of range` instead of failing.
                guard warned.count == 4 else {
                    XCTFail("""
                        the ramp above the anchor is \(warned.count) samples and this reads four: \
                        the anchor moved, and nothing here can say what the warning does between \
                        samples that are no longer there — \(warned)
                        """)
                    continue
                }
                XCTAssertGreaterThan(warned[0] - warned[1], 0.03,
                                     "the warning does not move between capacity and 115%: \(warned)")
                XCTAssertGreaterThan(warned[1] - warned[2], 0.03,
                                     "the warning does not move between 115% and 130%: \(warned)")
                XCTAssertEqual(warned[2], warned[3], accuracy: 0.005,
                               "past 130% the warning is still moving: \(warned)")
            }
        }
    }

    /// The hue and the saturation of a mean colour read off a rendering.
    ///
    /// Worked out from the three channels rather than through `NSColor`, because
    /// what came back is a mean of pixels and not a colour anybody named.
    private func hue(of colour: (red: Double, green: Double, blue: Double)) -> Double {
        let high = max(colour.red, colour.green, colour.blue)
        let low = min(colour.red, colour.green, colour.blue)
        guard high > low else { return 0 }
        let delta = high - low
        var hue = 0.0
        if high == colour.red { hue = (colour.green - colour.blue) / delta }
        else if high == colour.green { hue = 2 + (colour.blue - colour.red) / delta }
        else { hue = 4 + (colour.red - colour.green) / delta }
        hue = (hue / 6).truncatingRemainder(dividingBy: 1)
        return hue < 0 ? hue + 1 : hue
    }

    private func saturation(of colour: (red: Double, green: Double, blue: Double)) -> Double {
        let high = max(colour.red, colour.green, colour.blue)
        guard high > 0 else { return 0 }
        return (high - min(colour.red, colour.green, colour.blue)) / high
    }

    /// The hue a `Color` the rule handed out resolves to.
    private func hue(of colour: Color) -> Double {
        guard let srgb = NSColor(colour).usingColorSpace(.sRGB) else { return -1 }
        return hue(of: (srgb.redComponent, srgb.greenComponent, srgb.blueComponent))
    }

    /// Past the refill rate the warning is on the frame and the number, not the fill
    /// alone: anything the boundary fires on has a full capsule, so the frame and the
    /// number are what separate 105% from 900%.
    /// Asked of the frame's band and the number's rows separately: over the whole
    /// picture a red number would pass with a colourless frame, and the reverse.
    func testOverCapacityIsLoudOnTheFrameAndTheNumberToo() throws {
        let alarming = try render(ratio(300))
        let frame = try XCTUnwrap(alarming.chromaticMean(in: Self.frameBand), """
            past the refill rate the bar's frame drew nothing in a colour of its own, so the \
            warning is carried by the fill and by nothing else (§4)
            """)
        XCTAssertGreaterThan(frame.red, frame.green + 0.2,
                             "the frame at 300% of capacity is not red: \(frame)")
        let number = try XCTUnwrap(alarming.chromaticMean(in: MenuBarIcon.numberRows),
                                   "the number at 300% of capacity was drawn in ink")
        XCTAssertGreaterThan(number.red, number.green + 0.2,
                             "the number at 300% of capacity is not red: \(number)")

        // Below capacity both are ink and nothing else: the loud state has to be
        // the one that means something, and it has to be loud in both places or
        // the assertions above stop being two. The fill is coloured here — it
        // carries the whole ramp and always has — so the fixture asks the frame's
        // own rows and the number's, which is what the boundary is about.
        let quiet = try render(ratio(30))
        XCTAssertNil(quiet.chromaticMean(in: Self.frameBand),
                     "a fleet well inside its capacity coloured the frame anyway")
        XCTAssertNil(quiet.chromaticMean(in: MenuBarIcon.numberRows),
                     "a fleet well inside its capacity coloured the number anyway")
        XCTAssertNotNil(quiet.chromaticMean(in: Self.barBand),
                        "the fixture has no fill at all, so the two nils above prove nothing")
    }

    /// A band of the picture as it lands on the plate underneath: the most fully covered
    /// pixels, composited over that plate, and their contrast against it.
    /// The most covered pixels rather than a fixed alpha, because the calm frame is drawn
    /// at 0.55 of `labelColor`'s 0.847 and the warning at full strength; a stroke's
    /// interior is where its alpha peaks. Compositing matters because the picture is
    /// drawn on transparency over the menu bar.
    private func onPlate(_ picture: Rendered, in band: ClosedRange<CGFloat>,
                         on plate: UsagePopoverView.RampBackground,
                         colouredOnly: Bool = false)
        -> (red: Double, green: Double, blue: Double, contrast: Double)? {
        var dots = picture.rows(in: band)
        if colouredOnly {
            dots = dots.filter { dot in
                let high = max(dot.red, dot.green, dot.blue)
                let low = min(dot.red, dot.green, dot.blue)
                return high > 0 && (high - low) / high > 0.3
            }
        }
        guard let peak = dots.map(\.alpha).max() else { return nil }
        let solid = dots.filter { $0.alpha >= peak - 0.02 }
        guard !solid.isEmpty else { return nil }
        let count = Double(solid.count)
        let mixed = (red: solid.reduce(0.0) { $0 + $1.red * $1.alpha + plate.grey * (1 - $1.alpha) }
                        / count,
                     green: solid.reduce(0.0) { $0 + $1.green * $1.alpha + plate.grey * (1 - $1.alpha) }
                        / count,
                     blue: solid.reduce(0.0) { $0 + $1.blue * $1.alpha + plate.grey * (1 - $1.alpha) }
                        / count)
        return (mixed.red, mixed.green, mixed.blue, wcagContrast(mixed, against: plate.grey))
    }

    /// The legibility of the status item, measured off the drawing on both plates at
    /// nine loads. A warning may never be less legible than the calm state it replaces.
    ///
    /// Three things are asked on both plates, each able to fail on its own:
    ///
    /// 1. Every mark the ramp paints (fill, frame, number) clears `contrastFloor(on:)`
    ///    for its plate, measured on the rendering, since the frame's own opacity is
    ///    part of the answer and the rule knows nothing about it.
    /// 2. The warning frame is at least as legible as the calm frame. By construction:
    ///    the floor is the calm frame's own contrast where that is larger (calm frame
    ///    4.41 against a floor of 4.50 on light, 4.67 against 4.69 on dark). On the dark
    ///    plate the hot end is the equality case (`contrastFloor(.dark)` is the analytic
    ///    calm frame, 4.6924); the rendering keeps it off the knife edge, because the
    ///    calm stroke at `calmFrameOpacity` loses more to partial coverage. Making both
    ///    strokes equally opaque would leave the comparison resting on rounding.
    /// 3. Every warning mark is chromatic, so a floor met by driving the ramp to black
    ///    or white fails.
    ///
    /// The same ordering is not asserted for the number: the calm number is full-strength
    /// ink (11.61 on light, 8.57 on dark) and no colour that keeps a hue reaches either.
    /// On a dark plate legibility is not monotone across the warning band (5.36 at 100%,
    /// 8.19 at 115%, 4.69 from 130%): a lit yellow is brighter than a red can be. On the
    /// light plate the whole ramp is pinned at the floor.
    func testTheWarningIsNeverQuieterThanTheCalmStateItReplaces() throws {
        var table = ["", "plate  load  mark    rgb as drawn            contrast"]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let plate = MenuBarIcon.background(for: appearance)
            let short = plate == .light ? "light" : "dark "

            // The calm state the warning replaces: a thousandth under capacity,
            // where the frame and the number are still ink. The frame is read off
            // its own rows, which the fill cannot reach — at this figure the fill
            // is a hair short of full and a reading over the whole band would be
            // the fill's.
            let calm = try render(ratio(UsagePopoverView.greenRatioPercent - 0.001),
                                  appearance: appearance)
            let calmFrame = try XCTUnwrap(onPlate(calm, in: Self.frameBand, on: plate))
            let calmNumber = try XCTUnwrap(onPlate(calm, in: MenuBarIcon.numberRows, on: plate))
            table.append(String(format: "%@  99.9  frame   %.3f %.3f %.3f (ink)  %6.2f",
                                short, calmFrame.red, calmFrame.green, calmFrame.blue,
                                calmFrame.contrast))
            table.append(String(format: "%@  99.9  number  %.3f %.3f %.3f (ink)  %6.2f",
                                short, calmNumber.red, calmNumber.green, calmNumber.blue,
                                calmNumber.contrast))

            for percent in legibilityLoadSamples {
                // One rendering per load now, and the marks are told apart by
                // where they are: the fill inside its own bounds, the frame in
                // the rows above them. Two were needed while the fill's length
                // was a second quantity that could be set to zero to get it out
                // of the way; a picture drawn from one reading has no such knob.
                let drawn = try render(ratio(percent), appearance: appearance)
                let fill = try XCTUnwrap(onPlate(drawn, in: Self.fillBand, on: plate,
                                                 colouredOnly: true),
                                         "at \(percent)% on \(short) the fill has no colour at all")
                var marks = [("fill  ", fill)]
                if percent >= UsagePopoverView.greenRatioPercent {
                    marks.append(("frame ", try XCTUnwrap(onPlate(drawn, in: Self.frameBand, on: plate,
                                                                  colouredOnly: true))))
                    marks.append(("number", try XCTUnwrap(onPlate(drawn, in: MenuBarIcon.numberRows,
                                                                  on: plate, colouredOnly: true))))
                }
                for (label, mark) in marks {
                    table.append(String(format: "%@ %5.0f  %@  %.3f %.3f %.3f        %6.2f",
                                        short, percent, label, mark.red, mark.green, mark.blue,
                                        mark.contrast))
                    // A tenth of a ratio of slack, and it is the glyph rather
                    // than the rule: even the most fully covered pixel of a
                    // 9 pt digit is not quite opaque, so the number measures
                    // 4.41 to 4.45 where its colour is 4.50. The frame and the
                    // fill land within 0.01 of the rule, which is what says the
                    // slack belongs to the text.
                    XCTAssertGreaterThanOrEqual(mark.contrast,
                                                UsagePopoverView.contrastFloor(on: plate) - 0.1,
                                                "at \(percent)% the \(label.trimmingCharacters(in: .whitespaces)) "
                                                + "is \(mark.contrast) to 1 on the \(short) menu "
                                                + "bar, under the floor "
                                                + "\(UsagePopoverView.contrastFloor(on: plate))")
                    // Colour, not merely contrast: a floor met by driving the ramp
                    // to black — or, on a dark plate, to white — would be ink with
                    // extra steps.
                    let high = max(mark.red, mark.green, mark.blue)
                    let low = min(mark.red, mark.green, mark.blue)
                    XCTAssertGreaterThan((high - low) / high, 0.3,
                                         "at \(percent)% on \(short) the \(label) came out grey: "
                                         + "\(mark.red) \(mark.green) \(mark.blue)")
                }
                if percent >= UsagePopoverView.greenRatioPercent {
                    XCTAssertGreaterThanOrEqual(marks[1].1.contrast, calmFrame.contrast,
                                                "at \(percent)% on \(short) the warning frame "
                                                + "(\(marks[1].1.contrast)) is quieter than the calm "
                                                + "frame it replaces (\(calmFrame.contrast))")
                }
            }
        }
        print(table.joined(separator: "\n"))
    }

    /// A fill too narrow to see is not drawn, and the reading still reaches the reader
    /// because it is printed under the bar. The threshold (`MenuBarIcon.fillWidth`
    /// against `minimumVisibleFillWidth`) decides only whether a sliver goes on screen;
    /// the description names the figure at every one of these widths.
    func testAFillTooNarrowToSeeIsNotDrawnAtAll() throws {
        for percent in [0.0, 1, 2, 3, 4, 5] {
            let figure = ratio(percent)
            let drawn = try render(figure).chromaticMean(in: Self.fillBand) != nil
            XCTAssertEqual(MenuBarIcon.fillWidth(for: figure) >= MenuBarIcon.minimumVisibleFillWidth,
                           drawn, """
                at \(percent)% the picture \(drawn ? "drew" : "drew no") fill while the threshold \
                said otherwise — fill \(MenuBarIcon.fillWidth(for: figure)) pt
                """)
            XCTAssertTrue(MenuBarIcon.describe(figure).contains(UsagePopoverView.ratioCaption),
                          "at \(percent)% the description dropped a reading the number carries")
            XCTAssertFalse(try render(figure).rows(in: MenuBarIcon.numberRows).isEmpty,
                           "at \(percent)% the number is not on screen either")
        }
        // The fixture is one where the threshold decides: the smallest figures
        // are below it and the largest of the six is above, so the loop is not
        // green by being all one answer.
        XCTAssertLessThan(MenuBarIcon.fillWidth(for: ratio(1)), MenuBarIcon.minimumVisibleFillWidth)
        XCTAssertGreaterThanOrEqual(MenuBarIcon.fillWidth(for: ratio(5)),
                                    MenuBarIcon.minimumVisibleFillWidth)
    }

    /// The picture is resolved against the status item button's appearance, and the
    /// application's only while there is no button. They differ: the menu bar follows
    /// the wallpaper, not the system theme (`NSApp.effectiveAppearance` can be
    /// `DarkAqua` while the button is `VibrantDark`). Drawn against the app's, the ink
    /// could be black on a dark menu bar.
    /// Held through the drawing, as the luminance test next door is. The real divergence
    /// needs a light theme under a dark desktop picture, so a view with its own
    /// appearance stands in for the button.
    func testThePictureTakesItsAppearanceFromTheButtonWhenThereIsOne() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let button = NSButton()
        button.appearance = NSAppearance(named: .darkAqua)

        let chosen = MenuBarIcon.appearance(ofButton: button, system: light)
        XCTAssertEqual(chosen.name, .darkAqua,
                       "the picture followed the system theme past a button that has its own")
        let dark = try XCTUnwrap(try render(ratio(42), appearance: chosen).luminance(in: MenuBarIcon.numberRows))
        XCTAssertGreaterThan(dark, 0.7,
                             "drawn against the button's dark appearance the number is not light "
                             + "ink (luminance \(dark))")

        // No button, no picture of its own to resolve: the application's
        // appearance is all there is, and it is what the drawing gets.
        XCTAssertEqual(MenuBarIcon.appearance(ofButton: nil, system: light).name, .aqua)
        let ink = try XCTUnwrap(try render(ratio(42), appearance: MenuBarIcon.appearance(ofButton: nil,
                                                                                        system: light))
            .luminance(in: MenuBarIcon.numberRows))
        XCTAssertLessThan(ink, 0.3, "the fallback did not draw against the appearance given")
    }

    /// The colour is the popover's, not a second copy of it. Two surfaces
    /// deciding separately what green is would drift the day one of them was
    /// tuned, and §4 is emphatic that the pair say one thing.
    ///
    /// Asked on both plates, because the plate is now an argument and "one rule"
    /// has to mean the whole rule: a menu bar that read the ramp and then applied
    /// a floor of its own would pass this on one plate and fail on the other.
    func testTheBarsFillIsTheColourThePopoverWouldUse() throws {
        for plate in [UsagePopoverView.RampBackground.light, .dark] {
            for percent in [0.0, 99.0, UsagePopoverView.greenRatioPercent, 300.0] {
                let figure = ratio(percent)
                XCTAssertEqual(MenuBarIcon.fillColor(for: figure, on: plate),
                               NSColor(UsagePopoverView.ratioColor(atPercent: figure.percent, on: plate)),
                               "the menu bar and the popover disagree about \(percent)% on \(plate)")
            }
        }
    }

    /// Everything that is not the fill must resolve against the menu bar it is drawn on,
    /// or it disappears when the bar goes dark; the picture is not a template, so this
    /// file checks it. Measured as luminance: `NSColor.black` fails and `labelColor`
    /// passes. The number and the frame are asked separately: the number's colour is
    /// baked into attributed strings laid out once at type initialisation, the frame's
    /// is built inside the drawing block.
    func testTheNumberAndTheFrameFollowTheAppearanceTheyAreDrawnAgainst() throws {
        let dark = NSAppearance(named: .darkAqua)

        let lightNumber = try XCTUnwrap(try render(ratio(42)).luminance(in: MenuBarIcon.numberRows))
        let darkNumber = try XCTUnwrap(try render(ratio(42), appearance: dark)
            .luminance(in: MenuBarIcon.numberRows))
        XCTAssertLessThan(lightNumber, 0.3,
                          "the number is not dark ink on a light menu bar (luminance \(lightNumber))")
        XCTAssertGreaterThan(darkNumber, 0.7, """
            the number stayed dark on a dark menu bar (luminance \(darkNumber)): laid-out \
            attributed strings resolved their colour once instead of at drawing time
            """)

        // The frame on its own, with no reading — then there is no fill inside it
        // and the bar's band is the frame and nothing else. (`frameBand` would do
        // as well; the bar band says more here, because with no reading the whole
        // of it has to be ink.)
        let lightFrame = try XCTUnwrap(try render(nil).luminance(in: Self.barBand))
        let darkFrame = try XCTUnwrap(try render(nil, appearance: dark).luminance(in: Self.barBand))
        XCTAssertLessThan(lightFrame, 0.3,
                          "the bar's frame is not ink on a light menu bar (luminance \(lightFrame))")
        XCTAssertGreaterThan(darkFrame, 0.7, """
            the bar's frame stayed dark on a dark menu bar (luminance \(darkFrame)): \
            `withAlphaComponent` flattened a dynamic colour into a fixed one
            """)
    }

    /// What the picture says for a reader who cannot see it. It carries two things the
    /// drawing cannot, both because a description has no width: the `≥` of a ratio that
    /// is only a floor, and a figure the column would have capped.
    func testTheDescriptionCarriesTheRatioAndNamesItRight() {
        XCTAssertEqual(MenuBarIcon.describe(nil), "Weekly burn: no data")
        XCTAssertEqual(MenuBarIcon.describe(ratio(126)), "126% of the weekly refill rate")
        XCTAssertEqual(MenuBarIcon.describe(ratio(126, lowerBound: true)),
                       "≥126% of the weekly refill rate",
                       "a floor was read out as if it were the figure")
        XCTAssertFalse(MenuBarIcon.describe(ratio(126)).contains("quota"),
                       "the description still calls the ratio a quota")
        XCTAssertEqual(MenuBarIcon.describe(ratio(126)),
                       UsagePopoverView.ratioLabel(for: ratio(126)) + " "
                       + UsagePopoverView.ratioCaption, """
            the two surfaces name the same figure differently, so the reader who hears it and \
            the reader who sees it are told about two quantities
            """)
        // Where the drawing caps, this does not.
        XCTAssertEqual(MenuBarIcon.label(for: ratio(1240)).string, "999%")
        XCTAssertEqual(MenuBarIcon.describe(ratio(1240)), "1240% of the weekly refill rate")
    }

    /// And it names the same reading the picture draws, at every figure either side of
    /// the colour boundary: whatever the picture prints, the description contains,
    /// capping aside.
    func testTheDescriptionAndThePictureNameOneNumber() throws {
        for percent in [0.0, 1, 60, 99.999, 100, 130, 300, 999] {
            let figure = ratio(percent)
            let printed = MenuBarIcon.label(for: figure).string
            XCTAssertTrue(MenuBarIcon.describe(figure).hasPrefix(printed),
                          "the picture prints \(printed) and the description says "
                          + MenuBarIcon.describe(figure))
            XCTAssertFalse(try render(figure).rows(in: MenuBarIcon.numberRows).isEmpty,
                           "at \(percent)% the description names a number the picture never drew")
        }
        // With no ratio neither says anything, which is the other half: a
        // description that named a figure over a dashed empty bar would be the
        // reverse of what describing a picture is for.
        XCTAssertEqual(MenuBarIcon.describe(nil), "Weekly burn: no data")
        XCTAssertTrue(try render(nil).rows(in: MenuBarIcon.numberRows).isEmpty)
    }

    /// What the owner of the picture redraws on, and what it refuses to draw at all.
    /// Both sides of the figure come from the same pass and series, so there is one
    /// number to watch, plus the `≥` beside it, which moves without the number and
    /// changes what the picture may claim.
    func testThePictureIsRedrawnWhenTheFigureMoves() throws {
        var snapshot = UsageSnapshot.empty
        snapshot.fleetBurn = UsagePopoverLabelTests.burn(126)
        // With its arrival, which is half of what the picture asks of a figure —
        // see `testAFigureNobodyHasConfirmedForTwoIntervalsIsNotDrawnOnEitherSurface`.
        snapshot.historiesFetchedAt = Date()
        let loaded = try XCTUnwrap(MenuBarIcon.ratio(for: snapshot))
        XCTAssertEqual(loaded.percent, 126)

        var faster = snapshot
        faster.fleetBurn = UsagePopoverLabelTests.burn(200)
        XCTAssertNotEqual(MenuBarIcon.ratio(for: faster), loaded)
        var floored = snapshot
        floored.fleetBurn = UsagePopoverLabelTests.burn(126, lowerBound: true)
        XCTAssertNotEqual(MenuBarIcon.ratio(for: floored), loaded, """
            the same number over a blocked fleet is the same picture, so a fleet whose figure \
            became a floor keeps a status item that states it exactly
            """)

        // And the live token rate is not in it at all any more, which is the
        // other half of the same change: it is a supporting reading on the
        // popover and colours nothing.
        var spending = snapshot
        spending.fleetTokenRate = 20_000_000
        XCTAssertEqual(MenuBarIcon.ratio(for: spending), loaded,
                       "the five-minute token rate moved the menu bar's picture again")

        // Its own half's failure takes the whole picture away, while the other
        // halves' do not: the refusals are the endpoints', one each.
        snapshot.sessionsFailure = "/gw/sessions: unreachable"
        XCTAssertEqual(MenuBarIcon.ratio(for: snapshot)?.percent, 126,
                       "the sessions endpoint knows nothing about the histories")
        snapshot.historiesFailure = "/gw/usage/<label>/history: unreachable"
        XCTAssertNil(MenuBarIcon.ratio(for: snapshot),
                     "a reading outlived the figures behind it, with no room up here to say so")
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

    /// The fourth state is about what is one instruction away from the screen. Putting
    /// the status menu up begins by closing the popover, and that close hands the
    /// keyboard back: with the menu asked for but not yet tracked, the hide would cancel
    /// a tracking that had not started and collapse the menu under the pointer. Line
    /// order is no defence; it holds only while AppKit delivers the close synchronously.
    func testAMenuOnItsWayUpCountsAsAMenuAlreadyUp() {
        XCTAssertFalse(PanelController.canHideApp(modal: false, menuTrackingDepth: 0,
                                                  menuOpening: true, popoverOpen: false))
        // And it is the flag alone that says so: nothing else about that instant
        // is different from the safe state above.
        XCTAssertTrue(PanelController.canHideApp(modal: false, menuTrackingDepth: 0,
                                                 menuOpening: false, popoverOpen: false))
    }

    /// The rule above is a pure function; this holds the pair of calls that sets and
    /// clears the flag. The clearing half is the dangerous one: the tracking count is
    /// reconciled before every retry and the modal re-asked, but a flag left set answers
    /// "do not hide" for the rest of the run, so the keyboard is never handed back
    /// (§4's "typing into nowhere") and the retry timer wakes the process five times a
    /// second forever. No AppKit state is needed to test it.
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

    /// What the window measures is not the length of that press. On the measured path
    /// the dismissing press never reaches the action (see `toggleUsagePopover`), so its
    /// mark is spent by the next click: the window bounds the pause between two clicks,
    /// and its price is a deliberate second click swallowed. An ordinary double click on
    /// the status item is `down#1 → up#2`, 200–350 ms end to end.
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

    /// It also disarms: a close with no button down clears a mark an earlier press left.
    /// Unreachable in practice (reopening the popover is the click that spends the
    /// mark), but the type takes the state directly, so the `: nil` half is held by name
    /// like every other clause.
    func testACloseThatWasNotAPressClearsAMarkAlreadyArmed() {
        var dismissal = PopoverDismissal()
        dismissal.popoverClosed(at: closed, midPress: true)
        dismissal.popoverClosed(at: closed.addingTimeInterval(0.01), midPress: false)
        XCTAssertFalse(dismissal.shouldIgnoreClick(at: closed.addingTimeInterval(0.02)),
                       "a mark left by an earlier press outlived the close that should have cleared it")
    }

    /// The window is the backstop for a second half that never arrives, and both its
    /// sides are the constant's. A millisecond off each edge: a `Date` this far from its
    /// epoch resolves to a fraction of a microsecond, so two dates a nominal window apart
    /// differ by a hair less than it.
    func testBothSidesOfTheWindow() {
        let window = PopoverDismissal.suppressionWindow
        var inside = PopoverDismissal()
        inside.popoverClosed(at: closed, midPress: true)
        XCTAssertTrue(inside.shouldIgnoreClick(at: closed.addingTimeInterval(window - 0.001)))

        var outside = PopoverDismissal()
        outside.popoverClosed(at: closed, midPress: true)
        XCTAssertFalse(outside.shouldIgnoreClick(at: closed.addingTimeInterval(window + 0.001)))

        // The constant bounds the pause between two clicks, so its cost is a second click
        // swallowed; an ordinary double click on the icon has its ends 200–350 ms apart, so
        // the window must be narrower than that.
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

    /// The sequence that loses the popover's activation, and why the debt is one account
    /// rather than one flag per activator. Click the status item (the app activates for
    /// the popover), take the pointer to the left edge (the panel comes up), dismiss the
    /// popover with Esc. The popover's hand-back declines because the panel is on screen;
    /// the panel's hand-back must then cover the popover's activation too, or the app is
    /// left frontmost with no window (§4: typing goes nowhere).
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

/// The week's total: what it says, and what it says when it does not know. The
/// row's second number is the rate (`RowRateTests`, §2.9). The week is drawn in the
/// tooltip's `Over 7 days` summary and the spend column of `--dump`; this class
/// covers both plus the tooltip's hour-against-week arrangement. The row's layout is
/// `RowLayoutTests`.
@MainActor
final class RowSpendTests: XCTestCase {

    private func row(_ usage: TokenCounts?,
                     hourly: TokenCounts? = nil,
                     topic: String? = "тема") -> SwitcherRow {
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
                    usage: usage,
                    hourlyUsage: hourly)
    }

    /// The tooltip's week and the dump's week are the same figure, rounded the
    /// same way — one formatter, because two roundings would be two answers about
    /// one project's week on two surfaces read against each other.
    func testTheNumberIsTheOneTheDumpPrints() {
        let complete = TokenCounts(input: 1_000_000, output: 200_000,
                                   cacheCreation: 400_000, cacheRead: 9_000_000)
        XCTAssertEqual(SwitcherRowView.usageLabel(for: row(complete)), "3.40M")
        XCTAssertEqual(ConsoleDump.usageCell(for: row(complete)), "3.40M")
        XCTAssertEqual(SwitcherRowView.usageLabel(for: row(TokenCounts(input: 900, output: 0,
                                                                      cacheCreation: 0,
                                                                      cacheRead: 0))), "900")
    }

    /// A week with an unnamed counter behind it is a lower bound, and both places
    /// that print it have to say so — `≥` in the tooltip, `>=` in the dump's
    /// column, the same fact either way.
    func testALowerBoundWearsItsMark() {
        let partial = TokenCounts(input: 1_000_000, output: nil, cacheCreation: nil, cacheRead: nil)
        XCTAssertEqual(SwitcherRowView.usageLabel(for: row(partial)), "≥1.00M")
        XCTAssertTrue(ConsoleDump.usageCell(for: row(partial)).hasPrefix(">="))
        // And a complete one does not wear it.
        let complete = TokenCounts(input: 1_000_000, output: 0, cacheCreation: 0, cacheRead: 0)
        XCTAssertEqual(SwitcherRowView.usageLabel(for: row(complete)), "1.00M")
    }

    /// No week at all, and a week in which the gateway named nothing, both write
    /// nothing — no summary line in the tooltip and a dash in the dump. The second
    /// is the one worth a test: `weighted()` folds an unnamed counter in as zero,
    /// so such a week would otherwise be printed as a confident `0` where the
    /// honest answer is "no idea" (§2.4).
    func testNothingKnownDrawsNothingRatherThanAZero() {
        XCTAssertNil(SwitcherRowView.usageLabel(for: row(nil)))
        let blank = TokenCounts(input: nil, output: nil, cacheCreation: nil, cacheRead: nil)
        XCTAssertNil(SwitcherRowView.usageLabel(for: row(blank)))
        XCTAssertEqual(SwitcherRowView.usageLabel(for: row(.zero)), nil)
    }

    /// The figure the row prints is the hour's, so it is the hour that the
    /// tooltip breaks into the four counters the gateway named — the breakdown
    /// belongs to the number the reader is looking at. An unnamed counter is `?`,
    /// never 0.
    ///
    /// The week's figure is deliberately a *different* number from the hour's
    /// here: with the two equal, a breakdown taken from the wrong window would
    /// read correctly.
    func testTheTooltipBreaksTheHoursNumberIntoTheFourCounters() {
        let text = SwitcherRowView.tooltipText(for: row(TokenCounts(input: 7_000_000, output: 0,
                                                                    cacheCreation: 0, cacheRead: 0),
                                                        hourly: TokenCounts(input: 1_000_000,
                                                                            output: 200_000,
                                                                            cacheCreation: 400_000,
                                                                            cacheRead: 9_000_000)))
        XCTAssertTrue(text.contains("Tokens over the last hour (input-equivalent): 3.40M"), text)
        XCTAssertTrue(text.contains("• in 1.00M"), text)
        XCTAssertTrue(text.contains("• out 200k"), text)
        XCTAssertTrue(text.contains("• cache write 400k"), text)
        XCTAssertTrue(text.contains("• cache read 9.00M"), text)
        XCTAssertTrue(text.contains("Over 7 days: 7.00M"), text)

        let partial = SwitcherRowView.tooltipText(for: row(nil,
                                                           hourly: TokenCounts(input: 50, output: nil,
                                                                               cacheCreation: nil,
                                                                               cacheRead: 5_401_028)))
        XCTAssertTrue(partial.contains("• out ?"), partial)
        XCTAssertTrue(partial.contains("• cache write ?"), partial)
        XCTAssertTrue(partial.contains("Tokens over the last hour (input-equivalent): ≥540k"), partial)
    }

    /// A week with no hour under it (a project untouched in the last 3600 s) says the
    /// week and nothing else; the row's right-hand side is blank.
    /// The summary line wears `≥` on the same terms as the breakdown's total, asked here
    /// because every other fixture hands the week all four counters. The counters are
    /// billed at different rates, so a floor must not print as an exact figure.
    func testAWeekWithoutAnHourIsOneSummaryLineAndNoBreakdown() {
        let text = SwitcherRowView.tooltipText(for: row(TokenCounts(input: 1_000_000, output: 200_000,
                                                                    cacheCreation: 400_000,
                                                                    cacheRead: 9_000_000)))
        XCTAssertTrue(text.contains("Over 7 days: 3.40M"), text)
        XCTAssertFalse(text.contains("last hour"), text)
        XCTAssertFalse(text.contains("• in "), text)

        let floor = SwitcherRowView.tooltipText(for: row(TokenCounts(input: 1_000_000, output: nil,
                                                                     cacheCreation: nil,
                                                                     cacheRead: nil)))
        XCTAssertTrue(floor.contains("Over 7 days: ≥1.00M"), floor)
    }

    /// And the other way round, which is not a hypothetical: the two
    /// `/gw/sessions` calls fail apart, so a week that timed out leaves the hour's
    /// figures standing on their own (§2.9). The gateway's 200-consumer cap would
    /// do the same to a project spending right now after a quiet week, and is not
    /// firing today. The breakdown stands on its own either way, with no
    /// `Over 7 days` line under it.
    func testAnHourWithoutAWeekIsTheBreakdownAlone() {
        let text = SwitcherRowView.tooltipText(for: row(nil, hourly: TokenCounts(input: 1_000_000,
                                                                                 output: 200_000,
                                                                                 cacheCreation: 400_000,
                                                                                 cacheRead: 9_000_000)))
        XCTAssertTrue(text.contains("Tokens over the last hour (input-equivalent): 3.40M"), text)
        XCTAssertTrue(text.contains("• cache read 9.00M"), text)
        XCTAssertFalse(text.contains("Over 7 days"), text)
    }

    /// And a row with neither says nothing about spend, rather than saying zero —
    /// no blank line either, so its tooltip is exactly what it was before.
    func testTheTooltipSaysNothingWhenThereIsNothingToSay() {
        XCTAssertEqual(SwitcherRowView.usageLines(for: row(nil)), [])
        XCTAssertFalse(SwitcherRowView.tooltipText(for: row(nil)).contains("Tokens"))
        let blank = TokenCounts(input: nil, output: nil, cacheCreation: nil, cacheRead: nil)
        XCTAssertEqual(SwitcherRowView.usageLines(for: row(blank, hourly: blank)), [])
        XCTAssertFalse(SwitcherRowView.tooltipText(for: row(blank, hourly: blank)).contains("Tokens"))
    }

    /// The two spend columns of `--dump`'s `Projects` table, held to the widest cell
    /// each claims to fit. Both in one test because the widths are one decision: four
    /// digits of millions with a lower bound's `>=`, the rate's two extra characters
    /// buying `/h` (`ConsoleDump.spendColumnWidth` carries the reasoning).
    /// The second half checks that one digit more does not fit: `column` pads rather than
    /// cuts, so without it the first half passes for any width at or above the cell.
    func testTheSpendColumnsAreAsWideAsTheWidestCellTheyClaimToFit() {
        let ceiling = TokenCounts(input: 9_999_990_000, output: nil,
                                  cacheCreation: nil, cacheRead: nil)
        XCTAssertEqual(ConsoleDump.usageCell(for: row(ceiling)), ">=9999.99M")
        XCTAssertEqual(ConsoleDump.usageCell(for: row(ceiling)).count,
                       ConsoleDump.spendColumnWidth)
        XCTAssertEqual(ConsoleDump.rateCell(for: row(nil, hourly: ceiling)), ">=9999.99M/h")
        XCTAssertEqual(ConsoleDump.rateCell(for: row(nil, hourly: ceiling)).count,
                       ConsoleDump.rateColumnWidth)

        let over = TokenCounts(input: 12_345_670_000, output: nil,
                               cacheCreation: nil, cacheRead: nil)
        XCTAssertEqual(ConsoleDump.usageCell(for: row(over)), ">=12345.67M",
                       "no `B` step, so millions keep growing digits")
        XCTAssertGreaterThan(ConsoleDump.usageCell(for: row(over)).count,
                             ConsoleDump.spendColumnWidth)
        XCTAssertGreaterThan(ConsoleDump.rateCell(for: row(nil, hourly: over)).count,
                             ConsoleDump.rateColumnWidth)
    }

    /// The table is held to those widths: two rows whose spend cells differ in width put
    /// everything after the column at the same offset (a column that gives way takes
    /// the rest of the line with it). The second half stops a wider literal from
    /// passing: a cell one character over shifts the rest by exactly one.
    ///
    /// Only the two spend columns: offsets are compared against a row whose spend cells
    /// are both `-`, so a uniformly wider column elsewhere moves the baseline too. The
    /// name cell is held to 34 by `testTheDumpCellKeepsTheCountWholeInsideItsColumn`.
    /// The CPU cell is held by nothing: `cpuLabel` writes `"≥" + "%.0f%%"`, so `≥1000%`
    /// is six characters in a column declared 5 (it takes ten cores on one session).
    func testTheSpendColumnsHoldTheTableToTheWidthTheyDeclare() throws {
        // Everything after both spend columns. `row` carries no project, so the
        // activity cell is the same fixed sentence on every line here, which is
        // what makes it a landmark rather than a second variable.
        let tail = "outside the scan roots"
        func offsetOfTail(week: TokenCounts?, hour: TokenCounts?) throws -> Int {
            let line = ConsoleDump.projectRow(for: row(week, hourly: hour), config: .default)
            let found = try XCTUnwrap(line.range(of: tail), line)
            return line.distance(from: line.startIndex, to: found.lowerBound)
        }

        let ceiling = TokenCounts(input: 9_999_990_000, output: nil,
                                  cacheCreation: nil, cacheRead: nil)
        let over = TokenCounts(input: 12_345_670_000, output: nil,
                               cacheCreation: nil, cacheRead: nil)
        // A row with neither figure: both cells are a bare `-`, the narrowest
        // either column ever holds.
        let dashes = try offsetOfTail(week: nil, hour: nil)

        XCTAssertEqual(try offsetOfTail(week: ceiling, hour: nil), dashes,
                       "the spend column does not hold \(ConsoleDump.spendColumnWidth) characters:"
                           + " the widest cell it claims to fit moves the rest of the row")
        XCTAssertEqual(try offsetOfTail(week: nil, hour: ceiling), dashes,
                       "the rate column does not hold \(ConsoleDump.rateColumnWidth) characters:"
                           + " the widest cell it claims to fit moves the rest of the row")

        XCTAssertEqual(try offsetOfTail(week: over, hour: nil), dashes + 1,
                       "the spend column is wider than \(ConsoleDump.spendColumnWidth):"
                           + " a cell one character over it did not move the rest of the row")
        XCTAssertEqual(try offsetOfTail(week: nil, hour: over), dashes + 1,
                       "the rate column is wider than \(ConsoleDump.rateColumnWidth):"
                           + " a cell one character over it did not move the rest of the row")
    }

    /// The path stays the last line of a project row (§4) — the counters go in
    /// front of it, not after.
    func testThePathIsStillTheLastLine() {
        var built = row(TokenCounts(input: 10, output: 10, cacheCreation: 10, cacheRead: 10),
                        hourly: TokenCounts(input: 1, output: 1, cacheCreation: 1, cacheRead: 1))
        built.project = TestFixtures.project(path: "/tmp/home-network", rootName: "home-network")
        let lines = SwitcherRowView.tooltipText(for: built).split(separator: "\n")
        XCTAssertEqual(lines.last, "/tmp/home-network")
    }
}

/// The rate on the row's second line: `12.40M/h`, and what it says when it does
/// not know. The layout of it is `RowLayoutTests`; this is the text.
///
/// Sibling of `RowSpendTests` rather than an edit of it: the week's label is still
/// drawn, in the tooltip and in `--dump`, and the two labels have to be asked
/// separately or a row wired to the wrong window answers both.
@MainActor
final class RowRateTests: XCTestCase {

    private func row(hourly: TokenCounts?, week: TokenCounts? = nil) -> SwitcherRow {
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
                    chatTopic: "тема",
                    model: nil,
                    contextUsedTokens: nil,
                    contextLimitTokens: nil,
                    lastActivity: nil,
                    usage: week,
                    hourlyUsage: hourly)
    }

    /// The figure carries its unit. Without the `/h` the second line would print a
    /// total and a rate identically, and the two differ by a factor of the week.
    func testTheRateSaysItIsPerHour() {
        let spent = TokenCounts(input: 4_000_000, output: 1_000_000,
                                cacheCreation: 800_000, cacheRead: 24_000_000)
        XCTAssertEqual(SwitcherRowView.rateLabel(for: row(hourly: spent)), "12.40M/h")
        XCTAssertEqual(ConsoleDump.rateCell(for: row(hourly: spent)), "12.40M/h")
        // The same rounding ladder the total uses, unit and all.
        XCTAssertEqual(SwitcherRowView.rateLabel(for: row(hourly: TokenCounts(input: 12_000, output: 0,
                                                                              cacheCreation: 0,
                                                                              cacheRead: 0))),
                       "12k/h")
        XCTAssertEqual(SwitcherRowView.rateLabel(for: row(hourly: TokenCounts(input: 900, output: 0,
                                                                              cacheCreation: 0,
                                                                              cacheRead: 0))),
                       "900/h")
    }

    /// The wording is the only thing that names the window, so it is pinned to the
    /// constant here. Nothing divides anything (§2.9): the figure is what the gateway
    /// reported over `UsageStore.hourWindowSeconds`, and `/h` is the whole arithmetic.
    /// `testTheHourlyFigureIsAskedOverExactlyOneSlidingHour` holds the request; this
    /// ties the value to the wording, so moving the constant names the strings to move.
    /// Three of the four labels are asserted below. The fourth, `usage 1h:` inside the
    /// private `ConsoleDump.printText`, is named in the message instead.
    func testTheLabelsNameTheWindowTheFigureIsMeasuredOver() {
        XCTAssertEqual(UsageStore.hourWindowSeconds, 3600, """
            the window stopped being an hour and four labels still say it is: "/h" in \
            SwitcherRowView.rateLabel, "Tokens over the last hour" in \
            SwitcherRowView.usageLines, "/h" in ConsoleDump.rateCell and "usage 1h:" in \
            ConsoleDump.printText. Nothing divides, so moving this constant relabels \
            every one of them instead of rescaling anything (§2.9)
            """)
        let built = row(hourly: TokenCounts(input: 1_000_000, output: 0,
                                            cacheCreation: 0, cacheRead: 0))
        XCTAssertEqual(SwitcherRowView.rateLabel(for: built)?.hasSuffix("/h"), true)
        XCTAssertEqual(ConsoleDump.rateCell(for: built).hasSuffix("/h"), true)
        XCTAssertTrue(SwitcherRowView.tooltipText(for: built).contains("over the last hour"),
                      SwitcherRowView.tooltipText(for: built))
    }

    /// The rate is the *hour's* figure and not the week's. Asked with both
    /// present and different, because with one of them missing a row wired to
    /// either window still answers something.
    func testTheRateIsTheHoursFigureAndTheTotalIsTheWeeks() {
        let built = row(hourly: TokenCounts(input: 1_000, output: 0, cacheCreation: 0, cacheRead: 0),
                        week: TokenCounts(input: 5_000_000, output: 0, cacheCreation: 0, cacheRead: 0))
        XCTAssertEqual(SwitcherRowView.rateLabel(for: built), "1k/h")
        XCTAssertEqual(SwitcherRowView.usageLabel(for: built), "5.00M",
                       "the week's label did not follow the row's line to the hour")
    }

    /// An unnamed counter makes the rate a floor, and it says so — `≥` on the
    /// panel, `>=` in the dump, the same fact either way.
    func testARateThatIsOnlyAFloorWearsItsMark() {
        let partial = TokenCounts(input: 1_000_000, output: nil, cacheCreation: nil, cacheRead: nil)
        XCTAssertEqual(SwitcherRowView.rateLabel(for: row(hourly: partial)), "≥1.00M/h")
        XCTAssertEqual(ConsoleDump.rateCell(for: row(hourly: partial)), ">=1.00M/h")
        let complete = TokenCounts(input: 1_000_000, output: 0, cacheCreation: 0, cacheRead: 0)
        XCTAssertEqual(SwitcherRowView.rateLabel(for: row(hourly: complete)), "1.00M/h",
                       "a complete figure does not wear the mark")
    }

    /// No figure at all, and a figure in which the gateway named nothing, both
    /// draw nothing. The second is the one worth a test: `weighted()` folds an
    /// unnamed counter in as zero, so such a row would otherwise show a confident
    /// `0/h` — a project reading as idle because nothing was reported about it.
    func testNothingKnownDrawsNoRateRatherThanAZeroPerHour() {
        XCTAssertNil(SwitcherRowView.rateLabel(for: row(hourly: nil)))
        let blank = TokenCounts(input: nil, output: nil, cacheCreation: nil, cacheRead: nil)
        XCTAssertNil(SwitcherRowView.rateLabel(for: row(hourly: blank)))
        XCTAssertNil(SwitcherRowView.rateLabel(for: row(hourly: .zero)))
        XCTAssertEqual(ConsoleDump.rateCell(for: row(hourly: blank)), "-")
        // And a measured zero is a reading, which stays one.
        XCTAssertEqual(SwitcherRowView.rateLabel(for: row(hourly: TokenCounts(input: 0, output: 0,
                                                                              cacheCreation: 0,
                                                                              cacheRead: 0))),
                       "0/h")
    }
}

/// A rotation that draws nothing and warns about nothing: one account no row here is
/// about, which the gateway can still route to. Naming nobody the popover draws
/// keeps every checkbox inert and every switched-off note unwritten. Naming somebody
/// eligible keeps the orange line off: `{"accounts": []}` would be zero routable
/// accounts and put a warning under every picture, and a failing request would write
/// a line of blame instead.
private let quietRotation = """
{"accounts": [{"label": "elsewhere", "eligible": true, "disabled": false, \
"disabled_until": null, "disabled_reason": ""}]}
"""

/// A gateway that answers each account it knows with one flat line at the level it
/// is handed, ten samples a minute apart. Flat, so where ink lands is a fact about
/// the chart. Shared by `UsageHistoryTests` (weighs the plot's ink) and
/// `UsagePopoverPaintTests` (reads its colour).
///
/// `silentOnUnknown`: off, an unnamed account answers a flat zero; on, its request
/// fails, which is how an account is named by the quota poll and missing from the
/// chart.
///
/// `rotation` answers `/gw/status`, which the row's checkbox is drawn from; it
/// defaults to `quietRotation` (see there).
private func flatHistoryClient(readings: [String: Double],
                               silentOnUnknown: Bool = false,
                               rotation: String = quietRotation) -> UsageClient {
    UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
        let url = request.url ?? Config.default.resolvedUsageBaseURL
        if url.path == "/gw/status" {
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(rotation.utf8), response)
        }
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

    /// One suite for the whole class, wiped around every test. A suite name is a file in
    /// the user's preferences, so a fresh name per test would leave one behind per run.
    /// `removePersistentDomain` empties the domain but
    /// `~/Library/Preferences/<suite>.plist` stays as an empty 42-byte file; deleting it
    /// would write behind `cfprefsd`, which may write it out again.
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

    /// Answers every history request from the fixture, the rotation from its own, and
    /// counts them all. Two fixtures because `GatewayStatus` decodes `accounts` strictly
    /// (`UsageModel`) and the history body has no such key: served to `/gw/status` it
    /// would throw on every pass, leaving `rotationFailure` the only reachable outcome.
    private func client(_ counter: RequestCounter, gateway: Gateway = Gateway()) -> UsageClient {
        UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            counter.record(request.url)
            guard gateway.answers else { throw UsageError.unreachable("the gateway is not there") }
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            let body = url.path == "/gw/status" ? UsageFixtures.status : UsageFixtures.history
            return (Data(body.utf8), response)
        }
    }

    /// The requests of one pass that are histories — the rotation rides beside
    /// them and is counted separately wherever the count is the subject.
    private func histories(_ counter: RequestCounter) -> [URL] {
        counter.urls.filter { $0.path.hasSuffix("/history") }
    }

    private func model(_ counter: RequestCounter,
                       defaults: UserDefaults) -> UsageHistoryModel {
        UsageHistoryModel(client: client(counter), defaults: defaults)
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: Self.suiteName) ?? .standard
    }

    /// The reason this schedule is separate from `UsageStore`'s: a closed popover makes
    /// no request at all from anything the timer or the view model drives (`fetch`, a
    /// change of the account list, a change of period).
    ///
    /// `setAccount` is not swept on purpose: its only caller is the binding inside
    /// `rotationSwitch`, which exists only on an open popover, and it is the one request
    /// meant to outlive a close (`close` cancels `fetchTask` and leaves `switchTasks`,
    /// see `testASwitchAlreadySentOutlivesTheClose`).
    /// Poked after an open, so the accounts are in hand and the guard is the only thing
    /// stopping the requests.
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
        XCTAssertEqual(asked, 3, "two histories and the rotation: \(counter.urls)")

        history.close()
        history.fetch()
        history.update(labels: ["acc1", "acc2", "acc3"])
        history.period = .month
        await history.fetchTask?.value
        XCTAssertEqual(counter.urls.count, asked, "asked while closed: \(counter.urls)")
    }

    /// Opening asks once for each account, on the account's own endpoint, for
    /// the chosen window — and once for the rotation, which is the fleet's and
    /// therefore asked for once however many accounts there are.
    func testOpeningAsksOnceForEveryAccount() async {
        let counter = RequestCounter()
        let history = model(counter, defaults: freshDefaults())
        history.period = .hour
        history.open(labels: ["acc1", "acc2"])
        await history.fetchTask?.value
        defer { history.close() }

        XCTAssertEqual(Set(counter.urls.map(\.path)),
                       ["/gw/usage/acc1/history", "/gw/usage/acc2/history", "/gw/status"])
        XCTAssertEqual(histories(counter).count, 2)
        XCTAssertEqual(counter.urls.filter { $0.path == "/gw/status" }.count, 1)
        XCTAssertEqual(history.series.map(\.label), ["acc1", "acc2"])
        // The window asked for is the period, to the second. Off a history: the
        // rotation carries no window and is first in the air.
        let since = try? XCTUnwrap(histories(counter).first?.query?
            .split(separator: "=").last.flatMap { Double($0) })
        XCTAssertEqual(Date().timeIntervalSince1970 - (since ?? 0),
                       HistoryPeriod.hour.seconds, accuracy: 5)
    }

    /// The rotation is applied the moment `/gw/status` answers, with the histories still
    /// in the air, so the checkboxes do not jump once the popover is open. A bare
    /// `/gw/status` is much smaller and faster than a day pass (`fetch`'s docblock has
    /// the measurements).
    ///
    /// The histories are held open-ended and the status answers at once. The wait is
    /// timed, for `testLoadDoesNotNeedTheMainThread`'s reason: a rotation that waited for
    /// the histories would otherwise hang the run. The controls: `series` empty proves
    /// the gate held the histories, and reading them after the gate opens proves it was
    /// the only thing holding them.
    func testTheRotationIsDrawnBeforeTheHistoriesHaveLanded() async throws {
        let counter = RequestCounter()
        let histories = Gate()
        let history = UsageHistoryModel(client: rotationClient(counter, historyGate: histories),
                                        defaults: freshDefaults())
        history.open(labels: ["acc2", "acc3"])
        defer { history.close() }
        // The pass is genuinely in the air before anything is asked of it: `open`
        // starts a `Task` whose body has not run yet.
        await histories.arrival()

        var switches: [String: AccountSwitch]?
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            switches = history.switches
            if switches != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(switches, """
            the rotation waited for the histories: every box stands clear and disabled until \
            they answer, and then the list moves
            """)
        XCTAssertEqual(switches?["acc3"]?.disabled, true,
                       "the boxes were drawn off something other than this rotation")
        XCTAssertTrue(history.series.isEmpty,
                      "the histories answered after all, so nothing here was held apart")
        XCTAssertNil(history.fetchedAt, "the pass dated itself from its cheap half")

        histories.open()
        await history.fetchTask?.value
        XCTAssertEqual(history.series.map(\.label), ["acc2", "acc3"],
                       "the histories never landed at all, so the first half of this proves nothing")
        XCTAssertNotNil(history.fetchedAt, "the pass never dated itself")
    }

    /// A pass cancelled before its rotation landed applies neither half of itself.
    ///
    /// `fetch` guards both halves with the same check. The rotation half draws the
    /// checkboxes, so applying a cancelled one puts an old fleet under the pointer; the
    /// history half writes `seriesPeriod`, so applying it leaves a `1d` chart under the
    /// `7d` tab.
    ///
    /// A change of period sets this up: `period.didSet` calls `fetch`, which cancels the
    /// pass in flight before starting the next. `firstStatus` holds the first pass at a
    /// gate with its answer in hand, the second lands whole, then the gate opens and the
    /// cancelled one wakes with stale news; only the hop back to the main actor is
    /// left, which is where the cancelling `fetch` fits. Period rather than labels
    /// because the mark it leaves is one field: `apply` writes the period into
    /// `seriesPeriod` on any non-empty answer.
    ///
    /// The stale body says something different where the assertion looks (`acc2`
    /// switched off) and keeps the routable count at one, as `UsageFixtures.status`
    /// does, so the orange line is not part of the claim. The two assertions before the
    /// gate opens are the control.
    func testAPassCancelledBeforeItsRotationLandedAppliesNeitherHalf() async throws {
        let counter = RequestCounter()
        let held = Gate()
        // A fleet with `acc2` switched off, which is the only thing asserted about
        // this body. One routable account, as `UsageFixtures.status` has too, so
        // the orange line reads the same off either answer and is not a second
        // claim riding along.
        let stale = """
        {"accounts": [
           {"label": "acc2", "eligible": false,
            "disabled": true, "disabled_until": null, "disabled_reason": ""},
           {"label": "acc3", "eligible": false,
            "disabled": true, "disabled_until": 1788706735, "disabled_reason": ""},
           {"label": "main", "eligible": true,
            "disabled": false, "disabled_until": null, "disabled_reason": ""}
         ]}
        """
        let history = UsageHistoryModel(
            client: rotationClient(counter, firstStatus: (gate: held, body: stale)),
            defaults: freshDefaults())
        history.open(labels: ["acc2"])
        defer { history.close() }
        let cancelled = history.fetchTask
        // The first pass is genuinely at the gate before anything is asked of it.
        await held.arrival()

        XCTAssertEqual(history.period, .day, "the pass being cancelled asked for the wrong window")
        history.period = .week
        await history.fetchTask?.value
        XCTAssertEqual(history.switches?["acc2"]?.disabled, false,
                       "the second pass never drew the boxes, so there is nothing here to undo")
        XCTAssertEqual(history.seriesPeriod, .week,
                       "the second pass never drew its own lines, so the same")

        held.open()
        await cancelled?.value

        XCTAssertEqual(history.switches?["acc2"]?.disabled, false, """
            the cancelled pass put its own rotation on the boxes, and what it carries is the \
            fleet as it stood before the period was changed
            """)
        XCTAssertEqual(history.seriesPeriod, .week, """
            the cancelled pass applied its lines under the tab that is on screen: a 1d chart \
            labelled 7d
            """)
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

        XCTAssertEqual(histories(counter).count, 2, "changing the period did not refetch")
        XCTAssertEqual(UsageHistoryModel(client: UsageClient(baseURL: Config.default.resolvedUsageBaseURL),
                                         defaults: defaults).period,
                       .month,
                       "the period did not outlive the model")
    }

    /// The pass must not need the main thread, as with `UsageStore.poll` (§6):
    /// everything `load` touches is on a `@MainActor` class, so reading a `static let`
    /// that lost its `nonisolated`, or `load` losing its own, silently moves the work to
    /// the main thread, with no diagnostic under `-strict-concurrency=complete`. Here
    /// that would freeze an open popover for up to several five-second requests.
    ///
    /// A timed wait, so a regression fails instead of hanging. Both halves of a pass,
    /// because `fetch` starts the rotation beside the histories: two entry points with
    /// the same trap.
    func testLoadDoesNotNeedTheMainThread() {
        let counter = RequestCounter()
        let client = client(counter)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await UsageHistoryModel.load(client: client, labels: ["acc1", "acc2"],
                                             since: Date().addingTimeInterval(-3600))
            _ = await UsageHistoryModel.fetchRotation(client: client)
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success,
                       "the pass waited for a main thread that is standing right here")
        XCTAssertEqual(counter.urls.count, 3, "the pass finished without asking for anything")
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

    /// A pass that finished and a pass that brought lines are two facts. One stamp for
    /// both would make the chart claim the period held no data after a pass in which
    /// every account failed; the schedule still needs the "finished" fact, or a failed
    /// first pass would stop the refresh while the popover stays open.
    func testAPassNobodyAnsweredIsNotAnAnswer() async throws {
        let counter = RequestCounter()
        let gateway = Gateway()
        gateway.answers = false
        let history = UsageHistoryModel(client: client(counter, gateway: gateway),
                                        defaults: freshDefaults())
        history.open(labels: ["acc1", "acc2"])
        await history.fetchTask?.value
        defer { history.close() }

        XCTAssertEqual(histories(counter).count, 2, "the pass never reached the gateway")
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
        XCTAssertEqual(asked, 2, "one history and the rotation: \(counter.urls)")
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

    /// On the pass that succeeds, the old lines are just as wrong until it lands.
    /// `period.didSet` only refetches and does not touch the series, and the answer can
    /// take up to five seconds, so the drawing site must ask `seriesPeriod`.
    /// Held at what the view branches on rather than the view: a `Charts` tree has no
    /// ink of its own to count.
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

        // The footer must not date lines that are not on screen: the stamp in hand is the
        // previous window's. Asked of the model because the state is reachable on every
        // change of period, and far enough in the future to be audible: inside
        // `footerStaleSeconds` the footer is silent anyway.
        XCTAssertNotNil(history.fetchedAt, "the model left no stamp for the footer to misuse")
        XCTAssertNil(UsagePopoverView.footerAgeLabel(quotaFetchedAt: nil,
                                                     quotaFailed: false,
                                                     chartFetchedAt: history.fetchedAt,
                                                     seriesPeriod: history.seriesPeriod,
                                                     period: history.period,
                                                     chartFailed: false,
                                                     historiesFailed: false,
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

    /// A popover nobody is looking at draws no chart.
    ///
    /// `NSPopover` keeps its content view controller for the life of the process
    /// (`AppDelegate` assigns it once), so this `body` is rebuilt on every publication of
    /// `usage.snapshot`, once a minute; without the guard the chart is rebuilt behind a
    /// shut popover. Asked with the lines in hand, so the chart really would be drawn.
    ///
    /// `ImageRenderer` returns the previous rendering for content that draws nothing, so
    /// counting ink of the shut plot asks nothing. The picture is taken over an opaque
    /// ground and compared with the ground alone: `XCTAssertNotEqual` for the chart,
    /// `XCTAssertEqual` for the blank that stands in for it.
    ///
    /// The last assertion holds the slot's height, which comes from `chart`
    /// (`.frame(height: 130)`); it is measured on the whole view because `plot` is given
    /// its box by `plotBytes`.
    func testAShutPopoverDrawsNoChart() async throws {
        let counter = RequestCounter()
        let history = model(counter, defaults: freshDefaults())
        let usage = UsageStore(config: .default, cache: UsageCache())
        history.open(labels: ["acc1"])
        // Cleanup for a throw out of the renderings below, which would otherwise
        // leave the timer running; the `close()` in the middle is the subject of
        // the test and stays where it is.
        defer { history.close() }
        await history.fetchTask?.value
        let view = UsagePopoverView(usage: usage, history: history)

        // The two questions the chart branch asks, in the same words, so the fixture cannot
        // drift into the "no data" branch. `allSatisfy` rather than `series.isEmpty`: an
        // account that answered only holes is present and empty, and a list of those draws
        // no lines.
        XCTAssertFalse(history.series.allSatisfy(\.isEmpty), "the fixture left no lines to draw")
        XCTAssertEqual(history.seriesPeriod, history.period,
                       "the lines in hand answer another period, so no chart is drawn anyway")

        let ground = try plotBytes(Color.clear)
        XCTAssertNotEqual(try plotBytes(view.plot), ground,
                          "the open popover drew nothing at all — the measurement is empty")
        let openHeight = try pictureHeight(view)

        history.close()
        XCTAssertEqual(try plotBytes(view.plot), ground,
                       "the chart was built behind a shut popover")
        XCTAssertEqual(try pictureHeight(view), openHeight,
                       "the blank standing in for the chart changed the height of the popover")
    }

    /// What a view puts down over an opaque ground, in the box the popover gives
    /// the plot, as bytes: see `testAShutPopoverDrawsNoChart` for why the ground.
    private func plotBytes(_ view: some View) throws -> [UInt8] {
        let content = ZStack {
            Color.white
            view
        }
        .frame(width: UsagePopoverView.width, height: 130)
        let renderer = ImageRenderer(content: content)
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
        return pixels
    }

    /// The height of a rendering of the whole popover, at its own natural size.
    private func pictureHeight(_ view: some View) throws -> Int {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage, "ImageRenderer produced nothing").height
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

    /// The band the mean of 100 and 20 runs through, and nothing else does. Measured off
    /// the rendering: with the y scale pinned to 0…100 the plot runs from 0% of the
    /// picture's height (the 100 grid line) to 84% (the 0 one), so 60% lands at 34%.
    /// The account lines are at 0% and 68% and the 50 grid line at 42%, none inside.
    private static let meanBand = 0.32...0.36

    /// The band the lower of the two accounts (20) runs through: 1780 inked
    /// against 6 with that account moved up to 100.
    private static let accountBand = 0.67...0.70

    /// The mean line is on the chart, where the mean is. Read off a bitmap (§4), since a
    /// `Charts` tree has no ink to inspect and the claim is visibility. Accounts at 100
    /// and 20 put the mean in a band nothing else crosses; moving both to 100 takes it
    /// out with the rest unchanged, leaving the difference the mean line makes.
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

    /// It is the one line drawn at full strength: wider than the accounts and not
    /// dimmed. Weighed by coverage rather than counted pixels, because a line at 55%
    /// alpha covers as many pixels as one at full strength.
    /// The threshold sits between measurements: 3.83 times as drawn, 1.54 with the
    /// mean's width reduced to an account's, 2.11 with the accounts undimmed. Both halves
    /// fail it.
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

    /// An account that did not answer the history request must not shift the colours of
    /// those that did. Colours go to the lines here and to the dots beside the account
    /// names, from two lists that match only while every account answers; each must be
    /// keyed on the poll's list. Asked of the scale: `styleRange` decides a line's
    /// colour, `accountColor` the dots'.
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

    // MARK: - Switching an account out of the rotation

    /// A request held mid-air until the test lets it through, and cancellable
    /// while it waits.
    ///
    /// The second half is the whole point: a switch that was cancelled and one
    /// that is merely slow look exactly alike at a stub that always answers, and
    /// what `close` promises is precisely the difference between them.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var arrivals: [CheckedContinuation<Void, Never>] = []
        private var opened = false
        private var reached = false
        private var claimed = false

        func open() {
            lock.lock()
            opened = true
            let pending = waiting
            waiting = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                reached = true
                let announce = arrivals
                arrivals = []
                let through = opened
                if !through { waiting.append(continuation) }
                lock.unlock()
                announce.forEach { $0.resume() }
                if through { continuation.resume() }
            }
        }

        /// Returns once a request has reached the gate, whether or not it is let through.
        /// That makes a race deterministic: started from `open`, the pass is a main-actor
        /// `Task` whose body has not run, so a click sent right after can be stamped first,
        /// and then the pass is legitimately newer and should win.
        func arrival() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                let already = reached
                if !already { arrivals.append(continuation) }
                lock.unlock()
                if already { continuation.resume() }
            }
        }

        /// Answers `true` to the first caller and `false` to every one after it. Lets a test
        /// put two passes in the air and know the order they land in: `open` releases
        /// everyone at once and the executor picks the order, so only the first is held.
        /// Synchronous under the same lock, so "first" is settled once.
        func claimFirst() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    /// A gateway that answers the three questions separately: histories from the
    /// fixture, the rotation from `status`, a switch from `switchAnswer`; `nil` makes
    /// that endpoint fail while the others answer.
    ///
    /// The switch and the rotation may each be held in a gate, never both: the gates
    /// order a pass against a click. `historyGate` orders the two halves of one pass and
    /// composes with either.
    ///
    /// `firstStatus` holds the first `/gw/status` in its own gate with its own body;
    /// later ones answer from `status` ungated, for tests with two passes in the air
    /// (`statusGate` holds both). The body differs so a stale write is visible. This path
    /// does not check for cancellation: it stands for the answer already in hand when
    /// the cancel arrives, the case `fetch`'s guards are written against.
    private func rotationClient(_ counter: RequestCounter,
                                status: String? = UsageFixtures.status,
                                switchAnswer: String? = UsageFixtures.switchAnswer,
                                gate: Gate? = nil,
                                statusGate: Gate? = nil,
                                firstStatus: (gate: Gate, body: String)? = nil,
                                historyGate: Gate? = nil) -> UsageClient {
        UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            counter.record(request.url)
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            let body: String?
            if url.path.hasSuffix("/history") {
                if let historyGate {
                    await historyGate.wait()
                    try Task.checkCancellation()
                }
                body = UsageFixtures.history
            } else if url.path == "/gw/status" {
                if let firstStatus, firstStatus.gate.claimFirst() {
                    await firstStatus.gate.wait()
                    body = firstStatus.body
                } else {
                    if let statusGate {
                        await statusGate.wait()
                        try Task.checkCancellation()
                    }
                    body = status
                }
            } else {
                if let gate {
                    await gate.wait()
                    try Task.checkCancellation()
                }
                body = switchAnswer
            }
            guard let body else { throw UsageError.unreachable("nothing to say about \(url.path)") }
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(body.utf8), response)
        }
    }

    private func switchRequests(_ counter: RequestCounter) -> [URL] {
        counter.urls.filter { $0.path.hasPrefix("/gw/accounts/") }
    }

    /// A second click on a switch already in the air sends nothing: the second click of
    /// a double click asks for the opposite, and with both requests out the network
    /// would decide. The guard is the label being in flight. The third click, after the
    /// answer lands, is the control.
    func testASecondClickOnASwitchAlreadyInTheAirSendsNothing() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(client: rotationClient(counter), defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        defer { history.close() }

        history.setAccount(label: "acc2", enabled: false)
        XCTAssertTrue(history.inFlight.contains("acc2"), "the guard has nothing to guard against")
        history.setAccount(label: "acc2", enabled: true)
        await history.switchTasks["acc2"]?.value

        XCTAssertEqual(switchRequests(counter).count, 1,
                       "both clicks went out: \(switchRequests(counter))")
        XCTAssertEqual(switchRequests(counter).first?.path, "/gw/accounts/acc2/disable",
                       "and the one that went is the one that was clicked first")
        XCTAssertTrue(history.inFlight.isEmpty, "the label stayed in flight after its answer")

        // The click that lands after it is sent, so the count above is a guard
        // and not a model that only ever sends one.
        history.setAccount(label: "acc2", enabled: true)
        await history.switchTasks["acc2"]?.value
        XCTAssertEqual(switchRequests(counter).count, 2)
    }

    /// A rotation nobody answered is `nil`, not an empty fleet — and it costs the
    /// chart nothing, because the two questions of a pass fail apart.
    ///
    /// `nil` against `[:]` is the whole of it: an empty dictionary is the gateway
    /// saying "no accounts", and every switch drawn from it would be drawn clear
    /// and clickable on the strength of a request that never arrived.
    func testARotationNobodyAnsweredIsNotAnEmptyFleet() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(client: rotationClient(counter, status: nil),
                                        defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        defer { history.close() }

        XCTAssertNil(history.switches, "a failed rotation request was written down as an empty fleet")
        XCTAssertNotNil(history.rotationFailure, "and nothing said why")
        XCTAssertEqual(history.series.map(\.label), ["acc2"], "the chart went with it")
        XCTAssertNil(history.failure, "and the histories were blamed for it too")
    }

    /// A pass publishes each account's token health, so the row of an account the
    /// gateway cannot renew a token for can say so.
    func testAPassPublishesAnAccountThatNeedsALogin() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(
            client: rotationClient(counter, status: UsageFixtures.statusWithAnAccountThatNeedsALogin),
            defaults: freshDefaults())
        history.open(labels: ["acc2", "acc3"])
        await history.fetchTask?.value
        defer { history.close() }

        XCTAssertEqual(history.auth["acc3"],
                       AccountAuth(state: "needs_manual_token",
                                   error: "refresh token rejected (HTTP 400)"),
                       "the pass never put the dead account's state on the model")
        XCTAssertEqual(history.auth["acc2"]?.state, "ok")
    }

    /// And a rotation that was answered once is kept when the next pass fails.
    ///
    /// The same rule the lines follow: an answer replaces what is held, a pass
    /// that got none leaves it alone. Blanking it here would take every switch on
    /// screen inert for a reason that has nothing to do with the switches.
    func testAKnownRotationSurvivesAPassThatCouldNotAskAgain() async {
        let counter = RequestCounter()
        let gateway = Gateway()
        let history = UsageHistoryModel(client: UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            counter.record(request.url)
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            let isRotation = url.path == "/gw/status"
            guard !isRotation || gateway.answers else {
                throw UsageError.unreachable("the gateway is not there")
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data((isRotation ? UsageFixtures.status : UsageFixtures.history).utf8), response)
        }, defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        defer { history.close() }
        XCTAssertEqual(history.switches?["acc3"]?.disabled, true, "the first pass learned nothing")
        XCTAssertEqual(history.auth["acc2"]?.state, "ok", "the first pass learned no token health")

        gateway.answers = false
        history.fetch()
        await history.fetchTask?.value
        XCTAssertEqual(history.switches?["acc3"]?.disabled, true,
                       "one failed request took the whole rotation off the screen")
        XCTAssertEqual(history.auth["acc2"]?.state, "ok", "a failed pass wiped the token notes")
        XCTAssertNotNil(history.rotationFailure, "and it was kept without a word about its age")
    }

    /// A rotation body missing one account's switch takes the whole fleet to "unknown",
    /// not that account to "in": a missing `disabled` read as on would tick and arm every
    /// box. Refusing it draws boxes clear, inert, and blamed in the line underneath.
    func testARotationBodyMissingASwitchLeavesEveryBoxUnknown() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(
            client: rotationClient(counter, status: UsageFixtures.statusWithoutTheSwitch),
            defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        defer { history.close() }

        XCTAssertNil(history.switches, "one account with a hole in it lit up the whole fleet")
        XCTAssertNotNil(history.rotationFailure, "and nothing said why the boxes went inert")
        XCTAssertFalse(UsagePopoverView.switchAppearance(history.switches?["acc2"], busy: false).usable,
                       "a box nobody reported on was left clickable")
    }

    /// A rotation body missing the routing flag raises no warning: it means "this app
    /// cannot say", not "nowhere to route". Read as `?? false`, two accounts nobody
    /// switched off would paint the loudest line on the surface. The blame and inert
    /// boxes are the honest reading.
    func testARotationWithNoRoutingFlagRaisesNoWarningAtAll() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(
            client: rotationClient(counter, status: UsageFixtures.statusWithoutTheRoutingFlag),
            defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        defer { history.close() }

        XCTAssertNil(history.fleetWarning, """
            a body that never mentioned routing was read as a fleet with nowhere to route, and \
            the orange line says every client request is now a 429
            """)
        XCTAssertNil(history.switches, "a body refused whole left switches behind")
        XCTAssertNotNil(history.rotationFailure, "and nothing said why the boxes went inert")
    }

    /// A switch answer with no count blames the click and raises nothing. This decoder
    /// runs on the operator's click, so `?? 0` would raise the orange line under the
    /// pointer. The per-label blame is what a failed click leaves, and the tick does not
    /// move. The passes either side answer `status`, with one routable account, so there
    /// is nothing to warn about at any point.
    func testASwitchAnswerWithNoCountBlamesTheClickAndWarnsAboutNothing() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(
            client: rotationClient(counter, switchAnswer: UsageFixtures.switchAnswerWithoutTheCount),
            defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        defer { history.close() }
        XCTAssertNil(history.fleetWarning, "the fleet had somewhere to route before the click")

        history.setAccount(label: "acc2", enabled: false)
        await history.switchTasks["acc2"]?.value

        XCTAssertNil(history.fleetWarning, """
            a body that never named the fleet's cost was read as a cost of everything, under \
            the pointer of the operator who had just clicked
            """)
        XCTAssertEqual(history.switchFailures["acc2"]?.hasPrefix("acc2: "), true,
                       "the click that could not be read was not blamed: \(history.switchFailures)")
        XCTAssertEqual(history.switches?["acc2"]?.disabled, false,
                       "an answer nobody could read moved the switch anyway")
        // The failed click asks the rotation again, and that pass is the one this
        // test lets finish rather than leaving in the air.
        await history.fetchTask?.value
    }

    /// The state after a switch is the gateway's answer and nothing else. Asked with an
    /// answer that contradicts the request, the only fixture that tells storing the
    /// answer from storing the request; a gateway refusing a switch would otherwise show
    /// the click rather than the fleet. The fixture's derivation is beside the other
    /// switch answers, where
    /// `testEverySwitchAnswerFixtureOnThisListIsABodyTheGatewayCouldHaveSent` reaches it.
    func testTheStateAfterASwitchIsTheOneTheGatewaySentBack() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(
            client: rotationClient(counter,
                                   switchAnswer: UsageFixtures.switchAnswerContradictingTheClick),
            defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        defer { history.close() }

        history.setAccount(label: "acc2", enabled: false)
        await history.switchTasks["acc2"]?.value

        XCTAssertEqual(history.switches?["acc2"]?.disabled, false,
                       "the row shows the click instead of the fleet")
        XCTAssertEqual(history.switches?["acc2"]?.disabledReason, "pinned")
        XCTAssertEqual(history.switches?["acc3"]?.disabled, true,
                       "the answer about one account rewrote the others")
    }

    /// A switch the gateway would not take changes nothing, says why, and keeps saying it
    /// after a successful pass. The blame is kept per label rather than in the field the
    /// pass writes: a failed click has no other mark (the tick does not move), so a pass
    /// must not clear it.
    func testABlameForAClickOutlivesAPassThatWentFine() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(client: rotationClient(counter, switchAnswer: nil),
                                        defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        defer { history.close() }
        XCTAssertTrue(history.switchFailures.isEmpty, "nothing had gone wrong before the click")

        history.setAccount(label: "acc2", enabled: false)
        await history.switchTasks["acc2"]?.value

        XCTAssertEqual(history.switches?["acc2"]?.disabled, false,
                       "a request that never landed moved the switch anyway")
        XCTAssertEqual(history.switchFailures["acc2"]?.hasPrefix("acc2: "), true,
                       "the blame does not name the account: \(history.switchFailures)")
        XCTAssertTrue(history.inFlight.isEmpty, "the label was left in flight, so the row stays inert")

        // The pass the failure itself asks for — and it answers, so this is the
        // successful pass the blame has to survive.
        await history.fetchTask?.value
        XCTAssertNil(history.rotationFailure, "the pass that had to go well did not")
        XCTAssertEqual(history.switchFailures["acc2"]?.hasPrefix("acc2: "), true,
                       "a pass that went fine wiped the one mark a failed click leaves")
        XCTAssertNotNil(UsagePopoverView.switchBlame(history.switchFailures),
                        "and the line under the accounts had nothing left to print")

        // The next click on that same label is what clears it: the operator acting
        // on the switch again is the one event that says the message was read.
        history.setAccount(label: "acc2", enabled: false)
        XCTAssertTrue(history.switchFailures.isEmpty, "the message outlived the click that answered it")
        await history.switchTasks["acc2"]?.value
        await history.fetchTask?.value
    }

    /// A switch that failed asks the gateway what actually happened. A timeout
    /// (`UsageClient.timeoutSeconds` is five) does not mean the gateway dropped the
    /// request, so the switch may have been applied; keeping the old tick would invite a
    /// click that undoes it. One extra pass is cheaper.
    func testASwitchThatFailedAsksTheRotationAgain() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(client: rotationClient(counter, switchAnswer: nil),
                                        defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        defer { history.close() }
        let asked = counter.urls.filter { $0.path == "/gw/status" }.count
        XCTAssertEqual(asked, 1, "the opening pass asked for the rotation more than once")

        history.setAccount(label: "acc2", enabled: false)
        await history.switchTasks["acc2"]?.value
        await history.fetchTask?.value

        XCTAssertEqual(counter.urls.filter { $0.path == "/gw/status" }.count, asked + 1,
                       "the failed switch left the tick standing as a confirmed state")
    }

    /// What the switch cost the fleet is shown. A zero count is the one thing the
    /// operator cannot work out from the checkboxes; the screen shows this app's wording
    /// (the gateway's sentence says `fleet`, which §4 keeps off displayed strings).
    /// The second click is the reverse pair, `eligible_accounts: 1` with `warning: null`
    /// (`_switch_payload` writes `None if eligible else "…"`), and the line goes with it.
    /// `testEverySwitchAnswerFixtureOnThisListIsABodyTheGatewayCouldHaveSent` holds both
    /// bodies to that pairing.
    func testAFleetWithNothingLeftInItSaysSoAndStopsSayingIt() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(client: UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            counter.record(request.url)
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            let body: String
            if url.path.hasSuffix("/history") {
                body = UsageFixtures.history
            } else if url.path == "/gw/status" {
                body = UsageFixtures.status
            } else {
                // The switch already counted above is this one, so the first
                // answer carries the warning and the second says it is over.
                body = counter.urls.filter { $0.path.hasPrefix("/gw/accounts/") }.count == 1
                    ? UsageFixtures.switchAnswerWithWarning
                    : UsageFixtures.switchAnswerPuttingTheAccountBack
            }
            return (Data(body.utf8), response)
        }, defaults: freshDefaults())
        history.open(labels: ["main"])
        await history.fetchTask?.value
        defer { history.close() }
        XCTAssertNil(history.fleetWarning, "there was nothing to warn about before the click")

        history.setAccount(label: "main", enabled: false)
        await history.switchTasks["main"]?.value
        // Ours rather than the answer's, even here where the answer carried a
        // sentence: the click and the pass raise one line with one wording.
        XCTAssertEqual(history.fleetWarning, UsageHistoryModel.noRouteWarning)

        history.setAccount(label: "main", enabled: true)
        await history.switchTasks["main"]?.value
        XCTAssertNil(history.fleetWarning,
                     "the count said there is somewhere to route and the line stayed up")
    }

    /// A switch already on its way outlives the popover closing: a close happens on any
    /// click elsewhere and is not a change of mind. `fetchTask` is cancelled there and
    /// this one is not, hence two fields. The gate makes the difference visible: the
    /// request checks cancellation when let through, so a `close` that reached it fails.
    func testASwitchAlreadySentOutlivesTheClose() async {
        let counter = RequestCounter()
        let gate = Gate()
        let history = UsageHistoryModel(client: rotationClient(counter, gate: gate),
                                        defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value

        history.setAccount(label: "acc2", enabled: false)
        history.close()
        gate.open()
        await history.switchTasks["acc2"]?.value

        XCTAssertEqual(history.switches?["acc2"]?.disabled, true,
                       "the close took the switch with it: \(history.switchFailures)")
        XCTAssertTrue(history.switchFailures.isEmpty)
    }

    /// A pass that left before the click may not undo it.
    ///
    /// `open` fires a pass at once, and a switch is one short POST against a pass's
    /// `/gw/status` plus a history per account, so an early click is answered first and
    /// the pass lands on top with the pre-click state. The tick would go back for up to
    /// a minute and read as "the click did nothing". What carries this is the ratio (four
    /// requests of some 208 KB against one small one), not an absolute;
    /// `UsageHistoryModel.applyRotation` has the measurements.
    ///
    /// The gate holds `/gw/status` and the test waits for it to be reached before
    /// clicking; without that wait the order is undecided: the pass is a `Task` on the
    /// main actor whose body has not run yet, so its request can be sent after the click,
    /// and then the pass is the newer news and is supposed to win.
    func testAPassThatLeftBeforeTheClickDoesNotPutTheTickBack() async {
        let counter = RequestCounter()
        let statusGate = Gate()
        let history = UsageHistoryModel(client: rotationClient(counter, statusGate: statusGate),
                                        defaults: freshDefaults())
        history.open(labels: ["acc2"])
        defer { history.close() }
        await statusGate.arrival()

        history.setAccount(label: "acc2", enabled: false)
        await history.switchTasks["acc2"]?.value
        XCTAssertEqual(history.switches?["acc2"]?.disabled, true, "the answer to the click never landed")

        statusGate.open()
        await history.fetchTask?.value

        XCTAssertEqual(history.switches?["acc2"]?.disabled, true, """
            the pass put the tick back where it stood before the click, and the fixture it \
            came from is older news than the answer the operator already has
            """)
        // The control: the pass did land, so the assertion above is a rule and
        // not a pass that quietly wrote nothing at all.
        XCTAssertEqual(history.switches?["acc3"]?.disabled, true, "the pass never reached the model")
        XCTAssertNotNil(history.switches?["main"], "the pass never reached the model")
    }

    /// A label with a click still in the air is left alone too. It has no answer yet to
    /// be newer than the pass, but letting a pass write the pre-click state under it says
    /// the same wrong thing for the length of the round trip.
    ///
    /// The second pass answers something else about `acc2`, since overwriting the row
    /// with the same value and leaving it alone look identical. `acc3` moving the other
    /// way is the control that the pass landed.
    func testAPassLeavesAloneALabelWithAClickStillInTheAir() async {
        let counter = RequestCounter()
        let gate = Gate()
        let history = UsageHistoryModel(client: UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            counter.record(request.url)
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            let body: String
            if url.path.hasSuffix("/history") {
                body = UsageFixtures.history
            } else if url.path == "/gw/status" {
                // The rotation request already counted is this one, so the first
                // pass gets the fixture and every pass after it gets the change.
                body = counter.urls.filter { $0.path == "/gw/status" }.count == 1
                    ? UsageFixtures.status
                    : UsageFixtures.statusWithASwitchThrownElsewhere
            } else {
                await gate.wait()
                try Task.checkCancellation()
                body = UsageFixtures.switchAnswer
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(body.utf8), response)
        }, defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        defer { history.close() }
        XCTAssertEqual(history.switches?["acc2"]?.disabled, false, "the first pass said nothing useful")

        history.setAccount(label: "acc2", enabled: false)
        XCTAssertTrue(history.inFlight.contains("acc2"), "there is no click in the air to guard")
        history.fetch()
        await history.fetchTask?.value

        XCTAssertEqual(history.switches?["acc3"]?.disabled, false, "the second pass never landed")
        XCTAssertEqual(history.switches?["acc2"]?.disabled, false,
                       "a pass rewrote the box the operator is waiting on")
        XCTAssertEqual(history.switches?["acc2"]?.disabledReason, "")

        // And the answer, when it comes, is what moves it.
        gate.open()
        await history.switchTasks["acc2"]?.value
        XCTAssertEqual(history.switches?["acc2"]?.disabled, true)
    }

    /// A pass that found somewhere to route takes the warning down. The warning is about
    /// the fleet, and the fleet moves without this app (an account put back from the
    /// command line, a quota window that reset).
    ///
    /// It is also the control on the hold next door: this pass is asked after the click
    /// was answered, so it is newer and should win.
    func testAPassThatFoundSomewhereToRouteTakesTheWarningDown() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(
            client: rotationClient(counter, switchAnswer: UsageFixtures.switchAnswerWithWarning),
            defaults: freshDefaults())
        history.open(labels: ["main"])
        await history.fetchTask?.value
        defer { history.close() }

        history.setAccount(label: "main", enabled: false)
        await history.switchTasks["main"]?.value
        XCTAssertNotNil(history.fleetWarning, "the switch that emptied the fleet said nothing")

        // The fixture names one routable account, which is the fleet answering the
        // question the warning asks.
        history.fetch()
        await history.fetchTask?.value
        XCTAssertNil(history.fleetWarning, """
            a pass that found the fleet with somewhere to route left the warning standing, \
            and it will stand at every opening until the app is restarted
            """)
    }

    /// The count is the verdict and the sentence only its wording, so a pass raises the
    /// line as well as taking it down. The gateway computes `routableAccounts` and
    /// `eligible_accounts` with the same `is_eligible`, so the pass's count is as good as
    /// the switch's, and a fleet emptied from the command line or by backoff is reported
    /// too.
    ///
    /// The fixture is a fleet nobody has switched off: `eligible` folds the five-hour
    /// window in with the operator's switch, so the line appears with every box ticked
    /// when the windows have filled. That is the state the sentence describes.
    /// `/gw/status` sends no sentence at all.
    func testTheCountRaisesTheWarningWithNoSentenceAnywhere() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(client: UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            counter.record(request.url)
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            let body: String
            if url.path.hasSuffix("/history") {
                body = UsageFixtures.history
            } else {
                // The rotation request already counted is this one, so the first
                // pass finds a fleet with nowhere to route and the next one finds
                // `status`, where `acc2` is routable.
                body = counter.urls.filter { $0.path == "/gw/status" }.count == 1
                    ? UsageFixtures.statusWithNowhereToRoute
                    : UsageFixtures.status
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(body.utf8), response)
        }, defaults: freshDefaults())
        history.open(labels: ["main"])
        await history.fetchTask?.value
        defer { history.close() }

        XCTAssertEqual(history.fleetWarning, UsageHistoryModel.noRouteWarning, """
            a fleet the gateway cannot route to said nothing, because nobody in this session \
            had clicked anything
            """)
        // The state, not the switches: nobody has been switched off, so the boxes
        // are all ticked and it is the line that carries the news.
        XCTAssertEqual(history.switches?["main"]?.disabled, false)
        XCTAssertEqual(history.switches?["acc2"]?.disabled, false)

        history.fetch()
        await history.fetchTask?.value
        XCTAssertNil(history.fleetWarning, "a count above zero left the line standing")
    }

    /// A pass that left before the operator's click may not take the warning down
    /// either. A tick put back wrongly is repaired by the next pass; a warning taken down
    /// wrongly comes back only with another click. The scene: the minute pass is in the
    /// air, the operator switches the last usable account off, the POST answers first
    /// with the sentence, and the pass lands with the pre-click fleet.
    ///
    /// The gate holds `/gw/status` and the test waits for it to be reached, so the pass
    /// really did leave first.
    func testAPassThatLeftBeforeTheClickDoesNotTakeTheWarningDown() async throws {
        let counter = RequestCounter()
        let statusGate = Gate()
        let history = UsageHistoryModel(
            client: rotationClient(counter,
                                   switchAnswer: UsageFixtures.switchAnswerWithWarning,
                                   statusGate: statusGate),
            defaults: freshDefaults())
        history.open(labels: ["main"])
        defer { history.close() }
        await statusGate.arrival()

        history.setAccount(label: "main", enabled: false)
        await history.switchTasks["main"]?.value
        let raised = try XCTUnwrap(history.fleetWarning,
                                   "the switch that emptied the fleet never raised the line")

        statusGate.open()
        await history.fetchTask?.value

        XCTAssertEqual(history.fleetWarning, raised, """
            the pass counted the fleet as it stood before the click and took the line down, \
            and nothing but another click could ever put it back
            """)
        // The control: the pass did land, so the assertion above is a rule and not
        // a pass that quietly wrote nothing at all. `acc3` is a label the click
        // never touched, so it carries the pass's own reading.
        XCTAssertEqual(history.switches?["acc3"]?.disabled, true, "the pass never reached the model")
    }

    /// Two clicks answered in the opposite order to the one they were asked in: the
    /// count that stands is the one asked for last.
    ///
    /// `setAccount` guards one label at a time, so a click on a different account while
    /// the first is in the air goes out. The count is the fleet's and moves with every
    /// switch, so two answers are two readings of one quantity. Here `acc2` off (count
    /// 1), then `main` off (count 0, with the sentence); `main`'s answer lands first and
    /// raises the line, and `acc2`'s, unordered, would take it back down, leaving every
    /// request answered 429 with nothing on screen until the next pass.
    ///
    /// A gate per label makes the order a fact. The per-label writes are deliberately not
    /// ordered: an answer is authoritative about its own account, which the last
    /// assertion reads.
    ///
    /// The settling pass this ends on is answered with the fleet the two clicks left
    /// behind (`UsageFixtures.statusWithBothRoutableAccountsSwitchedOff`), though no
    /// assertion here reads it: the middle two read `inFlight` and a count put up before
    /// the settling pass exists, and the last three run in the same actor turn as the
    /// `await` on `acc2`'s task, before that pass can land. An assertion added here that
    /// reads the tick or the line off that pass reads the gateway.
    func testTheCountThatStandsIsTheOneAskedForLast() async throws {
        let counter = RequestCounter()
        let acc2Gate = Gate()
        let mainGate = Gate()
        // The fleet the two answers below are derived against is not `status` but
        // `statusWithTwoRoutableAccounts`, where the derivation is written down.
        let history = UsageHistoryModel(client: UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            counter.record(request.url)
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            let body: String
            if url.path.hasSuffix("/history") {
                body = UsageFixtures.history
            } else if url.path == "/gw/status" {
                // A pass reads the accounts table the POSTs write to, so it reports
                // the switches that had landed by the time it was asked. Keyed on the
                // switch requests already recorded — this pass is none of them — which
                // is the same question for the two passes the healthy program asks
                // here: the sitting's own, with nothing switched yet, and the settling
                // one after both of the burst's clicks were answered.
                body = counter.urls.contains { $0.path.hasPrefix("/gw/accounts/") }
                    ? UsageFixtures.statusWithBothRoutableAccountsSwitchedOff
                    : UsageFixtures.statusWithTwoRoutableAccounts
            } else if url.path.hasPrefix("/gw/accounts/acc2/") {
                await acc2Gate.wait()
                try Task.checkCancellation()
                body = UsageFixtures.switchAnswer
            } else {
                await mainGate.wait()
                try Task.checkCancellation()
                body = UsageFixtures.switchAnswerWithWarning
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(body.utf8), response)
        }, defaults: freshDefaults())
        history.open(labels: ["acc2", "main"])
        await history.fetchTask?.value
        defer { history.close() }
        XCTAssertNil(history.fleetWarning, "the fleet had somewhere to route before either click")

        // Asked in this order, both still in the air.
        history.setAccount(label: "acc2", enabled: false)
        history.setAccount(label: "main", enabled: false)
        XCTAssertEqual(history.inFlight, ["acc2", "main"],
                       "both clicks have to be out at once for either order to exist")

        // And answered in the other one.
        mainGate.open()
        await history.switchTasks["main"]?.value
        let raised = try XCTUnwrap(history.fleetWarning,
                                   "the switch that emptied the fleet never raised the line")

        acc2Gate.open()
        await history.switchTasks["acc2"]?.value

        XCTAssertEqual(history.fleetWarning, raised, """
            the answer asked for first landed last and took the line down with a count from \
            before the second click, and nothing but another click could put it back
            """)
        // The control: that answer did land, so the assertion above is a rule and
        // not a request that quietly failed on its way.
        XCTAssertEqual(history.switches?["acc2"]?.disabled, true,
                       "the older answer never reached the model, so it was refused by nothing")
        XCTAssertEqual(history.switches?["main"]?.disabled, true)
    }

    /// The count is settled by asking, once the last of two overlapping clicks has
    /// landed.
    ///
    /// The ask-instant guard orders answers by when this app asked, which is only the
    /// nearest thing to the order the gateway measured in: which of two handlers ran
    /// first was decided by two connections reaching one single-threaded loop. So the
    /// class is closed by an observation: one pass, asked when nothing is in the air.
    ///
    /// Not before: while another click is out, `isStale` refuses whatever count a pass
    /// brings back, and that click brings its own settling pass. Not for a click that
    /// went out alone either (`testALoneClickIsSettledByItsOwnAnswer`): `fetch` cancels
    /// the pass in flight, so settling after every click would put `isStale`'s ordering
    /// half out of reach.
    ///
    /// Counted in `/gw/status` requests, one per pass. A gate per label holds `main`
    /// while `acc2` is let through, so "a click still in the air" is asked in the right
    /// arrangement. Each assertion awaits `fetchTask` first, because a pass fired here is
    /// a `Task` whose request may not have reached the counter yet.
    ///
    /// The settling pass is answered with the fleet the burst left behind
    /// (`UsageFixtures.statusWithBothRoutableAccountsSwitchedOff`); no assertion here
    /// reads that body.
    func testTheCountIsSettledByAPassOnceTheLastClickHasLanded() async {
        let counter = RequestCounter()
        let acc2Gate = Gate()
        let mainGate = Gate()
        func passes() -> Int { counter.urls.filter { $0.path == "/gw/status" }.count }
        let history = UsageHistoryModel(client: UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            counter.record(request.url)
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            let body: String
            if url.path.hasSuffix("/history") {
                body = UsageFixtures.history
            } else if url.path == "/gw/status" {
                // A pass reads the accounts table the POSTs write to, so it reports
                // the switches that had landed by the time it was asked. Keyed on the
                // switch requests already recorded — this pass is none of them — which
                // is the same question for the two passes the healthy program asks
                // here: the sitting's own, with nothing switched yet, and the settling
                // one after both of the burst's clicks were answered.
                body = counter.urls.contains { $0.path.hasPrefix("/gw/accounts/") }
                    ? UsageFixtures.statusWithBothRoutableAccountsSwitchedOff
                    : UsageFixtures.statusWithTwoRoutableAccounts
            } else if url.path.hasPrefix("/gw/accounts/acc2/") {
                await acc2Gate.wait()
                try Task.checkCancellation()
                body = UsageFixtures.switchAnswer
            } else {
                await mainGate.wait()
                try Task.checkCancellation()
                body = UsageFixtures.switchAnswerWithWarning
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(body.utf8), response)
        }, defaults: freshDefaults())
        history.open(labels: ["acc2", "main"])
        await history.fetchTask?.value
        defer { history.close() }
        let opening = passes()
        XCTAssertEqual(opening, 1, "the sitting's own first pass did not happen")

        history.setAccount(label: "acc2", enabled: false)
        history.setAccount(label: "main", enabled: false)
        XCTAssertEqual(history.inFlight, ["acc2", "main"],
                       "both clicks have to be out at once for either half of this to exist")

        acc2Gate.open()
        await history.switchTasks["acc2"]?.value
        XCTAssertEqual(history.inFlight, ["main"], "the other click was not still in the air")
        await history.fetchTask?.value
        XCTAssertEqual(passes(), opening, """
            a pass was asked with a click still in the air, where `isStale` refuses whatever \
            count it brings back — bytes spent to be ignored
            """)

        mainGate.open()
        await history.switchTasks["main"]?.value
        XCTAssertTrue(history.inFlight.isEmpty, "a click is still out, so nothing settles yet")
        await history.fetchTask?.value
        XCTAssertEqual(passes(), opening + 1, """
            the last click landed and nobody asked the gateway to count the fleet again, so the \
            standing count is whichever of the two answers the ask-instant happened to admit
            """)
    }

    /// A click that went out alone is settled by its own answer: no pass. The settling
    /// pass exists for two POSTs in the air at once. A lone POST meets only a pass's
    /// count, and those are ordered in both directions already: `isStale` refuses a pass
    /// asked before this answer's confirmation, and `applyRoutable` refuses a count asked
    /// earlier than the one on screen.
    ///
    /// A pass here would also cost more than bytes: `fetch` cancels `fetchTask`, so
    /// settling after every click destroys the pass `isStale`'s second half is written to
    /// refuse, and that half could never fire (the two
    /// `testAPassThatLeftBeforeTheClick…` tests would lose their subject).
    ///
    /// Counted in `/gw/status` requests; `fetchTask` is awaited first, as next door.
    func testALoneClickIsSettledByItsOwnAnswer() async {
        let counter = RequestCounter()
        func passes() -> Int { counter.urls.filter { $0.path == "/gw/status" }.count }
        let history = UsageHistoryModel(client: rotationClient(counter),
                                        defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        defer { history.close() }
        let opening = passes()
        XCTAssertEqual(opening, 1, "the sitting's own first pass did not happen")

        history.setAccount(label: "acc2", enabled: false)
        await history.switchTasks["acc2"]?.value
        // The control: the click really was answered, so the count below is about
        // a burst that ended rather than one that never started.
        XCTAssertEqual(history.switches?["acc2"]?.disabled, true,
                       "the answer to the click never landed")
        await history.fetchTask?.value

        XCTAssertEqual(passes(), opening, """
            a click sent on its own asked the gateway to count the fleet again, which costs \
            a pass to settle what its own answer already settled — and cancels the pass in \
            flight, the one `isStale` exists to refuse
            """)
    }

    /// "Sent on its own" is a fact about this click, not about the sitting: a burst that
    /// overlapped is charged to itself and to nothing after it.
    ///
    /// `clicksOverlapped` is set when the second click of a burst goes out and reset only
    /// beside the line that reads it. Without the reset the first overlapping burst arms
    /// it for good, and every later lone click takes the settling path, cancelling
    /// whatever pass is in the air.
    ///
    /// The burst here is the neighbour's (`acc2` and `main` off with both POSTs in the
    /// air, the settling pass awaited), then `main` put back on its own. Every body is
    /// one the gateway could have sent at that moment; the count runs 2, 1, 0, 0, 1:
    /// `statusWithTwoRoutableAccounts` (`acc3` parked), `switchAnswer`,
    /// `switchAnswerWithWarning`, `statusWithBothRoutableAccountsSwitchedOff`, and
    /// `switchAnswerPuttingTheAccountBack`.
    ///
    /// That settling body is what makes the second control meaningful: `main` stands at
    /// `disabled: true` when the lone click goes out, so only that click's own answer
    /// puts it back. A failed click goes through `setAccount`'s failure branch, which
    /// calls `fetch()` unconditionally, so the control fails along with the final count.
    ///
    /// No gate holds the burst: `setAccount` is synchronous up to `inFlight.insert`, so
    /// both are in the air before either is answered. Counts are taken after awaiting
    /// `fetchTask`.
    func testABurstsOverlapIsNotChargedToTheNextLoneClick() async {
        let counter = RequestCounter()
        func passes() -> Int { counter.urls.filter { $0.path == "/gw/status" }.count }
        let history = UsageHistoryModel(client: UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            counter.record(request.url)
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            let body: String
            if url.path.hasSuffix("/history") {
                body = UsageFixtures.history
            } else if url.path == "/gw/status" {
                // A pass reads the accounts table the POSTs write to, so it reports
                // the switches that had landed by the time it was asked. Counted in
                // the switch requests already recorded — this pass is none of them —
                // and the healthy program asks exactly two: the sitting's own, with
                // nothing switched yet, and the settling one after both of the
                // burst's clicks.
                body = counter.urls.contains { $0.path.hasPrefix("/gw/accounts/") }
                    ? UsageFixtures.statusWithBothRoutableAccountsSwitchedOff
                    : UsageFixtures.statusWithTwoRoutableAccounts
            } else if url.path == "/gw/accounts/acc2/disable" {
                body = UsageFixtures.switchAnswer
            } else if url.path == "/gw/accounts/main/disable" {
                body = UsageFixtures.switchAnswerWithWarning
            } else {
                body = UsageFixtures.switchAnswerPuttingTheAccountBack
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(body.utf8), response)
        }, defaults: freshDefaults())
        history.open(labels: ["acc2", "main"])
        await history.fetchTask?.value
        defer { history.close() }
        let opening = passes()
        XCTAssertEqual(opening, 1, "the sitting's own first pass did not happen")

        history.setAccount(label: "acc2", enabled: false)
        history.setAccount(label: "main", enabled: false)
        XCTAssertEqual(history.inFlight, ["acc2", "main"],
                       "both clicks have to be out at once for the flag to be set at all")
        await history.switchTasks["acc2"]?.value
        await history.switchTasks["main"]?.value
        await history.fetchTask?.value
        // The control: the burst really did settle, so what follows is about a flag
        // that was set and then had to be cleared, rather than one never set.
        XCTAssertEqual(passes(), opening + 1, "the burst never settled, so there is no flag to clear")

        history.setAccount(label: "main", enabled: true)
        await history.switchTasks["main"]?.value
        // And the second control: the lone click was answered, so the count below
        // is about a click that finished rather than one still in the air. The
        // settling pass left `main` switched off — see the note above on why that
        // is the body the gateway would have sent it — so nothing but this click's
        // own answer can be what makes this read `false`.
        XCTAssertEqual(history.switches?["main"]?.disabled, false,
                       "the answer to the lone click never landed")
        await history.fetchTask?.value

        XCTAssertEqual(passes(), opening + 1, """
            a lone click was charged for an earlier burst's ambiguity and asked for a settling \
            pass of its own — which cancels the pass in flight, the one `isStale` exists to refuse
            """)
    }

    /// A failed click's blame does not follow the operator into the next sitting. It is
    /// cleared otherwise only by the next click on that label, so it would keep reporting
    /// an old failure as current (§2.4).
    ///
    /// Cleared on `open`, not `close`: a popover closes on any click anywhere, and `open`
    /// fires a pass in the next line, which settles what the blame stands for.
    func testAFailedClicksBlameDoesNotSurviveIntoTheNextSitting() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(client: rotationClient(counter, switchAnswer: nil),
                                        defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value

        history.setAccount(label: "acc2", enabled: false)
        await history.switchTasks["acc2"]?.value
        await history.fetchTask?.value
        XCTAssertNotNil(UsagePopoverView.switchBlame(history.switchFailures),
                        "the click that could not go through left nothing to clear")

        history.close()
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        defer { history.close() }

        XCTAssertTrue(history.switchFailures.isEmpty, """
            an hour-old failure came back with the popover and reads as this sitting's: \
            \(history.switchFailures)
            """)
        XCTAssertNil(UsagePopoverView.switchBlame(history.switchFailures))
    }

    /// Neither do the fleet's own two messages, for the same reason and with the same
    /// remedy: after a shut popover they stand for a tick that may be an hour old.
    ///
    /// Both are put up first in two passes: one answers a fleet with nowhere to route,
    /// the next cannot ask and writes the blame while keeping the warning. The
    /// assertions after the reopen run before the new pass: `open` starts it as a `Task`
    /// on this actor.
    func testTheFleetsOwnTwoMessagesDoNotSurviveIntoTheNextSitting() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(client: UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            counter.record(request.url)
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            let isRotation = url.path == "/gw/status"
            // The rotation request already counted is this one, so the first pass
            // is answered and every pass after it is not.
            if isRotation, counter.urls.filter({ $0.path == "/gw/status" }).count > 1 {
                throw UsageError.unreachable("the gateway is not there")
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            let body = isRotation ? UsageFixtures.statusWithNowhereToRoute : UsageFixtures.history
            return (Data(body.utf8), response)
        }, defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        XCTAssertEqual(history.fleetWarning, UsageHistoryModel.noRouteWarning,
                       "the fleet with nowhere to route said nothing, so there is nothing to clear")

        history.fetch()
        await history.fetchTask?.value
        XCTAssertNotNil(history.rotationFailure, "the pass that had to fail did not")
        XCTAssertNotNil(history.fleetWarning,
                        "a failed pass took the warning with it, and the reopen below proves nothing")

        history.close()
        history.open(labels: ["acc2"])
        defer { history.close() }

        XCTAssertNil(history.fleetWarning, """
            an hour-old "every client request is a 429" came back with the popover and reads as \
            this second's, in orange and with no age beside it
            """)
        XCTAssertNil(history.rotationFailure, """
            and an hour-old reason the boxes went inert came back with it: \
            \(history.rotationFailure ?? "")
            """)
        await history.fetchTask?.value
    }

    /// Neither does the rotation itself, which matters most because it is a control. An
    /// hour-old reading survives a shut popover (`close` leaves it, `NSPopover` keeps the
    /// view controller), so the boxes would be drawn from it, ticked and clickable. A
    /// click on a stale tick changes the fleet: `disableAccount` sends no body, which the
    /// gateway's `_parse_disable_body` reads as `DISABLED_NO_DEADLINE`, so a timed parking
    /// becomes an indefinite switch-off.
    ///
    /// Asked of the model: a checkbox renders as the same 784 inked pixels in all four
    /// states. `switchAppearance` and `switchHelp` show what `nil` costs on screen. The
    /// pass afterwards is the control, without which a model that never learned a
    /// rotation would pass. An empty carry-over must stay `nil`, not `[:]` ("the gateway
    /// said nobody").
    func testTheRotationItselfDoesNotSurviveIntoTheNextSitting() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(client: rotationClient(counter), defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        XCTAssertEqual(history.switches?["acc3"]?.disabled, true,
                       "the first sitting learned no rotation, so there is nothing to clear")
        XCTAssertNotNil(history.auth["acc2"], "the first sitting learned no token health")

        history.close()
        history.open(labels: ["acc2"])
        defer { history.close() }
        XCTAssertTrue(history.auth.isEmpty, "an hour-old token note came back with the popover")

        // Read before the new pass has run: `open` starts it as a `Task` on this
        // actor, so this is the surface the operator meets on the way in.
        XCTAssertNil(history.switches, """
            an hour-old rotation came back with the popover, and every box is drawn from it as \
            this second's: \(history.switches ?? [:])
            """)
        let look = UsagePopoverView.switchAppearance(history.switches?["acc3"], busy: false)
        XCTAssertEqual(look.ticked, false, "a box was ticked from a reading this app no longer has")
        XCTAssertEqual(look.usable, false, "and it could be clicked")
        XCTAssertEqual(UsagePopoverView.switchHelp(history.switches?["acc3"]),
                       "The gateway did not say whether this account is in rotation")

        await history.fetchTask?.value
        XCTAssertEqual(history.switches?["acc3"]?.disabled, true,
                       "the pass `open` fires never filled the rotation back in")
        XCTAssertNotNil(history.auth["acc2"], "the pass `open` fires never filled the token notes back in")
    }

    /// Except the label the operator is waiting on: a click still in the air carries its
    /// reading across the reopen, and the new sitting's first pass may not write under
    /// it.
    ///
    /// `close` does not cancel a sent switch, so a POST can be in the air behind a shut
    /// popover for up to `UsageClient.timeoutSeconds`. The hold in `applyRotation` lays
    /// the value this app already has over the pass's, so a wiped rotation would leave
    /// nothing to lay, and the box would show the pre-click reading.
    ///
    /// Unlike `testAPassLeavesAloneALabelWithAClickStillInTheAir`, the close and reopen
    /// fall between the click and the pass, the only order in which the dictionary is
    /// empty under a label in flight. `acc3`'s 22-hour parking has expired by the reopen,
    /// so the pass has something else to say about it. Asked of `switchAppearance` for
    /// the reason the previous test gives.
    func testAClickStillInTheAirKeepsItsRowAcrossTheReopen() async {
        let counter = RequestCounter()
        let gate = Gate()
        let history = UsageHistoryModel(client: UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            counter.record(request.url)
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            let body: String
            if url.path.hasSuffix("/history") {
                body = UsageFixtures.history
            } else if url.path == "/gw/status" {
                // The rotation request already counted is this one, so the first
                // sitting gets the fixture and the second gets the change: the
                // 22-hour parking of `acc3` ran out between the two sittings —
                // `disabled: false` with the past deadline and the operator's
                // reason still standing beside it, which is how the gateway
                // reports an expiry nobody clicked (see the fixture).
                body = counter.urls.filter { $0.path == "/gw/status" }.count == 1
                    ? UsageFixtures.status
                    : UsageFixtures.statusWithTheParkingExpired
            } else {
                await gate.wait()
                try Task.checkCancellation()
                body = UsageFixtures.switchAnswerPuttingAcc3Back
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(body.utf8), response)
        }, defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        XCTAssertEqual(history.switches?["acc3"]?.disabled, true,
                       "the first sitting learned no rotation, so there is nothing to carry")

        history.setAccount(label: "acc3", enabled: true)
        XCTAssertTrue(history.inFlight.contains("acc3"), "there is no click in the air to carry")

        history.close()
        history.open(labels: ["acc2"])

        // Read before the new pass has run, and it is the whole of what survives:
        // the label in flight and nothing beside it. The confirmed ones are not
        // carried because this sitting's pass is asked after this line and is
        // newer than every one of them, which `holds` decides on its own.
        XCTAssertEqual(history.switches?.keys.sorted(), ["acc3"], """
            the reopen was supposed to carry the one row nobody could settle yet and nothing \
            else; it carried \(history.switches.map { "\($0.keys.sorted())" } ?? "nothing at all")
            """)

        await history.fetchTask?.value
        let look = UsagePopoverView.switchAppearance(history.switches?["acc3"],
                                                     busy: history.inFlight.contains("acc3"))
        XCTAssertFalse(look.ticked, """
            the pass wrote the gateway's own reading under a box whose click is still in the \
            air, and it is drawn as this second's state of an account being switched
            """)
        XCTAssertFalse(look.usable, "a label with a click in the air took a second one")
        // The control that the pass landed at all: `acc2` has no click on it and
        // carries the pass's own reading.
        XCTAssertEqual(history.switches?["acc2"]?.disabled, false, "the pass never reached the model")
        XCTAssertNotNil(history.switches?["main"], "the pass never reached the model")

        // And the answer, when it comes, is what moves it.
        gate.open()
        await history.switchTasks["acc3"]?.value
        defer { history.close() }
        XCTAssertEqual(history.switches?["acc3"]?.disabled, false)
        XCTAssertTrue(UsagePopoverView.switchAppearance(history.switches?["acc3"],
                                                        busy: history.inFlight.contains("acc3")).usable,
                      "the row stayed inert after its own answer landed")
    }

    /// The three stamps that decide whether a pass is older than the operator's click run
    /// on a clock that cannot step backwards. They are only compared, never drawn, and
    /// the wall clock does step back (NTP, wake from sleep), which would stamp an answer
    /// in the future and block every later pass from refreshing the label.
    ///
    /// Asked of `Rotation.askedAt`, which covers the other two: `holds` compares
    /// `switchConfirmedAt[label]` with it, and `applyRoutable(_:askedAt:)` takes a
    /// `ContinuousClock.Instant`, so the compiler keeps all three on one clock.
    func testTheStampsThatDecideAStalePassCannotStepBackwards() throws {
        let rotation = UsageHistoryModel.Rotation(state: nil, auth: nil, routable: nil, failure: nil,
                                                  askedAt: UsageHistoryModel.stamp())
        let askedAt = try XCTUnwrap(Mirror(reflecting: rotation).children
            .first { $0.label == "askedAt" }?.value)
        XCTAssertTrue(askedAt is ContinuousClock.Instant, """
            the hold is decided on \(type(of: askedAt)), and a wall clock steps back: one \
            correction after a switch answer and that label stops taking the gateway's word \
            until the clock catches up
            """)
    }

    /// A switch must not need the main thread either. `switchAccount` runs from a `Task`
    /// started inside a `@MainActor` method, which inherits the main actor; only
    /// `nonisolated` keeps the request off it, nothing warns when that is lost, and the
    /// cost is up to five seconds of a frozen open popover. Timed, so a regression fails
    /// instead of hanging (§6).
    func testSwitchingAnAccountDoesNotNeedTheMainThread() {
        let counter = RequestCounter()
        let client = rotationClient(counter)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await UsageHistoryModel.switchAccount(client: client, label: "acc2", enabled: false)
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success,
                       "the switch waited for a main thread that is standing right here")
        XCTAssertEqual(switchRequests(counter).count, 1, "the switch finished without asking for anything")
    }

    /// Inked pixels, over an area the size the popover gives the plot.
    private func ink(_ view: some View) throws -> Int {
        try rendered(view).inked
    }

    /// What a rendering put down, over the whole plot or a horizontal band given as
    /// fractions of the height from the top. `inked` counts pixels carrying anything
    /// (where a line is and how wide); `coverage` sums how much, the only one opacity
    /// moves: a line at 55% alpha is as inked as one at 100% and half as heavy.
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

    /// The end of the line and the number over it are one quantity. They cannot be one
    /// call (the headline is `fleet.seven_day.mean` from `/gw/usage`, the line comes from
    /// `/gw/usage/{label}/history`), so what is held is the rule, the mean of every
    /// account's last known reading, computed by one function. Two accounts here were
    /// last sampled before the third, which is what makes carrying matter.
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

    /// Two readings stamped the same second are one point on the line, the last of them.
    /// The gateway sends such pairs (its poll and a response-header reading in one
    /// second), and the marks are keyed on the stamp
    /// (`ForEach(segment.readings, id: \.timestamp)`), where duplicate ids are outside
    /// what `ForEach` promises.
    ///
    /// Only the drawn series: the raw samples keep their repeats, because a zero-length
    /// step still carries spend `FleetCapacity` and `UsageStore` measure (§2.7).
    func testTwoReadingsOnOneSecondAreOnePointOnTheLine() throws {
        let pair = AccountSeries.make(label: "acc1", points: try samples([(0, 10), (0, 12), (1, 20)]))
        XCTAssertEqual(pair.segments.count, 1)
        XCTAssertEqual(pair.segments.first?.readings.map(\.timestamp), [moment(0), moment(1)],
                       "the repeated stamp is on the line twice")
        XCTAssertEqual(pair.segments.first?.readings.map(\.value), [12, 20],
                       "the earlier reading of the repeated second won")

        // Three of them, which is as long as a repeat has been seen to run, and
        // a hole beside them: the stamps of a segment are unique whatever the
        // series does around them.
        let triple = AccountSeries.make(label: "acc1",
                                        points: try samples([(0, 10), (0, 11), (0, 12),
                                                             (1, nil),
                                                             (2, 30), (2, 33)]))
        XCTAssertEqual(triple.segments.map { $0.readings.map(\.value) }, [[12], [33]])
        for segment in triple.segments {
            XCTAssertEqual(Set(segment.readings.map(\.timestamp)).count, segment.readings.count,
                           "a segment holds one stamp twice: \(segment.readings)")
        }
    }

    /// And the last of them is the one the mean is already drawn from, which is
    /// why it is the one kept.
    ///
    /// `FleetSeries.make` eats every sample at or before a moment and keeps the
    /// last non-null of them, so an account line built off the first reading of a
    /// repeated second would sit at one value while the bold line over it sits at
    /// another — at the same point of the same picture.
    func testTheEndOfAnAccountLineAgreesWithTheMeanOnARepeatedSecond() throws {
        let points = try samples([(0, 10), (1, 40), (1, 44)])
        let line = try XCTUnwrap(AccountSeries.make(label: "acc1", points: points)
            .segments.last?.readings.last)
        let mean = try XCTUnwrap(FleetSeries.make(from: [points]).points.last)
        XCTAssertEqual(line.timestamp, mean.timestamp, "the two lines end at different moments")
        XCTAssertEqual(mean.accounts, 1, "the mean is over more accounts than the fixture has")
        XCTAssertEqual(line.value, mean.value, accuracy: 0.001,
                       "the account's line and the mean over it read the same second differently")
        XCTAssertEqual(line.value, 44, accuracy: 0.001, "both of them read the repeat backwards")
    }
}

/// The sawtooth the lag between the two measuring sources puts on the chart, and
/// the rule that takes it off without touching anything the quota actually did.
@MainActor
final class SourceLagTests: XCTestCase {

    /// Samples a minute apart, as the gateway sends them. Decoded rather than
    /// constructed, because a hole is a thing only the wire format can say.
    private func samples(_ readings: [Double?]) throws -> [HistoryPoint] {
        let body = readings.enumerated().map { index, value in
            "{\"ts\": \(1_786_700_000 + index * 60), \"util_7d\": \(value.map { "\($0)" } ?? "null")}"
        }
        return try UsageFixtures.decode("[\(body.joined(separator: ","))]", as: [HistoryPoint].self)
    }

    private func filtered(_ readings: [Double?]) throws -> [Double?] {
        UsageHistoryModel.withoutSourceLag(try samples(readings)).map(\.sevenDay)
    }

    /// The shortest fall there is: one sample a point below the reading either
    /// side of it. 43 of the 322 falls in the live history lasted a single sample,
    /// and a median of three could have reached 42 of them — the forty-third stood
    /// last in its series, where no filter may go (§4). Those were the only ones it
    /// could reach at all.
    func testASingleSampleFallIsPulledUp() throws {
        XCTAssertEqual(try filtered([40, 39, 40]), [40, 40, 40])
        // The same event seen from the other side — the leading source spiking up
        // between two trailing samples. The spike is a genuine new level, and the
        // sample after it is the one that gets pulled, so inside the series no comb
        // is left either way round. The tail is the exception and it is not this
        // test's: the array below ends on a fall of 41 → 40, which stands because
        // the last reading is never moved (`testTheLastReadingIsNeverMoved`).
        XCTAssertEqual(try filtered([40, 41, 40, 40]), [40, 41, 41, 40])
    }

    /// The fall a median of three cannot reach, and the reason this rule replaced
    /// it. A fall lasts 3 to 5 samples in the live history — the trailing source
    /// is behind by about a poll cycle, and every sample it takes meanwhile
    /// repeats the stale figure. A median of three leaves every one of these
    /// standing; taken out with the old filter in place, this test fails.
    func testALongFallIsPulledUpToTheReadingBeforeIt() throws {
        XCTAssertEqual(try filtered([40, 39, 39, 39, 40]), [40, 40, 40, 40, 40])
        // Five samples of it, which is the commonest length of all (§4).
        XCTAssertEqual(try filtered([40, 39, 39, 39, 39, 39, 40]),
                       [40, 40, 40, 40, 40, 40, 40])
    }

    /// A step is not a fall. The quota goes up in ones all day long, and every one
    /// of those is kept: the rule only ever looks at readings that went *down*.
    func testAGenuineStepSurvivesWhole() throws {
        XCTAssertEqual(try filtered([40, 41, 41]), [40, 41, 41])
        XCTAssertEqual(try filtered([40, 40, 41, 41, 42, 42]), [40, 40, 41, 41, 42, 42])
    }

    /// The largest step there is, a week rolling over, survives to the sample. The window
    /// is hard, not sliding, so utilisation inside one only accumulates; a reset is a
    /// real corner followed by a `resets_at` exactly 7×24 h later (§4).
    func testAQuotaResetIsNotSmoothedAway() throws {
        XCTAssertEqual(try filtered([87, 87, 3, 3]), [87, 87, 3, 3])
        XCTAssertEqual(try filtered([100, 100, 0, 0, 1]), [100, 100, 0, 0, 1])
        // A reset that falls by exactly one point is still a reset: the rule reads
        // a zero as the window rolling over and takes it as it came, rather than
        // carrying the 1 across it and drawing a week that never ended.
        XCTAssertEqual(try filtered([1, 0, 0]), [1, 0, 0])
        XCTAssertEqual(try filtered([1, 0, 0, 1, 1]), [1, 0, 0, 1, 1])
    }

    /// A level is never carried across a hole. A `null` says the gateway took no
    /// reading at that moment (§4) — a reset may have happened inside one — so
    /// after a hole the rule starts again with nothing behind it.
    func testTheLevelIsNotCarriedAcrossAHole() throws {
        XCTAssertEqual(try filtered([40, nil, 80]), [40, nil, 80])
        // The bite of it: the same shape with and without the hole. Continuous,
        // the two samples after the 41 are a fall and get pulled up to it; with a
        // hole in front of them there is no level to pull them to.
        XCTAssertEqual(try filtered([40, 41, 40, 40, 41]), [40, 41, 41, 41, 41])
        XCTAssertEqual(try filtered([40, 41, nil, 40, 40, 41]), [40, 41, nil, 40, 40, 41])
        // And the pass carries on afterwards: the hole stops the level, not the
        // filter.
        XCTAssertEqual(try filtered([10, nil, 40, 39, 39, 40]), [10, nil, 40, 40, 40, 40])
    }

    /// The last reading is never moved: the freshest figure is the one thing the rule may
    /// not invent, so the line ends at the reading that arrived (§4). The rule looks only
    /// backwards, so a hole on the right stops nothing and the exemption is explicit: the
    /// pass ends at the last reading rather than the last element. Both forms are asked.
    func testTheLastReadingIsNeverMoved() throws {
        // A fall at the very end of the array, which is where the exemption costs
        // something: the line ends a point below the level before it, and that is
        // the price of the end of the line being the figure that arrived.
        XCTAssertEqual(try filtered([40, 40, 40, 39]), [40, 40, 40, 39])
        XCTAssertEqual(try filtered([40, 39, 39, 39]), [40, 40, 40, 39])
        // The same fall with nothing but holes after it. Still the last reading.
        XCTAssertEqual(try filtered([40, 40, 39, nil]), [40, 40, 39, nil])
        XCTAssertEqual(try filtered([40, 40, 39, nil, nil]), [40, 40, 39, nil, nil])
        // A reset is the case that matters, being the largest step there is: the
        // gateway last said 3, so the line ends at 3, however many samples it took
        // no reading for afterwards.
        for holes in 1...4 {
            let readings: [Double?] = [87, 87, 3] + Array(repeating: nil, count: holes)
            XCTAssertEqual(try filtered(readings).compactMap { $0 }.last, 3,
                           "the last reading moved with \(holes) hole(s) after it")
        }
    }

    /// A series too short to have a fall in it comes back as it was, rather than
    /// coming back empty. A series of nothing but holes too — there is no last
    /// reading to stop at, and the pass has to survive that.
    func testAVeryShortSeriesIsLeftAlone() throws {
        XCTAssertEqual(try filtered([]), [])
        XCTAssertEqual(try filtered([41]), [41])
        XCTAssertEqual(try filtered([41, 40]), [41, 40])
        XCTAssertEqual(try filtered([nil]), [nil])
        XCTAssertEqual(try filtered([nil, nil]), [nil, nil])
    }

    /// The picture the user pointed at, in the shape the live data has it: a run
    /// of trailing `headers` samples with a `poll` sample rising a point above
    /// them every poll cycle, over and over. After the rule the line has no fall
    /// left in it at all.
    func testTheCombOfTheTwoSourcesComesOutFlat() throws {
        let comb: [Double?] = [38, 39, 38, 38, 39, 38, 38, 39, 39]
        XCTAssertEqual(try filtered(comb), [38, 39, 39, 39, 39, 39, 39, 39, 39])
        // Strict alternation is the shape a median of three moves the phase of
        // instead of flattening. This rule flattens it, because it asks what the
        // window has already reached rather than what the neighbours agree on.
        let alternating: [Double?] = [38, 39, 38, 39, 38, 39]
        XCTAssertEqual(try filtered(alternating), [38, 39, 39, 39, 39, 39])
    }

    /// The rule's properties, asked of a series no `XCTAssertEqual` pins. The input is
    /// generated deterministically (a fixed seed through a linear congruential step, no
    /// `random()` or `Date`): six hundred-odd samples of a climbing level combed by
    /// falls of one to six samples, with resets and holes, and a trailing-source sample
    /// last so the tail exemption is in play.
    ///
    /// Four properties restate the rule: inside a window the result never falls; no
    /// reading moves by anything but exactly +1 pp; resets come through untouched; the
    /// last reading stays put. Four more assertions check the input and the work done,
    /// since a rule that did nothing would satisfy all four: the series holds a comb, at
    /// least two resets, one of them not into zero, and the rule moved a hundred samples.
    func testTheRuleHoldsItsPropertiesOverAGeneratedComb() throws {
        var seed: UInt64 = 0x2026_0817
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        var readings: [Double?] = []
        var resets: Set<Int> = []
        var level = 1.0
        while readings.count < 600 {
            for _ in 0...next(3) { readings.append(level) }
            // The trailing source repeating the figure from before this step, one
            // to six samples of it, and then the leading source again.
            let lag = next(7)
            if lag > 0, level > 1 {
                for _ in 0..<lag { readings.append(level - 1) }
                readings.append(level)
            }
            switch next(12) {
            case 0:
                readings.append(nil)                // nobody measured
            case 1 where level >= 5:
                // The window rolled over. Not always into zero: the gateway's
                // first sample of a new window can already carry a point or two,
                // and that is the reset the *depth* of the fall has to catch
                // rather than the guard on zero.
                level = Double(next(4))
                resets.insert(readings.count)
                readings.append(level)
            default:
                level += 1                          // spend
            }
        }
        // The series ends inside a lag, whatever the loop happened to leave behind:
        // the level once more, and then the trailing source repeating the figure
        // under it — the one sample the rule may not touch.
        level = max(level, 2)
        readings.append(level)
        readings.append(level - 1)
        let tail = readings.count - 1

        let result = try filtered(readings)
        XCTAssertEqual(result.count, readings.count)
        XCTAssertEqual(result.map { $0 == nil }, readings.map { $0 == nil },
                       "a hole was filled in or moved")

        // The input has to be able to break the rule before its surviving is worth
        // anything: a comb with resets in it, not a monotone ramp.
        let rawFalls = (1..<readings.count).filter { index in
            guard let previous = readings[index - 1], let value = readings[index] else { return false }
            return value < previous
        }
        XCTAssertGreaterThan(rawFalls.count, 50, "the generated series has no comb in it")
        XCTAssertGreaterThanOrEqual(resets.count, 2, "the generated series has no reset in it")
        // And at least one reset that does not land on zero. A series whose every
        // reset falls into zero is carried entirely by the guard on zero, and the
        // depth of the fall — the half of the condition that tells a reset from a
        // lag — is then never asked at all.
        XCTAssertGreaterThanOrEqual(resets.filter { (readings[$0] ?? 0) > 0 }.count, 1,
                                    "every generated reset fell into zero")

        // (1) Inside a window the result never falls. Two exceptions, and both are
        // the rule's own words: a reset, and the last reading.
        for index in 1..<result.count {
            guard let previous = result[index - 1], let value = result[index] else { continue }
            guard value < previous else { continue }
            XCTAssertTrue(resets.contains(index) || index == tail,
                          "the result fell at \(index): \(previous) → \(value)")
        }
        // (2) Every change is a reading raised to the level before it, by exactly
        // one point. Anything else is a figure nobody measured.
        var changed = 0
        for (raw, value) in zip(readings, result) {
            guard let raw, let value else { continue }
            if raw == value { continue }
            changed += 1
            XCTAssertEqual(value, raw + 1, "a reading moved from \(raw) to \(value)")
        }
        XCTAssertGreaterThan(changed, 100, "the rule barely touched the comb")
        // (3) The resets are the one event this chart exists to show.
        for index in resets.sorted() {
            XCTAssertEqual(result[index], readings[index], "the reset at \(index) was smoothed")
        }
        // (4) And the last reading is where it was — a point under the level the
        // window had reached, on a series long enough to have forgotten about it.
        XCTAssertEqual(result[tail], readings[tail], "the last reading moved")
        let beforeTail = try XCTUnwrap(result[tail - 1])
        let atTail = try XCTUnwrap(result[tail])
        XCTAssertEqual(beforeTail - atTail, 1, "this series was meant to end inside a lag")
    }

    /// `util_5h` is not filtered and the timestamps are not moved: the rule is
    /// about the one quantity this chart draws, and a sample that changed its
    /// moment would move the line sideways.
    func testNothingButTheSevenDayReadingIsTouched() throws {
        let body = (0..<3).map { index in
            "{\"ts\": \(1_786_700_000 + index * 60), \"util_5h\": \(index == 1 ? 91 : 4),"
                + " \"util_7d\": \(index == 1 ? 39 : 40)}"
        }
        let points = try UsageFixtures.decode("[\(body.joined(separator: ","))]",
                                              as: [HistoryPoint].self)
        let filtered = UsageHistoryModel.withoutSourceLag(points)
        XCTAssertEqual(filtered.map(\.sevenDay), [40, 40, 40])
        XCTAssertEqual(filtered.map(\.fiveHour), [4, 91, 4], "the five-hour window was filtered too")
        XCTAssertEqual(filtered.map(\.timestamp), points.map(\.timestamp))
    }

    /// And the filter is on the path the popover actually uses: the lines and the
    /// mean are both built from the filtered samples, so the two describe the same
    /// data. Applied on one path only, the bold line would run through falls the
    /// lines under it no longer have.
    func testBothTheLinesAndTheMeanAreBuiltFromFilteredSamples() async throws {
        // A gateway answering with the comb of the two sources, on one account.
        let client = UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            let points = [38, 39, 38, 38, 39].enumerated().map { index, value in
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
        XCTAssertEqual(readings, [38, 39, 39, 39, 39], "the account's line kept its falls")
        XCTAssertEqual(history.fleet.points.map(\.value), [38, 39, 39, 39, 39],
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

    /// A burn ratio as the surfaces read it, in per cent of the week's refill
    /// rate.
    private func ratio(_ percent: Double,
                       lowerBound: Bool = false) -> UsagePopoverView.HeadlineRatio {
        UsagePopoverView.HeadlineRatio(percent: percent, isLowerBound: lowerBound)
    }

    /// The fleet's burn against its refill, as the poll hands it over. Only `percent` and
    /// the lower-bound flag reach a surface; the rest is what `--dump` prints. Built to
    /// be an object production can produce: `refillRate` is what `burnAgainstRefill`
    /// computes for three contributors, `3 x 100 / 168` = 1.7857 pp/h, and `burnRate` is
    /// derived from the `percent` passed, so the three agree by construction. The depth
    /// is a plausible fixture value, not a measurement.
    ///
    /// `static` and internal because the menu bar's tests build the same fixture: both
    /// surfaces read one rule, so they get one figure.
    static func burn(_ percent: Double,
                     lowerBound: Bool = false) -> FleetCapacity.FleetBurn {
        FleetCapacity.FleetBurn(percent: percent,
                                burnRate: percent / 100 * 3 * 100 / 168,
                                refillRate: 3 * 100 / 168, accounts: 3, measuredHours: 47.9,
                                isLowerBound: lowerBound)
    }

    /// A snapshot the lead block can be drawn from: a ratio, and histories fresh enough
    /// to state it by. The tests below take these away one at a time.
    ///
    /// The live token rate comes along because the block prints it as a supporting
    /// reading; the lead is not made of it, and removing it leaves the lead unchanged.
    private func leading(lowerBound: Bool = false,
                         percent: Double = 126,
                         current: Double? = 23_800_000) -> UsageSnapshot {
        var snapshot = UsageSnapshot.empty
        snapshot.fleetSevenDayMean = 58.667
        snapshot.historiesFetchedAt = Date()
        snapshot.fleetTokenRate = current
        snapshot.fleetBurn = Self.burn(percent, lowerBound: lowerBound)
        return snapshot
    }

    /// A figure that is only a floor says so, in the symbol this app already
    /// uses for one (§2.7): an account sat at its ceiling while it was measured,
    /// so the points it was blocked from burning never reached the series, the
    /// burn came out too small against a refill share that account still brings,
    /// and the ratio is at least this — with no saying by how much.
    func testTheRatioLabelSaysWhenItIsOnlyAFloor() {
        XCTAssertEqual(UsagePopoverView.ratioLabel(for: ratio(126)), "126%")
        XCTAssertEqual(UsagePopoverView.ratioLabel(for: ratio(126, lowerBound: true)), "≥126%")
        XCTAssertEqual(UsagePopoverView.ratioLabel(for: ratio(125.6)), "126%", "rounded, like every "
                       + "other percentage this popover writes")
        XCTAssertEqual(UsagePopoverView.ratioLabel(for: ratio(0)), "0%",
                       "a fleet at rest has a figure, and it is not a dash")
    }

    /// The lead says what is being spent when it can, and falls back to the mean when it
    /// cannot. Every way the lead can be missing (gateway silent, no account with enough
    /// history, every account at its ceiling, an unexplained fall, histories unconfirmed
    /// for two intervals) arrives as one state, and none may become a number. With no
    /// mean either, it is the dash.
    func testTheHeadlineFallsBackToTheMeanWhenThereIsNoRatio() {
        var snapshot = UsageSnapshot.empty
        XCTAssertEqual(UsagePopoverView.headlineFigureLabel(for: snapshot), "—",
                       "nothing polled yet is a dash, not a zero")

        snapshot.fleetSevenDayMean = 58.667
        XCTAssertEqual(UsagePopoverView.headlineFigureLabel(for: snapshot), "59%",
                       "with no ratio the headline is the mean it has always been")

        // The arrival stamp goes with the figure, here and everywhere below: it
        // is half of what `historiesAreFresh` asks (a figure nobody has confirmed for
        // twenty minutes is not drawn), and a pass that produces a figure always
        // stamps it in the same breath — so a ratio without one is a fixture and
        // not a state the app can be in.
        XCTAssertEqual(UsagePopoverView.headlineFigureLabel(for: leading(lowerBound: true)),
                       "≥126%", """
            the burn against the refill is what the headline is for once there is one — and it \
            carries the floor mark, which the lead used to leave to the menu bar because it \
            printed a different quantity from the one the floor was a floor on
            """)
    }

    /// The lead is the burn against the refill, and the caption names what the hundred
    /// means. One quantity and one division, so the colour over the figure describes the
    /// figure itself.
    func testTheLeadStatesTheBurnAgainstTheWeeksRefill() throws {
        let snapshot = leading()
        let figure = try XCTUnwrap(UsagePopoverView.headlineRatio(for: snapshot))
        XCTAssertEqual(figure.percent, 126)
        XCTAssertFalse(figure.isLowerBound)
        XCTAssertEqual(UsagePopoverView.headlineFigureLabel(for: snapshot), "126%")
        XCTAssertEqual(UsagePopoverView.ratioCaption, "of the weekly refill rate")
        XCTAssertFalse(UsagePopoverView.ratioCaption.contains("token"), """
            the caption names tokens under a figure that is percentage points of a week, which \
            is the mismatch the whole metric was changed to remove
            """)
        XCTAssertEqual(figure.ratio, 1.26, accuracy: 0.001,
                       "the bar is the one drawn statement of how far past the refill it is")
    }

    /// The ratio the bar is drawn from is not rounded down on the way: how far
    /// past its refill a fleet is is exactly the thing this reading exists to
    /// carry, and the clamp belongs to the drawing rather than to the number
    /// (measured there — `testTheLeadBarFillsWithTheRatioAndStopsAtTheRefillRate`).
    func testTheLeadRatioIsKeptUnclamped() throws {
        let over = try XCTUnwrap(UsagePopoverView.headlineRatio(for: leading(percent: 300)))
        XCTAssertEqual(over.ratio, 3, accuracy: 0.001,
                       "a fleet burning three weeks a week said so, and the reading kept it")

        let under = try XCTUnwrap(UsagePopoverView.headlineRatio(for: leading(percent: 50)))
        XCTAssertEqual(under.ratio, 0.5, accuracy: 0.0001)

        let idle = try XCTUnwrap(UsagePopoverView.headlineRatio(for: leading(percent: 0)))
        XCTAssertEqual(idle.ratio, 0, "a fleet burning nothing draws no bar, and that is a reading")
    }

    /// The lead needs the ratio and nothing else: it falls back when the ratio is missing
    /// and not when the supporting live token rate is (no `tokens` block from an older
    /// gateway or with statistics off). That rate is printed with no bar and colours
    /// nothing.
    func testOnlyTheRatioGoingMissingTakesTheHeadlineBackToTheMean() {
        var noLiveRate = leading(current: nil)
        XCTAssertNotNil(UsagePopoverView.headlineRatio(for: noLiveRate), """
            the lead went back to the mean because a reading it no longer states was missing
            """)
        XCTAssertEqual(UsagePopoverView.headlineFigureLabel(for: noLiveRate), "126%")
        XCTAssertNil(noLiveRate.fleetTokenRate, "the fixture publishes the rate after all")

        noLiveRate.fleetBurn = nil
        XCTAssertNil(UsagePopoverView.headlineRatio(for: noLiveRate))
        XCTAssertEqual(UsagePopoverView.headlineFigureLabel(for: noLiveRate), "59%",
                       "a burn nobody measured is not a burn this line may state")
        XCTAssertEqual(UsagePopoverView.headlineFigureColor(for: noLiveRate, on: .dark), .primary,
                       "and the fallback is the whole block, colour included")
    }

    /// The magnitude letter steps with the number, and zero keeps its own shape.
    ///
    /// An idle fleet genuinely spends nothing (§2.7), so `0/h` has to read as a
    /// fleet at rest rather than as a figure rounded away — which is exactly what
    /// a fixed `%.1fM/h` would make of it.
    func testATokenRateIsWrittenAtItsOwnMagnitude() {
        XCTAssertEqual(UsagePopoverView.rateLabel(0), "0/h", "a fleet at rest, not a rounded million")
        XCTAssertEqual(UsagePopoverView.rateLabel(812), "812/h")
        XCTAssertEqual(UsagePopoverView.rateLabel(23_800_000), "23.8M/h")
        XCTAssertEqual(UsagePopoverView.rateLabel(1_500), "1.5k/h")
        XCTAssertEqual(UsagePopoverView.rateLabel(2_400_000_000), "2.4B/h")
        XCTAssertEqual(UsagePopoverView.rateLabel(999), "999/h", "and the step is at the thousand itself")
        XCTAssertEqual(UsagePopoverView.rateLabel(1_000), "1.0k/h")
    }

    /// A figure whose own half is failing is not one this line may state, and the
    /// fallback is the same as when there has never been one. With `/history` failing
    /// while `/gw/usage` and `/gw/sessions` answer, a frozen figure is wrong in either
    /// direction: a false alarm over a calmed fleet, or a calm green over one at 200%.
    ///
    /// The figure, the caption, the bar and the colour all follow the one answer, so all
    /// four are asked.
    func testAFailingHistoryHalfTakesTheHeadlineBackToTheMean() {
        var snapshot = leading()
        XCTAssertEqual(UsagePopoverView.headlineFigureLabel(for: snapshot), "126%")
        XCTAssertEqual(UsagePopoverView.headlineFigureColor(for: snapshot, on: .dark),
                       UsagePopoverView.ratioColor(atPercent: 126, on: .dark),
                       "the colour is the ratio the block states and not a second figure")
        XCTAssertTrue(UsagePopoverView.historiesAreFresh(for: snapshot))

        snapshot.historiesFailure = "/gw/usage/<label>/history: HTTP 500"
        XCTAssertFalse(UsagePopoverView.historiesAreFresh(for: snapshot),
                     "a figure nobody has confirmed since the outage began was still the headline")
        XCTAssertNil(UsagePopoverView.headlineRatio(for: snapshot),
                     "the ratio comes from that same failed half and goes with it")
        XCTAssertEqual(UsagePopoverView.headlineFigureLabel(for: snapshot), "59%")
        XCTAssertEqual(UsagePopoverView.headlineFigureColor(for: snapshot, on: .dark), .primary)

        // And the other halves' failures move none of it: the ratio comes from
        // the histories and from nowhere else. This surface keeps a stale figure
        // rather than blanking one — the same rule the account rows below it have
        // always followed.
        snapshot.historiesFailure = nil
        snapshot.quotaFailure = "/gw/usage: unreachable"
        snapshot.sessionsFailure = "/gw/sessions: unreachable"
        XCTAssertEqual(UsagePopoverView.headlineFigureLabel(for: snapshot), "126%",
                       "an endpoint that knows nothing about the histories blanked the lead")
    }

    /// A figure nobody has confirmed for two of its own intervals may not be stated on
    /// either surface, and no failure is set when that happens. Reachable with
    /// everything nominally healthy: a `/gw/usage` outage skips the histories half whole
    /// (`UsageStore.poll` will not measure a fleet whose membership nobody just
    /// confirmed), so `historiesFailure` stays `nil` and neither stamp moves.
    ///
    /// Both surfaces are asked because it is one rule: the menu bar has no room for the
    /// footer's caveat, so a ceiling applied only here would leave its colour outliving
    /// the reading.
    func testAFigureNobodyHasConfirmedForTwoIntervalsIsNotDrawnOnEitherSurface() {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        let ceiling = UsagePopoverView.historyStaleSeconds
        var snapshot = leading()

        snapshot.historiesFetchedAt = now.addingTimeInterval(-ceiling + 1)
        XCTAssertEqual(UsagePopoverView.headlineRatio(for: snapshot, now: now)?.percent, 126,
                       "a figure inside its own schedule was dropped: the ceiling is the "
                       + "slow cadence running, not staleness")
        XCTAssertNotNil(MenuBarIcon.ratio(for: snapshot, now: now))

        snapshot.historiesFetchedAt = now.addingTimeInterval(-ceiling)
        XCTAssertNil(UsagePopoverView.headlineRatio(for: snapshot, now: now),
                     "nothing has refreshed the figure for two of its intervals and it is "
                     + "still the headline")
        XCTAssertNil(MenuBarIcon.ratio(for: snapshot, now: now),
                     "the menu bar kept a colour whose reading nobody has confirmed")
        // And the fallback is the same one a failure gets: the mean, in ink.
        XCTAssertEqual(UsagePopoverView.headlineFigureLabel(for: snapshot, now: now), "59%")
        XCTAssertEqual(UsagePopoverView.headlineFigureColor(for: snapshot, now: now, on: .dark),
                       .primary)

        // A figure with no arrival stamp at all is in the same position: no pass
        // can produce one, and drawing it would be trusting a number with no age.
        snapshot.historiesFetchedAt = nil
        XCTAssertNil(UsagePopoverView.headlineRatio(for: snapshot, now: now))
        XCTAssertNil(MenuBarIcon.ratio(for: snapshot, now: now))

        // The ceiling is two of the interval the histories are actually fetched
        // on — not a number of its own that could drift away from the schedule.
        XCTAssertEqual(ceiling, 2 * UsageStore.historyIntervalSeconds)
    }

    /// The headline's colour is the load's colour, and ink when the headline falls back
    /// to the mean. Held here as a rule and in `UsagePopoverPaintTests` as a rendering:
    /// this half alone would pass for a function the view no longer calls.
    ///
    /// The mean never gets `QuotaBar`'s scale: at 92% of a window that scale is red, and
    /// a red figure over green account rows would be two scales for one reading.
    func testTheHeadlineFigureTakesTheRatiosColourAndTheMeanTakesNone() {
        var snapshot = UsageSnapshot.empty
        snapshot.fleetSevenDayMean = 92
        for plate in [UsagePopoverView.RampBackground.light, .dark] {
            XCTAssertEqual(UsagePopoverView.headlineFigureColor(for: snapshot, on: plate), .primary,
                           "the mean was coloured on a scale that belongs to a different quantity")
            XCTAssertEqual(UsagePopoverView.headlineFigureColor(for: .empty, on: plate), .primary)
        }

        for plate in [UsagePopoverView.RampBackground.light, .dark] {
            for percent in rampSamples {
                // The ramp reads the ratio this very block states — the burn the
                // figure names against the refill its caption names — so the
                // snapshot carries that ratio and no second figure the colour
                // could be taken from instead. The spend rate stays at its
                // fixture value on purpose: it is drawn on this surface, it does
                // not move with the ramp, and a ramp that had been wired to it
                // would come out flat across every sample here.
                snapshot = leading(percent: percent)
                XCTAssertEqual(UsagePopoverView.headlineFigureColor(for: snapshot, on: plate),
                               UsagePopoverView.ratioColor(atPercent: percent, on: plate),
                               "at \(percent)% on \(plate) the figure and the bar under it are two "
                               + "colours for one reading")
            }
        }
    }

    /// The ramp as a rule: pinned to this project's colours at its three anchors, flat
    /// outside them, and falling all the way between. The anchors are asked against the
    /// system colours themselves (the family `QuotaBar.color(for:)` uses), so the test
    /// goes stale if a system colour moves.
    ///
    /// What survives a plate is the hue, and that is asked of all three. Both plates move
    /// the rest (light lowers brightness, dark raises it then lowers saturation,
    /// `legible(_:on:)`). The green at capacity on the dark plate comes through untouched
    /// (5.36:1 against a floor of 4.69) and is asked whole; the two ends are asked for
    /// hue and for the values the floor leaves them at: on light, full saturation at
    /// brightness 0.7955 (blue) and 0.7451 (red); on dark, full brightness at saturation
    /// 0.6383 and 0.5228.
    ///
    /// The shape is held here as well as in the renderings: a rule a view stopped calling
    /// answers correctly for ever, and a rendering samples only a few loads.
    func testTheRatioRampIsThisProjectsColoursStretchedBetweenThreeAnchors() throws {
        // Resolved inside the appearance the anchors were measured in, and that
        // is not ceremony: `Color.blue` answers hue 0.5869 in `aqua` and 0.5837
        // in `darkAqua`, which is wider than the tolerance below — a suite that
        // read the family against whatever appearance the machine was in would
        // pass or fail by the system theme.
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        var anchors: [(name: String, plate: UsagePopoverView.RampBackground,
                       ramp: (hue: Double, saturation: Double, brightness: Double),
                       family: (hue: Double, saturation: Double, brightness: Double))] = []
        appearance.performAsCurrentDrawingAppearance {
            for plate in [UsagePopoverView.RampBackground.light, .dark] {
                for (name, percent, family) in [("cold", UsagePopoverView.coldRatioPercent, Color.blue),
                                                ("green", UsagePopoverView.greenRatioPercent, Color.green),
                                                ("hot", UsagePopoverView.hotRatioPercent, Color.red)] {
                    anchors.append((name, plate,
                                    components(of: UsagePopoverView.ratioColor(atPercent: percent,
                                                                               on: plate)),
                                    components(of: family)))
                }
            }
        }
        for anchor in anchors {
            XCTAssertEqual(anchor.ramp.hue, anchor.family.hue, accuracy: 0.001,
                           "on \(anchor.plate) the \(anchor.name) anchor is not this project's "
                           + "own colour")
        }
        // The one anchor no plate has anything to do to: the ramp's green already
        // clears the dark plate's floor, so there the colour is the family's whole
        // colour and not only its hue.
        let green = try XCTUnwrap(anchors.first { $0.name == "green" && $0.plate == .dark })
        XCTAssertEqual(green.ramp.saturation, green.family.saturation, accuracy: 0.002,
                       "the green anchor is a saturation of its own")
        XCTAssertEqual(green.ramp.brightness, green.family.brightness, accuracy: 0.002,
                       "the green anchor is a brightness of its own")
        // And what the floor leaves the two ends at, which is the price of the
        // rule written out. Each is the family's own saturation or brightness with
        // one coordinate spent.
        for (name, plate, saturation, brightness) in [("cold", UsagePopoverView.RampBackground.light,
                                                       1.0000, 0.7955),
                                                      ("hot", .light, 0.8120, 0.7451),
                                                      ("cold", .dark, 0.6383, 1.0000),
                                                      ("hot", .dark, 0.5228, 1.0000)] {
            let anchor = try XCTUnwrap(anchors.first { $0.name == name && $0.plate == plate })
            XCTAssertEqual(anchor.ramp.saturation, saturation, accuracy: 0.002,
                           "on \(plate) the \(name) anchor moved off its measured saturation")
            XCTAssertEqual(anchor.ramp.brightness, brightness, accuracy: 0.002,
                           "on \(plate) the \(name) anchor moved off its measured brightness")
        }

        // The green anchor and the one step this pair still keeps are the same boundary,
        // asked of the step (`isOverRefill`) rather than of the constant it reads: a menu
        // bar warning where the ramp is not yet green would be two boundaries.
        let anchorRatio = UsagePopoverView.HeadlineRatio(
            percent: UsagePopoverView.greenRatioPercent, isLowerBound: false)
        XCTAssertTrue(anchorRatio.isOverRefill,
                      "at the ramp's green anchor the picture is already warning")
        let justUnder = UsagePopoverView.HeadlineRatio(
            percent: UsagePopoverView.greenRatioPercent - 0.001, isLowerBound: false)
        XCTAssertFalse(justUnder.isOverRefill,
                       "a thousandth under the green anchor is still the calm picture")

        for plate in [UsagePopoverView.RampBackground.light, .dark] {
            let hues = rampSamples.map {
                components(of: UsagePopoverView.ratioColor(atPercent: $0, on: plate)).hue
            }
            assertRamp(hues, on: "the rule on \(plate)")

            // Between the anchors the hue is interpolated: cyan is where blue and green meet
            // halfway, yellow and orange where green and red do. A table of hand-picked colours
            // could pass every assertion above, so the line is asked at every load; a quarter of
            // a point of hue is visible, and the tolerance is a hundredth of that.
            let cold = components(of: UsagePopoverView.ratioColor(
                atPercent: UsagePopoverView.coldRatioPercent, on: plate))
            let green = components(of: UsagePopoverView.ratioColor(
                atPercent: UsagePopoverView.greenRatioPercent, on: plate))
            let hot = components(of: UsagePopoverView.ratioColor(
                atPercent: UsagePopoverView.hotRatioPercent, on: plate))
            for percent in stride(from: UsagePopoverView.coldRatioPercent,
                                  through: UsagePopoverView.hotRatioPercent, by: 0.5) {
                let (from, to, span) = percent <= UsagePopoverView.greenRatioPercent
                    ? (cold, green, (UsagePopoverView.coldRatioPercent,
                                     UsagePopoverView.greenRatioPercent))
                    : (green, hot, (UsagePopoverView.greenRatioPercent,
                                    UsagePopoverView.hotRatioPercent))
                let position = (percent - span.0) / (span.1 - span.0)
                XCTAssertEqual(components(of: UsagePopoverView.ratioColor(atPercent: percent,
                                                                          on: plate)).hue,
                               from.hue + (to.hue - from.hue) * position, accuracy: 0.0025,
                               "at \(percent)% on \(plate) the hue is not on the line between "
                               + "its two anchors")
            }
        }

        // The plate never moves the hue, which is what one reading on two surfaces means. It
        // moves the other two in opposite directions, so the pair is asked for the
        // invariant rather than equality.
        //
        // On the light plate the floor is met by darkening alone; desaturating the yellow
        // band into khaki would be wrong there. On the dark plate desaturation is the only
        // lever once brightness is spent, and it bites at or below 74.4% and at or above
        // 124.9% on today's anchors: the two ends and nothing between.
        for percent in stride(from: 0.0, through: 200.0, by: 2.5) {
            let light = components(of: UsagePopoverView.ratioColor(atPercent: percent, on: .light))
            let dark = components(of: UsagePopoverView.ratioColor(atPercent: percent, on: .dark))
            XCTAssertEqual(light.hue, dark.hue, accuracy: 0.001,
                           "at \(percent)% the two plates are two hues")
            XCTAssertGreaterThanOrEqual(light.saturation, 0.8,
                                        "at \(percent)% the light plate desaturated the colour "
                                        + "instead of darkening it: the ramp as written never goes "
                                        + "below 0.805 (measured over the three anchors)")
            XCTAssertLessThanOrEqual(dark.saturation, light.saturation + 0.002,
                                     "at \(percent)% the dark plate saturated the colour further "
                                     + "than the ramp asks for")
            if percent > 74.4, percent < 124.9 {
                XCTAssertEqual(dark.saturation, light.saturation, accuracy: 0.002,
                               "at \(percent)% the dark plate desaturated a colour that already "
                               + "clears its floor")
            }
        }
    }

    /// The floor itself, as a rule: on every plate every colour on the ramp reaches that
    /// plate's floor, and none is moved further than it has to be. The colour is left
    /// alone until it is illegible and then moved exactly as far as the floor, so the
    /// yellow at 115% is untouched on a dark plate and a darker yellow (not olive) on a
    /// light one.
    ///
    /// On the dark plate the adjustment lifts instead of darkening; the second half of
    /// the test checks the ends are lifted as far as needed and no further, which keeps
    /// the ramp a colour rather than a wash.
    ///
    /// The contrast is worked out here rather than borrowed from the source, so the test
    /// does not share the linearisation it is checking.
    func testTheRampMeetsItsContrastFloorOnEveryPlate() {
        for plate in [UsagePopoverView.RampBackground.light, .dark] {
            for percent in stride(from: 0.0, through: 200.0, by: 0.5) {
                let colour = UsagePopoverView.ratioColor(atPercent: percent, on: plate)
                XCTAssertGreaterThanOrEqual(contrast(of: colour, on: plate),
                                            UsagePopoverView.contrastFloor(on: plate) - 0.001,
                                            "at \(percent)% the ramp is under its floor on the "
                                            + "\(plate) plate: \(contrast(of: colour, on: plate))")
            }
        }

        // Nothing is moved that did not have to move, which is the other half of
        // the rule: the middle of the ramp is legible as written, and there the
        // drawn colour is the anchors' own brightness and saturation on the dark
        // plate. Measured at the anchors themselves, where the ramp is flat, and
        // at the green in the middle, where the two plates part company.
        for percent in [UsagePopoverView.greenRatioPercent, 110.0, 115.0, 120.0] {
            let dark = components(of: UsagePopoverView.ratioColor(atPercent: percent, on: .dark))
            let light = components(of: UsagePopoverView.ratioColor(atPercent: percent, on: .light))
            XCTAssertGreaterThan(contrast(of: UsagePopoverView.ratioColor(atPercent: percent, on: .dark),
                                          on: .dark),
                                 UsagePopoverView.contrastFloor(on: .dark) + 0.1,
                                 "at \(percent)% the dark plate had to move the colour after all, "
                                 + "so this sample proves nothing about leaving it alone")
            XCTAssertEqual(dark.saturation, light.saturation, accuracy: 0.002,
                           "at \(percent)% the dark plate desaturated a legible colour")
            XCTAssertGreaterThan(dark.brightness, light.brightness,
                                 "at \(percent)% the dark plate did not leave the colour brighter "
                                 + "than the light plate's darkened one")
        }
    }

    /// The 115% colour, named by rendering rather than by adjective. On the dark plate
    /// it is the ramp's own `rgb(0.827, 0.902, 0.173)`, a yellow with a green cast at hue
    /// 66.2 degrees; on the light plate that colour darkened to the floor,
    /// `rgb(0.381, 0.415, 0.079)`, the same hue and dark.
    ///
    /// The load the ramp turns orange at is unmoved by either plate: hue is interpolated
    /// straight from green to red, so it crosses 30 degrees at 123.61%, and the first
    /// tenth of a point at or past orange is 123.7%.
    func testWhatTheRampActuallyIsAtOneHundredAndFifteen() {
        let dark = srgb(of: UsagePopoverView.ratioColor(atPercent: 115, on: .dark))
        XCTAssertEqual(dark.red, 0.827, accuracy: 0.002)
        XCTAssertEqual(dark.green, 0.902, accuracy: 0.002)
        XCTAssertEqual(dark.blue, 0.173, accuracy: 0.002)

        let light = srgb(of: UsagePopoverView.ratioColor(atPercent: 115, on: .light))
        XCTAssertEqual(light.red, 0.381, accuracy: 0.002)
        XCTAssertEqual(light.green, 0.415, accuracy: 0.002)
        XCTAssertEqual(light.blue, 0.079, accuracy: 0.002)

        // Orange is where the hue line reaches 30 degrees, and it is one load on
        // both plates.
        for plate in [UsagePopoverView.RampBackground.light, .dark] {
            let orange = stride(from: UsagePopoverView.greenRatioPercent,
                                through: UsagePopoverView.hotRatioPercent, by: 0.1)
                .first { components(of: UsagePopoverView.ratioColor(atPercent: $0, on: plate)).hue
                    <= 30.0 / 360 }
            XCTAssertEqual(orange ?? -1, 123.7, accuracy: 0.05,
                           "orange moved off 123.7% on \(plate)")
        }
    }

    /// The contrast a colour the rule handed out has against the plate it was
    /// asked for.
    private func contrast(of colour: Color, on background: UsagePopoverView.RampBackground) -> Double {
        wcagContrast(srgb(of: colour), against: background.grey)
    }

    private func srgb(of colour: Color) -> (red: Double, green: Double, blue: Double) {
        guard let converted = NSColor(colour).usingColorSpace(.sRGB) else { return (-1, -1, -1) }
        return (Double(converted.redComponent),
                Double(converted.greenComponent),
                Double(converted.blueComponent))
    }

    /// A colour as the ramp's own arithmetic states it.
    private func components(of colour: Color) -> (hue: Double, saturation: Double, brightness: Double) {
        guard let srgb = NSColor(colour).usingColorSpace(.sRGB) else { return (-1, -1, -1) }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return (Double(hue), Double(saturation), Double(brightness))
    }

    private func luminance(of colour: Color) -> Double {
        guard let srgb = NSColor(colour).usingColorSpace(.sRGB) else { return -1 }
        return 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent
    }

    /// The internal word for this metric appears in no string a person reads (§4).
    /// Asked of the strings on the list below, which is every string these two surfaces
    /// write themselves.
    ///
    /// The list is built by hand because it cannot be built otherwise: `some View` is
    /// opaque and `ImageRenderer` returns pixels. So the functions the views call are
    /// swept, and the view-to-function wire is held by reading, as with
    /// `switchAppearance`. Hence a new string is covered only once added here, and only
    /// if it lives in a named function rather than as a literal in a `@ViewBuilder`.
    ///
    /// Not swept: text this app did not write (`switchNote`'s `disabled_reason`,
    /// `switchBlame`'s transport failures, `failureText`'s). Each is swept for the frame
    /// around it (`off`, separators, `as of`). The switch answer's `warning` is decoded
    /// and dropped (`SwitchResult.warning`), and account labels are the operator's. The
    /// `5h` and `7d` of `windowRow`'s titles stay as literals: a digit and a unit cannot
    /// hold a word.
    ///
    /// Two frames are built in `UsageHistoryModel` (`"status: \(error)"` and
    /// `"\(label): \(error)"`), so they are produced below by running a refusing client
    /// through `load` and `switchAccount` rather than typed as literals.
    func testNoStringOnScreenNamesTheMetricByItsInternalWord() async {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        var strings = [UsagePopoverView.headlineCaption,
                       UsagePopoverView.ratioCaption,
                       // The third caption of the headline, and it was outside this
                       // sweep while its two neighbours were in it.
                       UsagePopoverView.spendRateCaption,
                       UsagePopoverView.ratioLabel(for: ratio(126, lowerBound: true)),
                       UsagePopoverView.ratioLabel(for: ratio(126))]
        strings.append(MenuBarIcon.describe(ratio(126)))
        strings.append(MenuBarIcon.describe(nil))
        strings.append(UsagePopoverView.switchHelp(nil))
        strings.append(UsagePopoverView.switchHelp(try? Self.rotationState()))
        strings.append(UsagePopoverView.switchHelp(try? Self.rotationState(disabled: true)))
        // What the checkbox is called with no eyes on it — as much a string on
        // screen as the ones with pixels, and §4 draws no line between them.
        strings.append(UsagePopoverView.switchAccessibilityLabel("acc2"))
        // The note beside a switched-off account's name, in all three of its
        // shapes. The reason in the third is the gateway's word and is here to be
        // carried rather than to be judged: what is asked is the frame around it.
        if let off = try? Self.rotationState(disabled: true) {
            strings.append(UsagePopoverView.switchNote(off, now: now))
        }
        if let timed = try? Self.rotationState(disabled: true, until: 1_786_803_600) {
            strings.append(UsagePopoverView.switchNote(timed, now: now))
        }
        if let blamed = try? Self.rotationState(disabled: true, reason: "quota cool-down") {
            strings.append(UsagePopoverView.switchNote(blamed, now: now))
        }
        // Every click that would not go through, joined. The failures themselves
        // are `UsageError` descriptions, which this app does write.
        strings.append(UsagePopoverView.switchBlame(["acc2": "acc2: HTTP 500",
                                                     "main": "main: unreachable: timed out"]) ?? "")
        // The token-health note in both of its states, text and tooltip; the gateway's
        // `auth_error` is left empty so only this app's wording is swept.
        for state in ["needs_manual_token", "refresh_backoff"] {
            let note = UsagePopoverView.authNote(AccountAuth(state: state, error: ""))
            XCTAssertNotNil(note, "\(state) drew no note, so the sweep covered nothing")
            strings.append(note?.text ?? "")
            strings.append(note?.help ?? "")
        }
        // The orange line: `applyRoutable` writes this string and nothing else. The
        // gateway's own sentence is decoded and dropped (`SwitchResult.warning`).
        strings.append(UsageHistoryModel.noRouteWarning)
        // The two sections that can be empty, in all three states each: not asked
        // yet, asked and refused, asked and answered with nothing.
        var landed = UsageSnapshot.empty
        landed.quotaFetchedAt = now
        var failed = UsageSnapshot.empty
        failed.quotaFailure = "/gw/usage: HTTP 500"
        for snapshot in [UsageSnapshot.empty, landed, failed] {
            strings.append(UsagePopoverView.accountsEmptyLabel(snapshot))
            strings.append(UsagePopoverView.plotEmptyLabel(snapshot: snapshot,
                                                           seriesFetchedAt: nil,
                                                           seriesPeriod: nil,
                                                           period: .day,
                                                           historyFailure: nil))
        }
        // The lead figure and its supporting readings, with and without a number
        // to print.
        strings.append(UsagePopoverView.headlineFigureLabel(for: .empty, now: now))
        strings.append(UsagePopoverView.headlineFigureLabel(for: landed, now: now))
        strings.append(UsagePopoverView.quotaLabel(for: .empty))
        strings.append(UsagePopoverView.rateLabel(3_400_000))
        strings.append(UsagePopoverView.rateLabel(0))
        strings.append(UsagePopoverView.percentLabel(58.667))
        strings.append(UsagePopoverView.percentLabel(nil))
        // Both shapes of the popover's one countdown, and the tab titles above the
        // chart — `CaseIterable`, so this half of the sweep is the one part of it
        // that cannot fall behind.
        strings.append(UsagePopoverView.resetLabel(now.addingTimeInterval(5400), now: now))
        strings.append(UsagePopoverView.resetLabel(now, now: now))
        strings.append(contentsOf: HistoryPeriod.allCases.map(\.title))
        // The footer: the age line in each of its units, and the reasons under it.
        for seconds in [30.0, 600.0, 7200.0, 200_000.0] {
            strings.append(UsagePopoverView.ago(now.addingTimeInterval(-seconds), now: now))
        }
        strings.append(UsagePopoverView.footerAgeLabel(quotaFetchedAt: now.addingTimeInterval(-600),
                                                       quotaFailed: false,
                                                       chartFetchedAt: now.addingTimeInterval(-600),
                                                       seriesPeriod: .day,
                                                       period: .day,
                                                       chartFailed: false,
                                                       historiesFailed: false,
                                                       now: now) ?? "")
        strings.append(UsagePopoverView.failureText(quota: "/gw/usage: HTTP 500",
                                                    chart: "/gw/usage/main/history: HTTP 500",
                                                    histories: "/gw/usage/acc2/history: HTTP 500") ?? "")
        // The two frames the model writes, produced by the model. A refusing
        // client gives the rotation's blame (`status: …`), the histories' blame
        // and a click's blame in one go; what is swept is the frame — the word in
        // front of the colon and the colon — because the reason inside it is a
        // `UsageError` description, which this app does write and which the entries
        // above already cover.
        let refusing = UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { _ in
            throw UsageError.unreachable("nothing is listening")
        }
        let refused = await UsageHistoryModel.load(client: refusing, labels: ["acc2"],
                                                   since: now.addingTimeInterval(-86_400))
        let refusedRotation = await UsageHistoryModel.fetchRotation(client: refusing)
        let refusedClick = await UsageHistoryModel.switchAccount(client: refusing, label: "acc2",
                                                                 enabled: false)
        // Without this the three below could be `nil`, and a sweep over three
        // empty strings reads as covered while covering nothing.
        XCTAssertNotNil(refusedRotation.failure, "the refusing client answered the rotation")
        XCTAssertNotNil(refused.failure, "the refusing client answered a history")
        XCTAssertNotNil(refusedClick.failure, "the refusing client answered the click")
        strings.append(refusedRotation.failure ?? "")
        strings.append(refused.failure ?? "")
        strings.append(refusedClick.failure ?? "")
        for text in strings {
            XCTAssertFalse(text.lowercased().contains("fleet"),
                           "\"\(text)\" says \"fleet\" to somebody who does not work on this app")
        }
    }

    /// The reset time always names its smallest unit, and never leaves a floor standing
    /// on its own. A bare unit is a range: `in 1d` covers 24 to 48 hours, `in 1h` 60 to
    /// 119 minutes. So the lower unit is printed beside the higher one, even when zero.
    func testTheResetTimeAlwaysNamesItsSmallestUnit() {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        func label(_ seconds: TimeInterval) -> String {
            UsagePopoverView.resetLabel(now.addingTimeInterval(seconds), now: now)
        }
        XCTAssertEqual(label(15 * 60), "in 15m")
        // Minutes round up: half a minute left is not "in 0m".
        XCTAssertEqual(label(30), "in 1m")
        XCTAssertEqual(label(3539), "in 59m")
        // Where the two rounding rules meet. The minutes round up to 60 of them
        // here, and `in 60m` is an hour written the long way — while the branch
        // below floors and would write `in 0h 59m` for the same instant.
        XCTAssertEqual(label(3599), "in 1h 0m", "the last minute below an hour stayed 60 minutes")
        XCTAssertEqual(label(3541), "in 1h 0m")
        // The carry stops one second short of that, and the seam is arithmetic
        // rather than a choice: 3540 s *is* fifty-nine minutes, and rounding an
        // exact figure up leaves it where it is.
        XCTAssertEqual(label(3540), "in 59m", "the carry took a minute that was already exact")
        XCTAssertEqual(label(3600), "in 1h 0m")
        XCTAssertEqual(label(5400), "in 1h 30m")
        XCTAssertEqual(label(4 * 3600), "in 4h 0m")
        // The remainder floors like everything above it: this is a countdown, and
        // 3h 59m 59s has turned neither into four hours nor into `in 3h 60m`.
        XCTAssertEqual(label(3 * 3600 + 59 * 60 + 59), "in 3h 59m")
        XCTAssertEqual(label(86_399), "in 23h 59m")
        XCTAssertEqual(label(86_400), "in 1d 0h")
        XCTAssertEqual(label(123_456), "in 1d 10h")
        XCTAssertEqual(label(3 * 86_400 + 7 * 3600), "in 3d 7h")
        XCTAssertEqual(label(5 * 86_400 + 20 * 60), "in 5d 0h",
                       "a whole number of days dropped the hours and became ambiguous again")
        XCTAssertEqual(label(86_400 + 23 * 3600 + 59 * 60), "in 1d 23h",
                       "the last hour before two days was rounded up into them")
        XCTAssertEqual(label(0), "resets now")
        XCTAssertEqual(label(-60), "resets now")
        XCTAssertEqual(UsagePopoverView.resetLabel(nil, now: now), "")
    }

    /// One account's switch, built the only way there is: `AccountSwitch` only decodes,
    /// so a state in a test is a gateway body.
    ///
    /// `eligible` is written into every body although this type has no field for it: it
    /// is the field next door, where the gateway folds a quota cool-down and a token
    /// backoff, and a fixture without it cannot tell a reader of `disabled` from a reader
    /// of `eligible`. It defaults to the opposite of `disabled`;
    /// `rotationState(eligible: false)` is the case where they disagree.
    static func rotationState(disabled: Bool = false,
                              eligible: Bool? = nil,
                              until: Int? = nil,
                              reason: String = "") throws -> AccountSwitch {
        try UsageFixtures.decode("""
            {"label": "acc2", "disabled": \(disabled), "eligible": \(eligible ?? !disabled), \
            "disabled_until": \(until.map(String.init) ?? "null"), \
            "disabled_reason": "\(reason)"}
            """, as: AccountSwitch.self)
    }

    /// The note beside a switched-off account's name says the two things the gateway can
    /// add to "off", and nothing where there is nothing to say. The deadline is drawn,
    /// never set: this app's switch sends no body ("until somebody puts it back"), so a
    /// deadline came from the command line or a gateway rule. It tells an account that
    /// comes back by itself from one that waits for a person.
    ///
    /// Written by `resetLabel`, the popover's one countdown, and in brackets because the
    /// bare shape (`resets now`) would run into the word before it.
    func testASwitchedOffAccountNamesItsDeadlineAndItsReason() throws {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        func note(_ state: AccountSwitch) -> String { UsagePopoverView.switchNote(state, now: now) }

        XCTAssertEqual(note(try Self.rotationState(disabled: true)), "off",
                       "off until somebody comes back, which is all this app can ask for")
        XCTAssertEqual(note(try Self.rotationState(disabled: true,
                                                   until: 1_786_800_000 + 5 * 86_400 + 20 * 60)),
                       "off (in 5d 0h)")
        XCTAssertEqual(note(try Self.rotationState(disabled: true, reason: "rate limited")),
                       "off · rate limited")
        XCTAssertEqual(note(try Self.rotationState(disabled: true,
                                                   until: 1_786_800_000 + 3600,
                                                   reason: "rate limited")),
                       "off (in 1h 0m) · rate limited")
        XCTAssertEqual(note(try Self.rotationState(disabled: true, until: 1_786_799_000)),
                       "off (resets now)",
                       "a deadline already past reads as one word and needs its brackets most")
    }

    /// And the switch may not claim a state nobody reported.
    ///
    /// Three states rather than two: with no answer from `/gw/status` the box is
    /// clear and inert, and its tooltip has to say that rather than offer to do
    /// the thing the box cannot do. The other two name the *action*, because the
    /// state is what the box itself is drawing.
    func testTheSwitchSaysWhichWayItWouldGoAndAdmitsWhenItCannotSay() throws {
        XCTAssertEqual(UsagePopoverView.switchHelp(nil),
                       "The gateway did not say whether this account is in rotation")
        XCTAssertEqual(UsagePopoverView.switchHelp(try Self.rotationState()),
                       "Take this account out of the gateway rotation")
        XCTAssertEqual(UsagePopoverView.switchHelp(try Self.rotationState(disabled: true)),
                       "Put this account back into the gateway rotation")
        // An account nobody switched off that the gateway will not route to: the
        // switch on offer is still the operator's own, because that is the only
        // one a click here can throw.
        XCTAssertEqual(UsagePopoverView.switchHelp(try Self.rotationState(eligible: false)),
                       "Take this account out of the gateway rotation")
    }

    /// Every click that would not go through, on one line, ordered by label.
    ///
    /// Two accounts can each be carrying their own bad news, and the order has to
    /// come from the labels rather than from a dictionary: a line that reshuffles
    /// itself under the pointer as a second answer lands is a line nobody finishes
    /// reading. Nothing to say is `nil` and not an empty line.
    func testEveryClickThatWouldNotGoThroughIsOnOneLineInLabelOrder() {
        XCTAssertNil(UsagePopoverView.switchBlame([:]))
        XCTAssertEqual(UsagePopoverView.switchBlame(["acc2": "acc2: down"]), "acc2: down")
        XCTAssertEqual(UsagePopoverView.switchBlame(["main": "main: down", "acc2": "acc2: refused"]),
                       "acc2: refused; main: down")
    }

    /// The box itself draws those same three states: unknown is not "in the rotation",
    /// and a box this app cannot fill in cannot be clicked. Asked of the function because
    /// `ImageRenderer` draws this checkbox as a blank plate, the same 784 inked pixels in
    /// every state. What is held by reading rather than a test is the one line that wires
    /// the view to this function.
    func testTheBoxIsClearUntilTheGatewaySaysOtherwiseAndInertUntilItAnswersAtAll() throws {
        func look(_ state: AccountSwitch?, busy: Bool = false) -> (ticked: Bool, usable: Bool) {
            UsagePopoverView.switchAppearance(state, busy: busy)
        }

        XCTAssertFalse(look(nil).ticked,
                       "a tick means \"in the rotation\", and nobody said that")
        XCTAssertFalse(look(nil).usable,
                       "a box that cannot say what it shows must not send anything either")

        XCTAssertTrue(look(try Self.rotationState()).ticked)
        XCTAssertTrue(look(try Self.rotationState()).usable)
        XCTAssertFalse(look(try Self.rotationState(disabled: true)).ticked)
        XCTAssertTrue(look(try Self.rotationState(disabled: true)).usable,
                      "switched off is a state to click out of, not a reason to freeze")

        // A live shape: nobody switched `main` off and the gateway still will not route to
        // it. The box follows the operator's switch, the thing a click can change; bound to
        // `eligible` it would clear when a quota window filled and then send an `enable`
        // that changes nothing. The only shape in which the two flags disagree.
        XCTAssertTrue(look(try Self.rotationState(eligible: false)).ticked,
                      "a quota cool-down was drawn as an operator having switched the account off")
        XCTAssertTrue(look(try Self.rotationState(eligible: false)).usable,
                      "and the one switch an operator could still throw was taken away from them")

        XCTAssertFalse(look(try Self.rotationState(), busy: true).usable,
                       "a switch already in the air takes no second click")
        XCTAssertTrue(look(try Self.rotationState(), busy: true).ticked,
                      "in flight the box keeps showing the state the gateway last confirmed")
        XCTAssertFalse(look(nil, busy: true).usable)
    }

    /// No input writes a floor on its own, an overflowed unit, or a leading zero: swept
    /// second by second from the reset out to two hours, then in 61-second steps out to
    /// forty days.
    ///
    /// The dense window holds the seams (`resets now`, minutes alone, the carry into
    /// `in 1h 0m`, the first hour both ways) and starts at zero so `resets now` is
    /// reached. Past two hours nothing changes shape until the day, so a coarse step
    /// suffices; 61 rather than 60 so it does not keep landing on one minute boundary.
    /// The assertions above cover the known seams; this sweep checks the shape
    /// everywhere else.
    func testNoResetTimeIsAFloorOnItsOwn() {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        // The label with every figure replaced by `N`: `in 1h 5m` and `in 400h 5m`
        // are one shape, and the shape is what the rule is about.
        func shape(_ label: String) -> String {
            label.split(separator: " ")
                .map { $0.first?.isNumber == true ? "N" + $0.drop(while: \.isNumber) : String($0) }
                .joined(separator: " ")
        }
        func figures(_ label: String) -> [Int] {
            label.split(separator: " ").compactMap { Int($0.prefix(while: \.isNumber)) }
        }
        var wrong: [String] = []
        func check(_ seconds: TimeInterval) {
            let label = UsagePopoverView.resetLabel(now.addingTimeInterval(seconds), now: now)
            let numbers = figures(label)
            let ok: Bool
            switch shape(label) {
            // Reached because the sweep starts at the reset itself: `resetLabel`
            // writes this for anything that is not still ahead.
            case "resets now": ok = numbers.isEmpty
            // Minutes on their own are the one place a bare unit is not a floor:
            // there is nothing below them to be floored away.
            case "in Nm": ok = numbers.count == 1 && (1...59).contains(numbers[0])
            case "in Nh Nm": ok = numbers.count == 2 && (1...23).contains(numbers[0])
                && (0...59).contains(numbers[1])
            case "in Nd Nh": ok = numbers.count == 2 && numbers[0] >= 1
                && (0...23).contains(numbers[1])
            default: ok = false
            }
            if !ok { wrong.append("\(Int(seconds)) s → \"\(label)\"") }
        }
        for seconds in 0...7200 { check(TimeInterval(seconds)) }
        for seconds in stride(from: 7200, through: 40 * 86_400, by: 61) {
            check(TimeInterval(seconds))
        }
        XCTAssertEqual(wrong.count, 0,
                       "\(wrong.count) inputs wrote a unit that is a floor, an overflow or a "
                       + "leading zero, first of them \(wrong.prefix(3).joined(separator: ", "))")
    }

    /// What `resetLabel` writes is drawn whole in its slot. Measured, because a truncated
    /// `in 5d 0h` reads an hour count as a day count. Two renderings of the same string,
    /// one in the row's slot and one unconstrained: equal ink means nothing was cut.
    ///
    /// `resetLabel` prints as many days as the gateway names, so the last probe is a
    /// reset 56 years out. `in 23h 59m` and `in 20h 44m` are both listed because the
    /// label has no `monospacedDigit`: over all 1380 strings of that shape the widest is
    /// `in 20h 44m` at 53.75 pt, against `in 23h 59m`'s 53.25.
    func testTheResetTimeFitsItsSlotWhole() throws {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        XCTAssertEqual(UsagePopoverView.resetLabel(now.addingTimeInterval(1_786_800_000), now: now),
                       "in 20680d 13h",
                       "the days are capped somewhere after all")
        for string in ["in 20h 44m", "in 23h 59m", "in 30d 23h", "resets now", "in 5d 0h",
                       "in 15m", "in 20680d 13h"] {
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
                                            historiesFailed: false,
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
                                            historiesFailed: false,
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
        func label(quotaFailed: Bool, chartFailed: Bool, historiesFailed: Bool = false) -> String? {
            UsagePopoverView.footerAgeLabel(quotaFetchedAt: now.addingTimeInterval(-30),
                                            quotaFailed: quotaFailed,
                                            chartFetchedAt: now.addingTimeInterval(-30),
                                            seriesPeriod: .day,
                                            period: .day,
                                            chartFailed: chartFailed,
                                            historiesFailed: historiesFailed,
                                            now: now)
        }
        XCTAssertNil(label(quotaFailed: false, chartFailed: false))
        XCTAssertEqual(label(quotaFailed: true, chartFailed: false), "as of less than a minute ago")
        XCTAssertEqual(label(quotaFailed: false, chartFailed: true), "as of less than a minute ago")
        XCTAssertEqual(label(quotaFailed: false, chartFailed: false, historiesFailed: true),
                       "as of less than a minute ago",
                       "one of the three halves went quiet and the footer said nothing at all")
    }

    /// The burn ratio is never dated by this footer, and the age it prints is the age of
    /// what is drawn. A ratio older than `historyStaleSeconds` is not shown
    /// (`historiesAreFresh`), so there is never a ratio on screen to date.
    ///
    /// The failure still breaks the silence, over the halves that are drawn, which the
    /// second half of this test holds.
    func testTheFooterDatesWhatIsDrawnAndTheRatioIsNotIt() {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        func label(quota: TimeInterval, historiesFailed: Bool = false) -> String? {
            UsagePopoverView.footerAgeLabel(quotaFetchedAt: now.addingTimeInterval(-quota),
                                            quotaFailed: false,
                                            chartFetchedAt: now.addingTimeInterval(-quota),
                                            seriesPeriod: .day,
                                            period: .day,
                                            chartFailed: false,
                                            historiesFailed: historiesFailed,
                                            now: now)
        }
        // The histories half has been failing for two hours, the quota and the chart are
        // 20 s old, and those are the only figures on screen.
        XCTAssertEqual(label(quota: 20, historiesFailed: true), "as of less than a minute ago",
                       "the footer dated the screen by a figure the same failure had removed")
        // The stale-quota case is untouched: the age of a screen is the age of
        // the oldest thing on it.
        XCTAssertEqual(label(quota: 3600, historiesFailed: true), "as of 1h ago")
        XCTAssertEqual(label(quota: 3600), "as of 1h ago")
        XCTAssertNil(label(quota: 20))
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

    /// The weekly quota is this surface's alone, rounded in one place
    /// (`UsageSnapshot.fleetSevenDayPercent`). The popover keeps a stale quota because
    /// the footer gives its age and the account rows below keep showing their stored
    /// percentages; a dash over live numbers would be the false statement.
    func testTheWeeklyQuotaIsThisSurfacesAloneAndSurvivesAFailedPass() throws {
        var snapshot = UsageSnapshot.empty
        snapshot.fleetSevenDayMean = 58.667
        XCTAssertEqual(snapshot.fleetSevenDayPercent, 59)
        XCTAssertEqual(UsagePopoverView.headlinePercent(for: snapshot), 59)
        XCTAssertEqual(UsagePopoverView.percentLabel(snapshot.fleetSevenDayMean), "59%")

        // Kept when the pass that brings it fails, and dated by the footer.
        snapshot.quotaFailure = "/gw/usage: unreachable"
        XCTAssertEqual(UsagePopoverView.headlinePercent(for: snapshot), 59,
                       "the headline blanked a reading it has, over rows that are showing it")

        // And the menu bar has nothing to draw from this snapshot at all: the
        // quota is not a figure it falls back to.
        XCTAssertNil(MenuBarIcon.ratio(for: snapshot))

        // A reading nobody ever took is a dash.
        XCTAssertNil(UsagePopoverView.headlinePercent(for: .empty))
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
        XCTAssertNil(UsagePopoverView.failureText(quota: nil, chart: nil, histories: nil))
        XCTAssertEqual(UsagePopoverView.failureText(quota: "/gw/usage: HTTP 500",
                                                    chart: nil, histories: nil),
                       "/gw/usage: HTTP 500")
        XCTAssertEqual(UsagePopoverView.failureText(quota: nil, chart: "acc2: unreachable",
                                                    histories: nil),
                       "acc2: unreachable")
        // The third half, and the one this footer was silent about: its figure
        // is the biggest thing on the surface, so the same test that keeps
        // `/gw/sessions` out is what puts this one in.
        XCTAssertEqual(UsagePopoverView.failureText(quota: nil, chart: nil,
                                                    histories: "/gw/usage/<label>/chart: HTTP 500"),
                       "/gw/usage/<label>/chart: HTTP 500",
                       "the headline stated a figure whose endpoint was failing, unexplained")
        XCTAssertEqual(UsagePopoverView.failureText(quota: "/gw/usage: HTTP 500",
                                                    chart: "acc2: unreachable",
                                                    histories: "/gw/usage/<label>/chart: HTTP 500"),
                       "/gw/usage: HTTP 500; acc2: unreachable; /gw/usage/<label>/chart: HTTP 500",
                       "one reason stood in for the others")

        // The endpoint this view has no figure from is not in it at all — while
        // the snapshot's own line, which the dump prints, still carries it.
        var snapshot = UsageSnapshot.empty
        snapshot.sessionsFailure = "/gw/sessions: HTTP 502"
        XCTAssertEqual(snapshot.failureText, "/gw/sessions: HTTP 502")
        XCTAssertNil(UsagePopoverView.failureText(quota: snapshot.quotaFailure,
                                                  chart: nil,
                                                  histories: snapshot.historiesFailure))
    }

}

/// The popover as pixels. Three of its rules are about colour and about what is drawn
/// at all (the colour scale, dots keyed off the poll's list, the footer's divider),
/// and no pure function can be asked any of them.
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

        /// The straight colour and coverage at a pixel — what `colour` reads
        /// before it throws the components away for a hue. Wanted whole by the
        /// legibility measurement, which has to composite the pixel onto the
        /// plate the popover really sits on before it can say how it reads.
        func straight(_ x: Int, _ y: Int) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
            let base = (y * width + x) * 4
            let alpha = Double(bytes[base + 3]) / 255
            guard alpha > 0.05 else { return nil }
            return (Double(bytes[base]) / 255 / alpha,
                    Double(bytes[base + 1]) / 255 / alpha,
                    Double(bytes[base + 2]) / 255 / alpha,
                    alpha)
        }

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

    /// Whether a patch is exactly the size of a frame the view asked for. The size comes
    /// from the view's own constant, not a copy, so changing the dot size does not fail
    /// the colour tests with "drew 0 dots". Plain equality works because a whole number
    /// of points is a whole number of pixels at this scale (16 for 8, 14 for 7); a
    /// fractional size would need slack.
    private func isSized(_ blob: Blob, _ size: CGSize, in canvas: Canvas) -> Bool {
        Double(blob.width) == Double(size.width) * canvas.scale
            && Double(blob.height) == Double(size.height) * canvas.scale
    }

    /// The account dots, in drawing order. Found as patches rather than at coordinates
    /// from the layout: a dot is a `Circle` of `accountDotSize` points at full strength,
    /// and nothing else is both. The only other opaque colour is the segmented picker's
    /// background, one 292 by 22 point patch, excluded by size.
    private func dots(in canvas: Canvas) -> [Blob] {
        let side = UsagePopoverView.accountDotSize
        return blobs(in: canvas) { isChromatic($0) && $0.alpha > 0.9 }
            .filter { isSized($0, CGSize(width: side, height: side), in: canvas) }
            .sorted { $0.box.minY < $1.box.minY }
    }

    /// The hues the account lines are drawn in, one per line. Read only inside the
    /// chart's rows: outside the plot the popover draws other hues, including the
    /// footer's orange warning symbol (drawn exactly when an account failed its history
    /// request, a fixture below) and the rims of the quota bars. Inside the band the
    /// lines are alone.
    ///
    /// The upper bound on alpha excludes the segmented picker's background, which is
    /// inside these rows, opaque and chromatic; an account line carries `accountOpacity`
    /// and cannot reach that band.
    ///
    /// Hues are grouped by proximity, not a fixed grid: one line's antialiased pixels
    /// spread by under 0.01 while the palette's hues are 0.2 apart, so a grid boundary
    /// inside that spread would report one line as two. What is left is thresholded by
    /// area, a line being thousands of pixels against a stray edge's few.
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

    /// The rules across the popover, top to bottom, as rows of the bitmap. A `Divider`
    /// is the only thing one point tall running from padding edge to padding edge, so it
    /// is measured against the content width, not the picture's; against the picture the
    /// threshold would sit close to the working point and move with the inset.
    ///
    /// Against the content a rule is 1.000 whatever the inset, and the thresholds sit
    /// between the figures: the headline bar is also 1.000 but 8 pt tall, the segmented
    /// picker 22, and the grid lines start after the y axis labels (0.918…0.949 of the
    /// content). The closest to 0.98 is that bar's end row (0.976 at `width` 240), inside
    /// an 8 pt run, so the height filter excludes it.
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

    /// A landed quota poll naming these accounts, with no reading for either window. A
    /// known utilisation fills the row's `QuotaBar` in green, orange or red, three more
    /// hues in a picture about which hue went where; an unknown one leaves the bar as its
    /// 12% track. The headline likewise shows a dash over an empty track, so every colour
    /// left belongs to a dot or a line.
    private func snapshot(labels: [String], fetched: Date = Date()) throws -> UsageSnapshot {
        let body = labels.map {
            "\"\($0)\": {\"five_hour\": {\"known\": false}, \"seven_day\": {\"known\": false}}"
        }
        let report = try UsageFixtures.decode("{\"accounts\": {\(body.joined(separator: ","))}}",
                                              as: UsageReport.self)
        var value = UsageSnapshot.empty
        value.accounts = report.accounts
        value.quotaFetchedAt = fetched
        // The histories half of the same landed pass. The arrival stamp has to be
        // as old as the poll, because that stamp is half of what decides whether
        // the lead block is drawn at all
        // (`UsagePopoverView.historiesAreFresh`). Without it a test that sets a
        // spend rate would be rendering the fallback picture and measuring the
        // wrong thing.
        value.historiesFetchedAt = fetched
        // The lead reading needs the ratio and the stamp above, and it is seeded
        // here so that a test asking about the lead block gets one — without it
        // the rendering is the fallback, which is the trap the stamp already
        // documents.
        value.fleetBurn = UsagePopoverLabelTests.burn(Self.leadPercent)
        // The third reading of the block, which is not part of the lead at all:
        // no bar, no colour, and its absence would cost the block one reading
        // rather than sending it back to the fallback.
        value.fleetTokenRate = Self.currentRate
        return value
    }

    /// What the lead states in every rendering here: a live burn against refill, which
    /// the surface writes `113%` over `of the weekly refill rate`.
    private static let leadPercent = 112.8
    /// And the supporting rate under it: `23.8M/h`.
    private static let currentRate = 23_800_000.0

    /// A store whose quota poll has already landed, naming these accounts. Seeded through
    /// the cache, where a store takes its first published value from. `UsageStore.apply`
    /// stays private: it releases the `pollInFlight` latch, so an outside caller could
    /// let two passes run at once. The only other route is a live gateway.
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
                         rotation: String = quietRotation,
                         fetched: Date = Date()) async throws -> (UsagePopoverView, UsageStore, UsageHistoryModel) {
        let history = UsageHistoryModel(client: flatHistoryClient(readings: readings,
                                                                  silentOnUnknown: true,
                                                                  rotation: rotation),
                                        defaults: freshDefaults())
        let store = try store(named: named, fetched: fetched)
        history.open(labels: asked)
        await history.fetchTask?.value
        return (UsagePopoverView(usage: store, history: history), store, history)
    }

    // MARK: - The headline's caption on one line

    /// The caption under the big figure is drawn on one line, whatever the figure says.
    /// Beside the figure it fitted only while the figure was short (205.5 pt of ink on a
    /// 292 pt line; `100%` leaves 199.5), so it sits on its own row.
    ///
    /// Measured like the reset slot (§4): the same string drawn alone and in place. The
    /// top of the popover is three lines of ink (figure, caption, bar), and the middle
    /// one must be as wide as the free caption. The position matters: with the caption
    /// back beside the figure, at 100% the figure plus the first wrapped line happen to
    /// form one band of exactly 205.50 pt, so only asking "is there a band this wide"
    /// would pass. Asked over the widest figure and over none.
    func testTheHeadlineCaptionIsDrawnOnOneLine() async throws {
        let content = Double(UsagePopoverView.width - 2 * UsagePopoverView.padding)

        // Both captions, and under the lead's the widest figure it can stand
        // over. The lead's caption is a fixed string of its own length, so what
        // is varied under it is the figure: `≥9999%` is the widest reading a
        // fleet in real trouble writes, and a caption that fitted under `113%`
        // proves nothing about the row that has to hold both.
        let cases: [(caption: String, mean: Double?, ratio: Double?)] = [
            (UsagePopoverView.headlineCaption, nil, nil),
            (UsagePopoverView.headlineCaption, 100, nil),
            (UsagePopoverView.ratioCaption, 100, 112.8),
            (UsagePopoverView.ratioCaption, 100, 9999),
        ]

        for (text, mean, ratio) in cases {
            let alone = inkBands(in: try canvas(Text(text)
                .font(.system(size: UsagePopoverView.headlineCaptionSize))))
            XCTAssertEqual(alone.count, 1, "the caption \"\(text)\" drew \(alone.count) lines on its own")
            let whole = try XCTUnwrap(alone.first)

            var snapshot = try snapshot(labels: ["acc1"])
            snapshot.fleetSevenDayMean = mean
            // A ratio in the case is the lead reading; no ratio is the fallback,
            // where the quota takes the big figure back and the caption with it.
            snapshot.fleetBurn = ratio.map { UsagePopoverLabelTests.burn($0, lowerBound: $0 > 1000) }
            let cache = UsageCache()
            cache.store(snapshot)
            let history = UsageHistoryModel(client: flatHistoryClient(readings: ["acc1": 90],
                                                                     silentOnUnknown: true),
                                           defaults: freshDefaults())
            history.open(labels: ["acc1"])
            await history.fetchTask?.value
            defer { history.close() }
            let view = UsagePopoverView(usage: UsageStore(config: .default, cache: cache),
                                        history: history)
            // The top three bands and no further: the rule below the bar is a
            // full-width line too, and the account names under that are text. Counted
            // rather than cut off at a height, because a height has headroom in one
            // direction only — the bar ends at 79 pt, so an 80 pt window leaves 1 pt
            // above it, and anything drawn a little taller fails this test in a place
            // it is not looking (at a 36 pt figure the cut clipped the bar's rounded
            // end and the third band came out 289.00 pt instead of 292.00).
            let bands = Array(inkBands(in: try canvas(view)).prefix(3))
            let widths = bands.map { String(format: "%.2f", $0) }.joined(separator: ", ")
            let drawn = UsagePopoverView.headlineFigureLabel(for: snapshot)
            XCTAssertEqual(bands.count, 3,
                           "with the figure at \(drawn) the top of the popover is \(bands.count) "
                           + "lines of ink (\(widths) pt wide) rather than figure, caption and bar")
            guard bands.count == 3 else { continue }
            XCTAssertEqual(bands[1], whole, accuracy: 0.5,
                           "with the figure at \(drawn) the line under it is \(bands[1]) pt wide "
                           + "against the caption \"\(text)\" at \(whole): it was wrapped, cut, or "
                           + "is not that caption at all (lines \(widths))")
            XCTAssertEqual(bands[2], content, accuracy: 0.5,
                           "the third line is \(bands[2]) pt wide, not the bar's \(content): the "
                           + "three lines measured are not the ones named (lines \(widths))")
        }
    }

    /// The lead bar is the ramp, drawn: cold blue below 70, green at capacity, red at 130
    /// and nothing new past it. Read back off the drawing on the popover, the dark
    /// surface with room to read a scale.
    ///
    /// The bar is found by height alone: the largest opaque patch is the segmented
    /// picker at 292 by 22 points and the dots are 7 by 7; only one thing is exactly
    /// `headlineBarHeight` tall (the supporting bar is `supportingBarHeight`, and empty
    /// here). Loads a thousandth of a point either side of 100 are one colour to three
    /// decimals of hue, asserted because a step would fail it.
    func testTheHeadlineBarIsARampAndNotAStep() async throws {
        var drawn: [Double] = []
        for percent in rampSamples {
            let hue = try await headlineBarHue(ratioPercent: percent)
            XCTAssertEqual(hue,
                           self.hue(of: UsagePopoverView.ratioColor(atPercent: percent,
                                                                   on: .light)),
                           accuracy: 0.01,
                           "at \(percent)% the popover drew a hue of its own rather than the ramp's")
            drawn.append(hue)
        }
        assertRamp(drawn, on: "the popover")

        // Either side of capacity is one colour.
        let boundary = UsagePopoverView.greenRatioPercent
        let under = try await headlineBarHue(ratioPercent: boundary - 0.001)
        let at = try await headlineBarHue(ratioPercent: boundary)
        XCTAssertEqual(under, at, accuracy: 0.001, "the bar still steps at capacity")
    }

    /// The popover's half of the legibility evidence: the lead figure and bar, measured
    /// off the drawing on both plates at nine loads; the menu bar's test is the other
    /// half. This half adds the plumbing: the popover asks the environment which plate it
    /// is on, and a view that stopped asking would paint the light plate's darkened
    /// colours on a dark popover while passing every hue assertion. So the whole colour
    /// is compared.
    ///
    /// The floor is asked on both plates. The middle of the ramp stays untouched on the
    /// dark plate, asserted as a rendering: the yellow at 115% comes back
    /// `rgb(0.827, 0.902, 0.173)`, the ramp's own.
    func testTheHeadlineIsLegibleOnWhicheverPlateItIsDrawnOn() async throws {
        var table = ["", "plate  load  mark    rgb as drawn            contrast"]
        for scheme in [ColorScheme.light, .dark] {
            let plate: UsagePopoverView.RampBackground = scheme == .dark ? .dark : .light
            let short = scheme == .dark ? "dark " : "light"
            for percent in legibilityLoadSamples {
                let drawn = try await headlineOnPlate(ratioPercent: percent, scheme: scheme)
                let expected = srgb(of: UsagePopoverView.ratioColor(atPercent: percent,
                                                                   on: plate))
                for (label, mark) in [("figure", drawn.figure), ("bar   ", drawn.bar)] {
                    table.append(String(format: "%@ %5.0f  %@  %.3f %.3f %.3f        %6.2f",
                                        short, percent, label, mark.red, mark.green, mark.blue,
                                        mark.contrast))
                    XCTAssertEqual(mark.red, expected.red, accuracy: 0.02,
                                   "at \(percent)% the \(label) on a \(short) popover is not the "
                                   + "colour this plate's rule answers")
                    XCTAssertEqual(mark.green, expected.green, accuracy: 0.02)
                    XCTAssertEqual(mark.blue, expected.blue, accuracy: 0.02)
                    XCTAssertGreaterThanOrEqual(mark.contrast,
                                                UsagePopoverView.contrastFloor(on: plate) - 0.1,
                                                "at \(percent)% the \(label) is \(mark.contrast) "
                                                + "to 1 on a \(short) popover, under the floor "
                                                + "\(UsagePopoverView.contrastFloor(on: plate))")
                }
            }
        }
        print(table.joined(separator: "\n"))
    }

    /// A colour the rule handed out, as sRGB.
    private func srgb(of colour: Color) -> (red: Double, green: Double, blue: Double) {
        guard let converted = NSColor(colour).usingColorSpace(.sRGB) else { return (-1, -1, -1) }
        return (Double(converted.redComponent),
                Double(converted.greenComponent),
                Double(converted.blueComponent))
    }

    /// The hue a `Color` the rule handed out resolves to, for comparing against
    /// what the rendering came back with.
    private func hue(of colour: Color) -> Double {
        guard let srgb = NSColor(colour).usingColorSpace(.sRGB) else { return -1 }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Double(hue)
    }

    /// The lead bar is the burn against the refill, and it stops at the refill rate. A
    /// scale stretched to three times the refill would put the refill, the point the
    /// reading turns on, a third of the way along. Read off the drawing at half, exactly,
    /// and three times the refill; the last two must be the same full bar. The ratio does
    /// not clamp itself, so the drawing is what holds this.
    func testTheLeadBarFillsWithTheRatioAndStopsAtTheRefillRate() async throws {
        let content = Double(UsagePopoverView.width - 2 * UsagePopoverView.padding)
        let half = try await headlineBarFill(ratioPercent: 50)
        let level = try await headlineBarFill(ratioPercent: 100)
        let over = try await headlineBarFill(ratioPercent: 300)

        XCTAssertEqual(half, content / 2, accuracy: 1.5,
                       "half the refill rate is not half the bar (\(half) pt of \(content))")
        XCTAssertEqual(level, content, accuracy: 1.5,
                       "burning exactly the refill is a full bar (\(level) pt of \(content))")
        XCTAssertEqual(over, level, accuracy: 0.5, """
            three times the refill drew \(over) pt against \(level) at the refill rate itself: a \
            bar that goes on growing puts the point the reading turns on a third of the way along
            """)
    }

    /// The width of the coloured part of the headline's lead bar, at one ratio.
    private func headlineBarFill(ratioPercent percent: Double) async throws -> Double {
        var snapshot = try snapshot(labels: ["acc1"])
        snapshot.fleetBurn = UsagePopoverLabelTests.burn(percent)
        let cache = UsageCache()
        cache.store(snapshot)
        let history = UsageHistoryModel(client: flatHistoryClient(readings: ["acc1": 90],
                                                                 silentOnUnknown: true),
                                        defaults: freshDefaults())
        history.open(labels: ["acc1"])
        await history.fetchTask?.value
        defer { history.close() }
        let picture = try canvas(UsagePopoverView(usage: UsageStore(config: .default, cache: cache),
                                                  history: history))
        let tall = Double(UsagePopoverView.headlineBarHeight) * picture.scale
        let bars = blobs(in: picture) { isChromatic($0) && $0.alpha > 0.9 }
            .filter { Double($0.height) == tall }
        XCTAssertEqual(bars.count, 1, "\(bars.count) patches of colour are the lead bar's height")
        return Double(try XCTUnwrap(bars.first).width) / picture.scale
    }

    /// The hue of the headline's bar at one burn ratio, in per cent of the
    /// week's refill rate — the quantity the ramp reads.
    private func headlineBarHue(ratioPercent percent: Double) async throws -> Double {
        var snapshot = try snapshot(labels: ["acc1"])
        snapshot.fleetBurn = UsagePopoverLabelTests.burn(percent)
        let cache = UsageCache()
        cache.store(snapshot)
        let history = UsageHistoryModel(client: flatHistoryClient(readings: ["acc1": 90],
                                                                 silentOnUnknown: true),
                                        defaults: freshDefaults())
        history.open(labels: ["acc1"])
        await history.fetchTask?.value
        defer { history.close() }
        let view = UsagePopoverView(usage: UsageStore(config: .default, cache: cache),
                                    history: history)
        let picture = try canvas(view)
        let tall = Double(UsagePopoverView.headlineBarHeight) * picture.scale
        let bars = blobs(in: picture) { isChromatic($0) && $0.alpha > 0.9 }
            .filter { Double($0.height) == tall }
        XCTAssertEqual(bars.count, 1,
                       "\(bars.count) patches of colour are \(UsagePopoverView.headlineBarHeight) pt "
                       + "tall, so the one measured below is not necessarily the headline's bar")
        return try XCTUnwrap(bars.first).hue
    }

    /// The lead figure over that bar is coloured by the same ramp. Asked of the
    /// rendering because a test of `headlineFigureColor` alone passes once the view stops
    /// calling it; the rule is asked in `UsagePopoverLabelTests`.
    ///
    /// Three ratios (cold at 60, green at capacity, red at 130) rather than the bar's
    /// seven, since what is held is that the figure follows the bar. With no ratio the
    /// figure is ink: the quota is a reading on a scale this line does not paint.
    func testTheHeadlineFigureIsDrawnInTheRatiosColour() async throws {
        for percent in [60.0, UsagePopoverView.greenRatioPercent, 130.0] {
            let drawn = try await headlineFigureHue(ratioPercent: percent)
            XCTAssertGreaterThan(drawn.pixels, 200,
                                 "the figure at \(percent)% drew \(drawn.pixels) coloured pixels: "
                                 + "the colour is gone, or the band measured is not the figure's")
            // Centred around zero the same way the reading is, so red on the
            // wrap compares as a small negative rather than as a large positive.
            var expected = hue(of: UsagePopoverView.ratioColor(atPercent: percent, on: .light))
            if expected > 0.5 { expected -= 1 }
            XCTAssertEqual(drawn.hue, expected, accuracy: 0.01,
                           "at \(percent)% the figure is not the ramp's colour (hue \(drawn.hue))")
        }

        // No ratio, and the figure is the quota: ink, whatever the quota says.
        let mean = try await headlineFigureHue(ratioPercent: nil)
        XCTAssertEqual(mean.pixels, 0,
                       "the quota was painted on some scale of its own (hue \(mean.hue))")
    }

    /// All three readings are on screen at once: the burn ratio leading, the weekly quota
    /// under it with its own figure, words and bar, and the spend rate under that with a
    /// figure and words but no bar.
    ///
    /// Measured like the caption's test: every string is drawn alone and the popover's
    /// lines of ink are compared with those widths. Eight lines above the first rule, in
    /// order (ratio figure, caption, bar; quota figure, caption, bar; rate figure,
    /// caption), each asserted, so a dropped or duplicated line fails on count and width.
    /// A `QuotaBar(fraction: nil)` under the rate would draw an empty track, reading as
    /// zero, and show up as a ninth full-width line.
    ///
    /// The three figures are different strings, and the lead at a different size (`126%`
    /// at `headlineFigureSize`, `52%` and `23.8M/h` at `supportingFigureSize`), so drawing
    /// one reading twice cannot pass.
    func testTheHeadlineDrawsAllThreeReadingsAtOnce() async throws {
        let content = Double(UsagePopoverView.width - 2 * UsagePopoverView.padding)
        let lines = try await headlineInkBands(ratioPercent: 126, mean: 52)
        XCTAssertEqual(lines.count, 8, """
            the headline is \(lines.count) lines of ink rather than the eight of three readings \
            (\(lines.map { String(format: "%.2f", $0) }.joined(separator: ", ")) pt wide)
            """)
        guard lines.count == 8 else { return }

        XCTAssertEqual(lines[0], try figureWidth("126%",
                                                 size: UsagePopoverView.headlineFigureSize),
                       accuracy: 0.5, "the lead figure is not the burn ratio at its own size")
        XCTAssertEqual(lines[1], try captionWidth(UsagePopoverView.ratioCaption), accuracy: 0.5,
                       "the line under the lead figure is not the refill caption")
        XCTAssertEqual(lines[2], content, accuracy: 0.5, "the lead bar is not full width")
        XCTAssertEqual(lines[3], try figureWidth("52%", size: UsagePopoverView.supportingFigureSize),
                       accuracy: 0.5,
                       "the second figure is not the weekly quota at the supporting size")
        XCTAssertEqual(lines[4], try captionWidth(UsagePopoverView.headlineCaption), accuracy: 0.5,
                       "the weekly quota lost the caption it has always had")
        XCTAssertEqual(lines[5], content, accuracy: 0.5, "the quota's own bar is not full width")
        XCTAssertEqual(lines[6], try figureWidth(UsagePopoverView.rateLabel(Self.currentRate),
                                                 size: UsagePopoverView.supportingFigureSize),
                       accuracy: 0.5, "the third figure is not the spend rate at the supporting size")
        XCTAssertEqual(lines[7], try captionWidth(UsagePopoverView.spendRateCaption), accuracy: 0.5,
                       "the spend rate lost its caption, or grew a bar it has no ceiling for")

        // And the supporting figures are smaller than the lead, which is what
        // makes the three a lead and two second readings rather than triplets.
        XCTAssertLessThan(UsagePopoverView.supportingFigureSize, UsagePopoverView.headlineFigureSize)
    }

    /// With no load the quota is the lead, and it is drawn once.
    ///
    /// The headline falls back to exactly what it drew before the load existed —
    /// three lines, the quota's caption under the quota's figure — and the
    /// supporting block is not drawn at all. Drawn anyway it would be the same
    /// percentage twice on one surface, which is the failure this half is here to
    /// catch: the count is the assertion.
    func testWithNoRatioTheQuotaIsTheLeadAndIsNotDrawnTwice() async throws {
        let lines = try await headlineInkBands(ratioPercent: nil, mean: 52)
        XCTAssertEqual(lines.count, 5, """
            with no ratio the headline is \(lines.count) lines of ink rather than five: the quota \
            is drawn twice, or the supporting block outlived the figure it supports \
            (\(lines.map { String(format: "%.2f", $0) }.joined(separator: ", ")) pt wide)
            """)
        guard lines.count == 5 else { return }
        XCTAssertEqual(lines[0], try figureWidth("52%", size: UsagePopoverView.headlineFigureSize),
                       accuracy: 0.5, "the quota is not the lead figure, at the lead's size")
        XCTAssertEqual(lines[1], try captionWidth(UsagePopoverView.headlineCaption), accuracy: 0.5,
                       "the caption under the lead is not the quota's")
        XCTAssertEqual(lines[2],
                       Double(UsagePopoverView.width - 2 * UsagePopoverView.padding), accuracy: 0.5)
        // The spend rate is not gated on the ratio: it is measured, it duplicates
        // nothing, and it stays. Its two lines are the fourth and fifth, and
        // asserting them is what keeps the count above from being satisfied by
        // the quota having been drawn twice after all.
        XCTAssertEqual(lines[3], try figureWidth(UsagePopoverView.rateLabel(Self.currentRate),
                                                 size: UsagePopoverView.supportingFigureSize),
                       accuracy: 0.5, "the spend rate went with the ratio it does not depend on")
        XCTAssertEqual(lines[4], try captionWidth(UsagePopoverView.spendRateCaption), accuracy: 0.5,
                       "the caption under the spend rate is not the spend rate's")
    }

    /// The quota's bar keeps the quota's scale and the lead's keeps the load's ramp. The
    /// fixture puts them on opposite sides: a load of 62% is cold blue on the ramp while
    /// a quota of 92% is red on `QuotaBar.color(for:)`'s 60-and-85 scale, so painting both
    /// by one rule fails. Then swapped: 126% is hot on the ramp and 52% green on the
    /// scale.
    func testTheTwoBarsKeepTheirOwnScales() async throws {
        let alarming = try await headlineBarHues(load: 62, mean: 92)
        XCTAssertEqual(alarming.lead,
                       hue(of: UsagePopoverView.ratioColor(atPercent: 62, on: .light)),
                       accuracy: 0.02, "the lead bar is not the load's ramp")
        XCTAssertEqual(alarming.supporting, hue(of: QuotaBar.color(for: 0.92)), accuracy: 0.02,
                       "the quota's bar lost the scale an account's window row is drawn on")

        let calm = try await headlineBarHues(load: 126, mean: 52)
        XCTAssertEqual(calm.lead,
                       hue(of: UsagePopoverView.ratioColor(atPercent: 126, on: .light)),
                       accuracy: 0.02)
        XCTAssertEqual(calm.supporting, hue(of: QuotaBar.color(for: 0.52)), accuracy: 0.02)
    }

    /// The hue of the two headline bars: the lead's, and the supporting reading's
    /// under it. Found as the third and sixth lines of ink above the first rule,
    /// which is the order `testTheHeadlineDrawsAllThreeReadingsAtOnce` holds.
    private func headlineBarHues(load percent: Double,
                                 mean: Double) async throws -> (lead: Double, supporting: Double) {
        let picture = try await headlinePicture(ratioPercent: percent, mean: mean)
        let firstRule = try XCTUnwrap(rules(in: picture).first, "the popover drew no rule at all")
        let bands = inkBandRows(in: picture).filter { $0.upperBound <= firstRule }
        guard bands.count == 8 else {
            XCTFail("the headline is \(bands.count) lines of ink rather than eight")
            return (-1, -1)
        }
        return (try chromaticHue(in: picture, rows: bands[2]),
                try chromaticHue(in: picture, rows: bands[5]))
    }

    /// The hue of everything drawn in a colour of its own inside a band of rows.
    /// Averaged over the three channels rather than over hues, so a colour on the
    /// wrap does not average into its opposite.
    private func chromaticHue(in canvas: Canvas, rows: Range<Int>) throws -> Double {
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        for y in rows {
            for x in 0..<canvas.width {
                guard let pixel = canvas.colour(x, y), isChromatic(pixel), pixel.alpha > 0.9 else {
                    continue
                }
                let straight = NSColor(hue: pixel.hue, saturation: pixel.saturation,
                                       brightness: 1, alpha: 1)
                red += straight.redComponent
                green += straight.greenComponent
                blue += straight.blueComponent
                count += 1
            }
        }
        guard count > 0 else {
            XCTFail("nothing in rows \(rows) was drawn in a colour of its own")
            return -1
        }
        let colour = NSColor(srgbRed: red / count, green: green / count, blue: blue / count, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        colour.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        XCTAssertGreaterThan(Double(saturation), 0.5,
                             "rows \(rows) came out all but grey, which any rule would pass")
        return Double(hue)
    }

    /// The widths of the lines of ink above the popover's first rule — which is
    /// exactly the headline, whatever it chose to draw.
    ///
    /// Cut at the rule rather than by a count, so a headline that grew a line
    /// fails the count above instead of being trimmed into passing it.
    private func headlineInkBands(ratioPercent percent: Double?, mean: Double) async throws -> [Double] {
        let picture = try await headlinePicture(ratioPercent: percent, mean: mean)
        let firstRule = try XCTUnwrap(rules(in: picture).first, "the popover drew no rule at all")
        return zip(inkBands(in: picture), inkBandRows(in: picture))
            .filter { $0.1.upperBound <= firstRule }
            .map(\.0)
    }

    /// A popover over a load and a fleet mean, rendered.
    ///
    /// The colour scheme is an argument because the load's colour now depends on
    /// it (`UsagePopoverView.RampBackground`), and `ImageRenderer` renders in
    /// whatever the environment says — which with nothing said is `.light`.
    private func headlinePicture(ratioPercent percent: Double?, mean: Double,
                                 scheme: ColorScheme = .light) async throws -> Canvas {
        var snapshot = try snapshot(labels: ["acc1"])
        snapshot.fleetSevenDayMean = mean
        // `nil` is the fallback picture: no ratio at all, which is the one thing
        // that takes the lead back to the mean.
        snapshot.fleetBurn = percent.map { UsagePopoverLabelTests.burn($0) }
        let cache = UsageCache()
        cache.store(snapshot)
        let history = UsageHistoryModel(client: flatHistoryClient(readings: ["acc1": 90],
                                                                 silentOnUnknown: true),
                                        defaults: freshDefaults())
        history.open(labels: ["acc1"])
        await history.fetchTask?.value
        defer { history.close() }
        return try canvas(UsagePopoverView(usage: UsageStore(config: .default, cache: cache),
                                           history: history)
            .environment(\.colorScheme, scheme))
    }

    /// The headline's lead figure and bar as they land on the popover's plate, at one
    /// load in one scheme: the first and third lines of ink above the first rule (the
    /// order `testTheHeadlineDrawsAllThreeReadingsAtOnce` holds). Composited over the
    /// plate because the rendering is on transparency and a reader sees the material
    /// through it.
    private func headlineOnPlate(ratioPercent percent: Double, scheme: ColorScheme)
        async throws -> (figure: (red: Double, green: Double, blue: Double, contrast: Double),
                         bar: (red: Double, green: Double, blue: Double, contrast: Double)) {
        let plate: UsagePopoverView.RampBackground = scheme == .dark ? .dark : .light
        let picture = try await headlinePicture(ratioPercent: percent, mean: 52, scheme: scheme)
        let firstRule = try XCTUnwrap(rules(in: picture).first, "the popover drew no rule at all")
        let bands = inkBandRows(in: picture).filter { $0.upperBound <= firstRule }
        guard bands.count == 8 else {
            XCTFail("the headline is \(bands.count) lines of ink rather than eight")
            return ((0, 0, 0, 0), (0, 0, 0, 0))
        }
        func measure(_ rows: Range<Int>) throws
            -> (red: Double, green: Double, blue: Double, contrast: Double) {
            var dots: [(red: Double, green: Double, blue: Double, alpha: Double)] = []
            for y in rows {
                for x in 0..<picture.width {
                    guard let pixel = picture.straight(x, y),
                          isChromatic(picture.colour(x, y)) else { continue }
                    dots.append(pixel)
                }
            }
            let peak = try XCTUnwrap(dots.map(\.alpha).max(), "nothing coloured in the band")
            let solid = dots.filter { $0.alpha >= peak - 0.02 }
            let count = Double(solid.count)
            let mixed = (
                red: solid.reduce(0.0) { $0 + $1.red * $1.alpha + plate.grey * (1 - $1.alpha) } / count,
                green: solid.reduce(0.0) { $0 + $1.green * $1.alpha + plate.grey * (1 - $1.alpha) } / count,
                blue: solid.reduce(0.0) { $0 + $1.blue * $1.alpha + plate.grey * (1 - $1.alpha) } / count)
            return (mixed.red, mixed.green, mixed.blue, wcagContrast(mixed, against: plate.grey))
        }
        return (try measure(bands[0]), try measure(bands[2]))
    }

    private func figureWidth(_ text: String, size: CGFloat) throws -> Double {
        try XCTUnwrap(inkBands(in: try canvas(Text(text)
            .font(.system(size: size, weight: .semibold))
            .monospacedDigit())).first)
    }

    private func captionWidth(_ text: String) throws -> Double {
        try XCTUnwrap(inkBands(in: try canvas(Text(text)
            .font(.system(size: UsagePopoverView.headlineCaptionSize)))).first)
    }

    /// The hue of the popover's big figure, and how much of it was drawn in colour. The
    /// figure is the topmost band of ink (figure, caption, bar, held by
    /// `testTheHeadlineCaptionIsDrawnOnOneLine`). Hues are centred around zero before
    /// averaging (`> 0.5` becomes negative) because red sits on the wrap: the mean of
    /// 0.99 and 0.01 would be 0.5, a cyan.
    private func headlineFigureHue(ratioPercent percent: Double?) async throws
        -> (hue: Double, pixels: Int) {
        var snapshot = try snapshot(labels: ["acc1"])
        // A mean as well, so the `nil` case still has a figure to draw.
        snapshot.fleetSevenDayMean = 52
        snapshot.fleetBurn = percent.map { UsagePopoverLabelTests.burn($0) }
        let cache = UsageCache()
        cache.store(snapshot)
        let history = UsageHistoryModel(client: flatHistoryClient(readings: ["acc1": 90],
                                                                 silentOnUnknown: true),
                                        defaults: freshDefaults())
        history.open(labels: ["acc1"])
        await history.fetchTask?.value
        defer { history.close() }
        let picture = try canvas(UsagePopoverView(usage: UsageStore(config: .default, cache: cache),
                                                  history: history))
        let figure = try XCTUnwrap(inkBandRows(in: picture).first, "the popover drew nothing at all")
        var hues: [Double] = []
        for y in figure {
            for x in 0..<picture.width {
                guard let pixel = picture.colour(x, y), isChromatic(pixel), pixel.alpha > 0.5 else {
                    continue
                }
                hues.append(pixel.hue > 0.5 ? pixel.hue - 1 : pixel.hue)
            }
        }
        guard !hues.isEmpty else { return (0, 0) }
        return (hues.reduce(0, +) / Double(hues.count), hues.count)
    }

    /// The rows each line of ink occupies, top to bottom — the same grouping
    /// `inkBands` measures widths from, kept as rows so a caller can read the
    /// colour inside one of them.
    private func inkBandRows(in canvas: Canvas) -> [Range<Int>] {
        var bands: [Range<Int>] = []
        var start: Int?
        for y in 0..<canvas.height {
            var inked = false
            for x in 0..<canvas.width where canvas.alpha(x, y) > 8.0 / 255 {
                inked = true
                break
            }
            if inked {
                start = start ?? y
            } else if let first = start {
                bands.append(first..<y)
                start = nil
            }
        }
        if let first = start { bands.append(first..<canvas.height) }
        return bands
    }

    /// How wide each line of ink in a rendering is, in points, top to bottom: rows
    /// that have anything drawn in them, grouped by the empty rows between them, each
    /// measured from its leftmost inked column to its rightmost.
    private func inkBands(in canvas: Canvas) -> [Double] {
        var widths: [Double] = []
        var run: (minX: Int, maxX: Int)?
        for y in 0..<canvas.height {
            var minX = Int.max
            var maxX = Int.min
            for x in 0..<canvas.width where canvas.alpha(x, y) > 8.0 / 255 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
            if minX <= maxX {
                run = run.map { (min($0.minX, minX), max($0.maxX, maxX)) } ?? (minX, maxX)
            } else if let current = run {
                widths.append(Double(current.maxX - current.minX + 1) / canvas.scale)
                run = nil
            }
        }
        if let current = run {
            widths.append(Double(current.maxX - current.minX + 1) / canvas.scale)
        }
        return widths
    }

    // MARK: - The note beside a switched-off account

    /// A real reason seen on the gateway: 62 characters, wider than the room the name
    /// line has for a note at any popover width. It sits on an account whose `disabled`
    /// is `false` (`disabled_reason` outlives its switch), so it is a fixture of real
    /// length, not an observation of the surface.
    private static let longReason = "operator: 22h, switched over from the temporary quota cooldown"

    /// One account's row, rendered alone at the width the list gives it. The row rather
    /// than the whole popover, because the claim is a height. Ink bands cannot see the
    /// note: the name line runs from the dot to the checkbox at the right edge, so a note
    /// between them widens no band. Inked pixels are counted instead, which a wider note
    /// moves and an undrawn note does not.
    private func accountRow(disabled: Bool,
                            reason: String,
                            label: String = "acc1") async throws -> Canvas {
        // `elsewhere` is here so the fleet has somewhere to route: this account
        // alone would be zero routable accounts in the switched-off half, and the
        // orange line is drawn under the list rather than in a row — but a rotation
        // this stub answers is the fleet's, and a fixture that says one thing in
        // one half and another in the other is measuring itself.
        let rotation = """
        {"accounts": [{"label": "\(label)", "eligible": \(!disabled), "disabled": \(disabled), \
        "disabled_until": null, "disabled_reason": "\(reason)"}, \
        {"label": "elsewhere", "eligible": true, "disabled": false, \
        "disabled_until": null, "disabled_reason": ""}]}
        """
        let (view, store, history) = try await popover(named: [label], asked: [label],
                                                       readings: [label: 40], rotation: rotation)
        defer { history.close() }
        let account = try XCTUnwrap(store.snapshot.accounts.first, "the poll named no account")
        let content = UsagePopoverView.width - 2 * UsagePopoverView.padding
        return try canvas(view.accountRow(account, in: [label]).frame(width: content))
    }

    /// Everything drawn in a rendering, counted rather than bounded: a note that
    /// grew inside a line already running edge to edge changes this and changes no
    /// bounding box.
    private func inkedPixels(in canvas: Canvas) -> Int {
        var count = 0
        for y in 0..<canvas.height {
            for x in 0..<canvas.width where canvas.alpha(x, y) > 8.0 / 255 { count += 1 }
        }
        return count
    }

    /// The row of an account the gateway is not routing to says so, and the row of one it
    /// is says nothing extra. Asked with two values of the same field, of different
    /// widths (§4): the two states also differ in the checkbox's tick, so "with and
    /// without" would see a difference even with the note deleted. Two reasons of
    /// different lengths hold the rest fixed: either the wider one inks more, or the
    /// renderings are identical. Both are short enough to escape truncation.
    func testTheRowOfASwitchedOffAccountSaysSoAndTheRowOfALiveOneDoesNot() async throws {
        let narrow = inkedPixels(in: try await accountRow(disabled: true, reason: "z"))
        let wide = inkedPixels(in: try await accountRow(disabled: true, reason: "zzzzzzzzzz"))
        XCTAssertGreaterThan(wide, narrow + 20,
                             "nine more characters of reason bought \(wide - narrow) pixels of "
                             + "ink (\(narrow) against \(wide)): the note is not drawn")

        // And in the rotation the field is not drawn at all, so the same two
        // values give the same picture.
        let live = inkedPixels(in: try await accountRow(disabled: false, reason: "z"))
        let liveWide = inkedPixels(in: try await accountRow(disabled: false,
                                                            reason: "zzzzzzzzzz"))
        XCTAssertEqual(live, liveWide,
                       "an account in the rotation drew a reason it is not disabled for")
    }

    /// The note costs the row no height, which is why it sits on the name line: a note on
    /// its own line grows the list under the pointer the moment an account is switched
    /// off from this very row.
    ///
    /// Three rows, and each pair catches a defect the other cannot. The live row against
    /// the short reason sees the arrangement (the note taking a row of its own); the two
    /// reasons of different widths see the truncation (a note allowed to wrap on the
    /// long value). Putting the note back under the name fails only the first pair;
    /// removing `lineLimit(1)` fails only the second.
    func testTheNoteRidesOnTheNameLineAndCostsTheRowNoHeight() async throws {
        func height(disabled: Bool, reason: String) async throws -> Double {
            let picture = try await accountRow(disabled: disabled, reason: reason)
            return Double(picture.height) / picture.scale
        }
        let live = try await height(disabled: false, reason: "")
        let short = try await height(disabled: true, reason: "z")
        let long = try await height(disabled: true, reason: Self.longReason)

        XCTAssertEqual(short, long, accuracy: 0.5,
                       "a longer reason made the row taller — \(short) pt against \(long) pt — so "
                       + "the note wrapped rather than being cut")
        XCTAssertEqual(live, short, accuracy: 0.5,
                       "switching an account off cost the row \(short - live) pt, which is the "
                       + "list moving under the pointer of whoever clicked it")
    }

    /// The dot and the name, as the bare row draws them: over the name line's own rows,
    /// every column up to the first clear gap wider than the `HStack`'s 5 pt spacing.
    ///
    /// Both are measured, not assumed. The band cannot be a fixed number: the note starts
    /// 5 pt past the name, well inside any guessed width, so the probe would read the
    /// reason as name. And the columns cannot span the whole row: the two window rows
    /// beneath run to the reset column, so the first gap of a full-height scan is theirs,
    /// past the note entirely.
    private func nameBand(of canvas: Canvas, over rows: Range<Int>) -> Int {
        func inked(_ x: Int) -> Bool { rows.contains { canvas.alpha(x, $0) > 8.0 / 255 } }
        // Wider than the 5 pt between the name and whatever follows it, and far
        // narrower than the `Spacer` before the checkbox, which is the only gap in
        // a name line drawn with nothing between the two.
        let gap = Int(8 * canvas.scale)
        var clear = 0
        for x in 0..<canvas.width {
            if inked(x) { clear = 0; continue }
            clear += 1
            if clear == gap { return x - gap + 1 }
        }
        return canvas.width
    }

    /// What the note gives up to fit is its own tail, never the name: the checkbox acts
    /// on that account, so the name is the row's identity. Asked with a reason wider than
    /// the line, comparing the left of the row (dot and name) with the same row without a
    /// note, pixel for pixel, since a name shortened by `truncationMode(.middle)` still
    /// inks something.
    ///
    /// Asked twice, and the long label is what matters: with short labels (`acc2`,
    /// `main`) the two never compete, so `layoutPriority` on the name is untested there
    /// (the modifier-in-the-default trap, §4). Labels come from `/gw/usage` and can be
    /// any length. Removing `layoutPriority(1)` fails only the long label; removing the
    /// note's `lineLimit(1)` fails both. The band guards are measured on the bare row,
    /// which has no note, so neither modifier affects them.
    func testTheNameIsNeverTheHalfThatIsCutToFitTheNote() async throws {
        func ink(_ label: String) async throws -> (bare: Int, crowded: Int, band: Double) {
            let bare = try await accountRow(disabled: false, reason: "", label: label)
            let crowded = try await accountRow(disabled: true, reason: Self.longReason,
                                               label: label)
            // The name line is the top band of the three: name, then the 5h
            // window, then the 7d one.
            let line = try XCTUnwrap(inkBandRows(in: bare).first, "the bare row drew nothing")
            // The band comes from the bare row, where the name has nothing next to
            // it: in the crowded one the note's ink would close the gap that finds
            // it.
            let band = nameBand(of: bare, over: line)
            func count(_ canvas: Canvas) -> Int {
                var total = 0
                for y in line {
                    for x in 0..<band where canvas.alpha(x, y) > 8.0 / 255 { total += 1 }
                }
                return total
            }
            return (count(bare), count(crowded), Double(band) / bare.scale)
        }

        let short = try await ink("acc1")
        XCTAssertGreaterThan(short.band, 30,
                             "the band stopped at \(short.band) pt, which is inside the name "
                             + "rather than after it")
        XCTAssertEqual(short.bare, short.crowded,
                       "the name gave way to the note: \(short.bare) inked pixels in the first "
                       + "\(short.band) pt of the name line against \(short.crowded)")

        // Long enough that the name and a 62-character reason cannot both have
        // what they want, which is the only arrangement in which either gives way.
        let long = try await ink("a-rather-long-account-label")
        XCTAssertGreaterThan(long.band, short.band + 40,
                             "the long label drew no wider than the short one (\(long.band) pt "
                             + "against \(short.band)), so nothing here competes for room")
        XCTAssertEqual(long.bare, long.crowded,
                       "the long name gave way to the note: \(long.bare) inked pixels in the "
                       + "first \(long.band) pt of the name line against \(long.crowded)")
    }

    /// The hue window of the warning's orange in a rendering. `Color.orange` reports hue
    /// 0.10136; drawn as 10 pt text and read off the bitmap it lands between 0.09681 and
    /// 0.09797 (scale 2.0, popover width). The band holds that spread and stays clear of
    /// the rest of the surface's colour, which runs 0.00886…0.21144.
    private static let warningHue: ClosedRange<Double> = 0.09...0.105

    /// Lines of the popover drawn entirely in the fleet warning's orange. Lines rather
    /// than a pixel count, because other colour on this surface straddles the orange; a
    /// band every coloured pixel of which is that orange cannot be made out of a wider
    /// spread. The floor of 100 pixels keeps a colourless band from qualifying by
    /// vacuity: the sentence's two lines carry about 2600 each, far above it and far
    /// above anything a rounded edge could leave.
    private func orangeLines(in canvas: Canvas) -> Int {
        inkBandRows(in: canvas).filter { band in
            var coloured = 0
            for y in band {
                for x in 0..<canvas.width {
                    guard let pixel = canvas.colour(x, y), isChromatic(pixel),
                          pixel.alpha > 0.5 else { continue }
                    guard Self.warningHue.contains(pixel.hue) else { return false }
                    coloured += 1
                }
            }
            return coloured > 100
        }.count
    }

    // MARK: - The fleet's own lines with no accounts to draw them under

    /// The orange line is drawn when the account list is empty. The rows come from the
    /// quota poll and the rotation from `/gw/status`, which fail apart: with `/gw/usage`
    /// down and every client request answered 429, the half that is up is the one with
    /// something to report.
    ///
    /// Asked of the line's colour, not of two pictures differing (§4): `fleetWarning` has
    /// one non-`nil` value, `noRouteWarning`, so there is no second width to compare.
    /// This surface draws only its warning in `.orange`, and `orangeLines` answers "not
    /// there" by returning zero.
    ///
    /// Two lines because the 114-character sentence at 10 pt wraps within 320 pt minus
    /// padding; `fixedSize(horizontal: false, vertical: true)` lets it wrap instead of
    /// being cut, and a truncated line would count 1. The control, a fleet with
    /// somewhere to route, shows the count can come back zero.
    func testTheFleetWarningIsDrawnWithNoAccountsToDrawItUnder() async throws {
        func lines(rotation: String) async throws -> (orange: Int, warning: String?) {
            let history = UsageHistoryModel(client: flatHistoryClient(readings: [:],
                                                                      silentOnUnknown: true,
                                                                      rotation: rotation),
                                            defaults: freshDefaults())
            let cache = UsageCache()
            cache.store(try snapshot(labels: []))
            history.open(labels: [])
            await history.fetchTask?.value
            defer { history.close() }
            let store = UsageStore(config: .default, cache: cache)
            XCTAssertTrue(store.snapshot.accounts.isEmpty,
                          "the popover has accounts to list, so this is not the empty branch")
            let picture = try canvas(UsagePopoverView(usage: store, history: history))
            return (orangeLines(in: picture), history.fleetWarning)
        }
        // A pass, not a click: `/gw/status` reporting a fleet with nowhere left to
        // route is the whole of what raises this line now.
        let raised = try await lines(rotation: UsageFixtures.statusWithNowhereToRoute)
        XCTAssertEqual(raised.warning, UsageHistoryModel.noRouteWarning,
                       "the pass did not raise the line this test is about")
        XCTAssertEqual(raised.orange, 2, """
            the warning is 114 characters over a 320 pt popover, so it is two lines of orange \
            and this picture has \(raised.orange) — with no accounts to list, the fleet's own \
            line is drawn nowhere
            """)

        let quiet = try await lines(rotation: quietRotation)
        XCTAssertNil(quiet.warning,
                     "the control fleet has somewhere to route, so nothing may have raised this")
        XCTAssertEqual(quiet.orange, 0,
                       "the measurement answers yes to a picture with no warning in it")
    }

    /// The blame for a click that would not go through is drawn there too: the rows come
    /// from `/gw/usage` and this line from the operator's click, which needs no rows. A
    /// failing quota poll must not hide the only statement that the click failed.
    ///
    /// Asked with two values of the same field, of different widths (§4):
    /// `acc1: unreachable: z` against `acc1: unreachable: zzzzzzzzzz`, everything else
    /// fixed. Both stay on one line uncut, so the band count is equal and exactly one
    /// band may follow the field.
    func testTheBlameForAFailedClickIsDrawnWithNoAccountsToDrawItUnder() async throws {
        func bands(reason: String) async throws -> [Double] {
            let client = UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
                let url = request.url ?? Config.default.resolvedUsageBaseURL
                guard !url.path.hasPrefix("/gw/accounts/") else {
                    throw UsageError.unreachable(reason)
                }
                guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                     httpVersion: nil, headerFields: nil) else {
                    throw UsageError.unreachable("no test response")
                }
                // Somewhere to route, so no orange line joins the picture and the
                // pass leaves nothing else to move.
                return (Data(quietRotation.utf8), response)
            }
            let history = UsageHistoryModel(client: client, defaults: freshDefaults())
            let cache = UsageCache()
            cache.store(try snapshot(labels: []))
            history.open(labels: [])
            await history.fetchTask?.value
            defer { history.close() }
            history.setAccount(label: "acc1", enabled: false)
            await history.switchTasks["acc1"]?.value
            // The failure path asks again on its way out, and that pass has to be
            // finished with before the picture is taken.
            await history.fetchTask?.value
            XCTAssertEqual(UsagePopoverView.switchBlame(history.switchFailures),
                           "acc1: unreachable: \(reason)",
                           "the click this test is about did go through")
            XCTAssertNil(history.fleetWarning, "an orange line joined the picture")
            XCTAssertNil(history.rotationFailure, "the pass this test holds fixed did not answer")
            let store = UsageStore(config: .default, cache: cache)
            return inkBands(in: try canvas(UsagePopoverView(usage: store, history: history)))
        }
        let narrow = try await bands(reason: "z")
        let wide = try await bands(reason: "zzzzzzzzzz")

        XCTAssertEqual(narrow.count, wide.count,
                       "the two reasons drew a different number of lines: \(narrow) / \(wide)")
        let moved = zip(narrow, wide).enumerated().filter { abs($0.element.1 - $0.element.0) > 0.5 }
        XCTAssertEqual(moved.count, 1, """
            \(moved.count) lines of the popover follow the blame rather than one: with no \
            accounts to list, the line saying the click failed is drawn nowhere \
            (\(narrow) / \(wide))
            """)
        let line = try XCTUnwrap(moved.first?.element)
        XCTAssertGreaterThan(line.1, line.0 + 10,
                             "nine more characters bought \(line.1 - line.0) pt of line")
    }

    /// And so is the reason the checkboxes went inert: `/gw/status` failing empties
    /// `switches`, drawing every box clear and unclickable, and a gateway that cannot
    /// answer `/gw/status` often cannot answer `/gw/usage` either, leaving no rows.
    ///
    /// Asked like the blame: `status: unreachable: z` against
    /// `status: unreachable: zzzzzzzzzz`. With the pass failing there is no rotation and
    /// no count, so the other two fleet lines are `nil` in both halves.
    func testTheReasonTheSwitchesWentInertIsDrawnWithNoAccountsToDrawItUnder() async throws {
        func bands(reason: String) async throws -> [Double] {
            let client = UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { _ in
                throw UsageError.unreachable(reason)
            }
            let history = UsageHistoryModel(client: client, defaults: freshDefaults())
            let cache = UsageCache()
            cache.store(try snapshot(labels: []))
            history.open(labels: [])
            await history.fetchTask?.value
            defer { history.close() }
            XCTAssertEqual(history.rotationFailure, "status: unreachable: \(reason)",
                           "the pass this test is about answered")
            XCTAssertNil(history.switches, "a failed pass left a rotation behind")
            XCTAssertNil(history.fleetWarning, "an orange line joined the picture")
            XCTAssertTrue(history.switchFailures.isEmpty, "a blame line joined the picture")
            let store = UsageStore(config: .default, cache: cache)
            return inkBands(in: try canvas(UsagePopoverView(usage: store, history: history)))
        }
        let narrow = try await bands(reason: "z")
        let wide = try await bands(reason: "zzzzzzzzzz")

        XCTAssertEqual(narrow.count, wide.count,
                       "the two reasons drew a different number of lines: \(narrow) / \(wide)")
        let moved = zip(narrow, wide).enumerated().filter { abs($0.element.1 - $0.element.0) > 0.5 }
        XCTAssertEqual(moved.count, 1, """
            \(moved.count) lines of the popover follow the pass's reason rather than one: with \
            no accounts to list, the line saying why the boxes went inert is drawn nowhere \
            (\(narrow) / \(wide))
            """)
        let line = try XCTUnwrap(moved.first?.element)
        XCTAssertGreaterThan(line.1, line.0 + 10,
                             "nine more characters bought \(line.1 - line.0) pt of line")
    }

    // MARK: - The mean line is ink

    /// The mean is drawn in ink, and no account may be handed that colour. That is why
    /// the chart declares its own colour scale: without `chartForegroundStyleScale`
    /// Charts gives the mean a palette hue, and the headline number (that line's last
    /// point) names nothing in the picture.
    ///
    /// Read in the two bands `UsageHistoryTests` calibrated (§4): with flat accounts at
    /// 100 and 20 the mean's band holds only the mean's line and the lower band the
    /// second account's. Saturation is averaged over the band's ink, weighted by alpha.
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

    /// It stays ink when an account carries the mean's key. `styleDomain` puts the mean's
    /// key first and the accounts after it, so a colliding account name repeats it in the
    /// domain; Charts keeps the last colour for a repeated key, and the mean would take
    /// that account's hue. Other palette tests stay green through that (both lines are
    /// chromatic, each dot matches a line), so only the mean's band can tell, by
    /// saturation.
    ///
    /// Same arrangement as above: the colliding account is the one at 100, so the mean
    /// is 60 and the two calibrated bands (§4) hold one line each.
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

    /// A dot beside an account's name is the colour of that account's line, even when the
    /// two lists the colours come from disagree: an account that failed its history
    /// request is in the poll but not on the chart, one that just left the poll is on the
    /// chart but not in the list. Keyed on `history.series`, the dots would point at
    /// someone else's line.
    ///
    /// Asked of the pixels because `styleRange` and `accountColor` are tested as pure
    /// functions but their call sites are not. Here the poll names an account whose
    /// history failed: its dot is drawn, its line is not, and the accounts after it must
    /// keep their hues.
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

    /// The same rule from the other side, where nothing but a colour changes: an account
    /// the poll stopped naming is still on the chart, so the list of lines is the longer.
    /// Each dot must be the colour of its account's line; counted off the chart's list
    /// they would shift one place, with the same count, so only the hue can tell.
    ///
    /// The departed account keeps a grey line (`accountColor`'s answer for a label the
    /// poll does not name), and grey is not counted among the hues.
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
                                        historiesFailed: store.snapshot.historiesFailure != nil,
                                        now: history.now)
    }
}
