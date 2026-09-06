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

/// The loads the ramp's *legibility* is measured at, on every surface and in
/// both appearances.
///
/// Two more than `rampSamples`, and they are the two that matter: 110 and
/// 120 sit inside 100–124, which is the band this fleet actually lives in
/// (`make dump` read 144% on 2026-08-18) and the band the old luminance ceiling
/// clamped hardest. A separate list rather than a wider `rampSamples`
/// because `assertRamp` is about the shape of the ramp and reads its samples by
/// position.
private let legibilityLoadSamples: [Double] = [60, 70, 85, 100, 110, 115, 120, 130, 150]

/// The WCAG contrast of an sRGB colour against an sRGB grey plate: linearise
/// each component, weigh by Rec. 709, take the ratio with 0.05 added to both
/// sides.
///
/// The tests keep their own copy of this arithmetic on purpose. The
/// linearisation is exactly the step the source had missing, and a check that
/// borrowed the function under test would have agreed with the mistake as
/// happily as it now agrees with the fix.
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
/// outside the end anchors, strictly falling between them, and spanning the
/// whole way from blue to red.
///
/// Three properties rather than one, because each survives the others being
/// broken. A step at capacity passes "flat at the ends" and fails the fall; a
/// table of hand-picked colours can fall and still stand still somewhere; and a
/// ramp squeezed into a corner of the wheel — greens through greens — passes
/// both and fails the span. `hues` is the drawn hue at each of
/// `rampSamples`, in that order.
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

    /// A sum the sweep could not take over every chat of the row wears `≥`, the
    /// mark the token figure already uses for the same hole (§3.1). It goes on
    /// the label rather than turning the number into `nil`, because `nil` is
    /// drawn as a dash — the quiet row — and would understate by the whole
    /// figure instead of by one chat's share.
    ///
    /// Below the one-percent threshold there is no label to mark, and the mark
    /// must not resurrect one: `≥` on nothing would be a row claiming a floor it
    /// does not print a number for.
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

    /// The tooltip is where there is room to say what the two numbers count: a
    /// share of *one* core, which is what makes 412% read as four cores, and the
    /// second number as **detached processes** rather than as orphaned ones.
    ///
    /// The wording matters because the count is not a tally of dead parents: a
    /// detached process brings everything running underneath it into the number
    /// (SPEC §2.8), so the live claim that was a `python` with a `docker` and
    /// two `ssh` under it counts 4 with one parent gone. `4 orphaned processes`
    /// said four parents had exited.
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

    /// The number never gives way; the topic does. `fixedSize` is what says so,
    /// and 150 pt is where it starts to matter — the panel width is a setting,
    /// and at the default there is room for both.
    ///
    /// Held by measurement rather than by belief: the number's ink is compared
    /// against the same string rendered on its own, so a truncated `3.40M/…`
    /// fails even though it is still "drawn". Proved by removing the modifier and
    /// re-measured 2026-08-27, now that the label is a rate: `3.40M/h` inks 42.00
    /// pt whole and 24.25 pt clipped at 150 pt — 17.75 pt of it gone — and this
    /// fails there. **Only there.** At 240 pt, and at the 380 pt default, the two
    /// extra characters still fit and nothing fails, so 150 is the whole of what
    /// holds this modifier down; a claim that it also broke at 240 was in this
    /// comment until the mutation was actually run.
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

    /// **Is the rate drawn at all** — asked with two rates of different width
    /// rather than with a rate against no rate.
    ///
    /// Two rates differ in **the label's width and nothing else**, so nothing but
    /// the label can make the two renders differ. That is the whole argument, and
    /// it does not depend on guessing how the label might one day stop being
    /// drawn.
    ///
    /// A rate against no rate is two different compositions of the line, not one
    /// composition with an element missing: `secondLine` hands the topic whatever
    /// the number does not take (`Spacer(minLength: 0)`, the topic truncating to a
    /// tail), so "these differ" is a fact about the line rather than about the
    /// number. Measured 2026-08-27 — the topic's own ink with the rate against
    /// without it: 12.75 pt against 64.50 at 150 pt, 104.25 against 150.50 at 240,
    /// and 189.50 either way at the 380 pt default, where the topic fits whole. So
    /// the naive form is contaminated exactly at the narrow widths, which are the
    /// widths the label is at risk in.
    ///
    /// §4 keeps this trap under the bracket and the percentage, where the
    /// mechanism is a rung of `titleLine`'s `ViewThatFits` ladder. That is a
    /// *different* case, not this one: `secondLine` has no `ViewThatFits` at all,
    /// and `renderSecondLine` draws the title line empty anyway. Same trap, other
    /// machinery.
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

    /// The rate is two characters wider than the total it replaced, and §4's
    /// floors were measured on the narrower string. Re-measured here: the rate is
    /// whole at the default width **and** at 150 pt, the narrow end of the
    /// `panelWidth` setting — the end where a modifier that "changes nothing" is
    /// the one that breaks (`AGENTS.md`).
    ///
    /// Clipping is caught by comparing the number's ink against the same string
    /// rendered on its own. That comparison is a **span** — `min…max` of the
    /// inked columns — and nothing about it is bitmap against bitmap; saying it
    /// was is what hid the defect below for a review round.
    ///
    /// Which is why the 6 pt gap in front of the number is asserted blank, exactly
    /// as `testTheRateIsNeverCutWhileTheTopicIs` asserts it. The measuring window
    /// is taken leftwards from the end of the line by the label's *whole* width,
    /// so a clipped number leaves that window hanging over the gap and into the
    /// topic, and `span` hands back the union of the two. Measured with
    /// `fixedSize` removed at 150 pt, before the guard was carried over: the wide
    /// label's window came out **49.50 pt** against **49.00 pt** of ink rendered
    /// alone — inside the 0.5 tolerance, so the wide label's own assertion did not
    /// see the break at all, though only 24.25 pt of that was number and the other
    /// 25.25 was topic. The test went red on the narrow label, and a regression
    /// that clipped just the long one — `≥123.45M/h`, ten characters, the one a
    /// narrow panel reaches first — would have left it green.
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

    /// Is the percentage on the line at this width?
    ///
    /// Decided against a **wider percentage**, not against no percentage at all.
    /// The obvious comparison — the row with one against the row without —
    /// answers "these two rows differ", which is not the same question: below
    /// the percentage's floor the row that carries one falls a rung further than
    /// the row that carries none, so the two differ while neither of them draws
    /// a percentage. Two figures that differ only in width cannot do that: when
    /// the label is dropped both rows draw the same thing, and when it is drawn
    /// the wider one takes more room. The predicate is about the narrow figure —
    /// the wide one is allowed to have been dropped already.
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

    /// The percentage stands at the right-hand end of the title line, in the
    /// same column as the spend on the line below it — which is the whole of
    /// what "opposite the title, above the token figure" means.
    ///
    /// Asserted by measuring the two apart and comparing where each of them
    /// ends, because a render collapses its columns over the height of the row
    /// and the two labels would otherwise be one span. Each row is drawn with
    /// nothing else on its line — no topic under the percentage, no name beside
    /// the spend — so the ink at the right-hand end is the label and nothing
    /// else.
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

    /// The degradation order, which is the decision the ladder encodes: as the
    /// panel narrows the **percentage** is what goes first, then the count, and
    /// the name outlives both.
    ///
    /// Swept rather than asserted at two chosen widths, because what is being
    /// claimed is an order and an order needs both of its boundaries. Measured
    /// a point at a time (27.08.2026): against the longest real name on this
    /// machine the percentage is drawn down to 224 pt and the count down to 186,
    /// and against a one-character name 192 and 154 — 38 pt of panel in either
    /// case where the row reads `name (agents: 1)` with no percentage, which is
    /// the state rungs 3 and 4 exist to produce.
    ///
    /// **Both names, because the short one is the only place rung 3 shows.** The
    /// longest name stopped fitting whole above 380 pt, so it never stands on
    /// rung 3 at all and reaches the same 186 through rung 4; deleting rung 3
    /// costs it nothing and this test would not notice. A one-character name
    /// climbs 1 → 3 → 5, and with rung 3 taken out it loses its bracket at 186
    /// instead of 154 (measured by deletion) — 32 pt of panel, and the failure
    /// order of §4 broken, the count and the percentage going within 6 pt of
    /// each other.
    ///
    /// The third floor is what pins that down as a property rather than a pair
    /// of widths: the count's floor is the same on a row that carries a
    /// percentage as on one that does not, because the percentage is always the
    /// first thing dropped and so can never cost the count a point of panel.
    ///
    /// The assertions are that order, that equality, and the fact that each rung
    /// is reached inside the sweep — not the exact widths, which move with the
    /// font metrics of an OS update. Swapping rungs 2 and 3 — dropping the count
    /// before the percentage — reverses the inequality and fails here. The step
    /// is 5 pt because the widths themselves are not what is asserted, and the
    /// sweep renders six rows at each of them.
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
        /// One inked pixel: where it is, what colour it came out, and how
        /// strongly. Colour is here because the picture stopped being a template
        /// (§4) — the system no longer decides what any of this looks like, so
        /// what it looks like is a thing these tests have to ask.
        ///
        /// The three components are *straight*, divided back out by the alpha
        /// they were stored premultiplied under: an antialiased edge is the same
        /// colour as the middle of a stroke, only fainter, and weighing the
        /// stored bytes would report every edge as a paler colour of its own.
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

    /// The rows where the bar's frame is the only thing that can be drawn: above
    /// the fill's own bounds and inside the bar's.
    ///
    /// It exists because the fill's length became the ratio. While it was the
    /// quota mean, a fixture at a mean of 0 left the whole bar band to the frame
    /// and the two could be told apart by choosing the figure; now anything the
    /// warning boundary fires on has a full capsule under it, and a band that
    /// held both would measure the fill and call it the frame.
    ///
    /// The lower edge is measured and not declared. Probed 2026-08-24 at scale 4
    /// with the predicate `chromaticMean` actually applies — alpha over a half
    /// and relative chroma over 0.3 — on both plates, at ratios 30, 60 and
    /// 99.999: the fill is at full strength from y = 16.00 down, reaches y = 16.25
    /// at alphas up to 0.88 with most of the row clearing the cut, and reaches
    /// y = 16.50 only at 0.04 to 0.48 on the light plate and 0.04 to 0.24 on the
    /// dark — where **not one pixel** clears it. From 16.75 up there is no fill
    /// colour at any alpha, until the frame itself takes one. (An earlier note
    /// here named a 0.54 row at 16.50 and made the edge turn on it; no row at
    /// 16.50 came out over half on either plate, and it is not in the data.)
    ///
    /// So `barFillBounds.maxY` of 16.5 would do, and the mutation says so rather
    /// than a comment: moving the edge exactly onto it leaves all 532 tests green
    /// (2026-08-24). The quarter point is slack, not a boundary — what it buys is
    /// a band whose lower edge is the first row carrying no fill colour *at all*,
    /// instead of one that rests on the alpha cut with 0.02 to spare. What the
    /// edge does have to stay above is the fill itself: widening the band to the
    /// whole bar reddens three tests (same day) —
    /// `testOverCapacityIsLoudOnTheFrameAndTheNumberToo`,
    /// `testTheFrameAndTheNumberAreInkBelowCapacityAndTakeTheRampAbove` and
    /// `testTheWarningIsNeverQuieterThanTheCalmStateItReplaces`.
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

    /// A burn ratio to colour a bar by, in per cent of the week's refill rate.
    ///
    /// One number and a flag, which is all the drawing reads — it used to take a
    /// pair of token rates and divide them, and the division moved into
    /// `FleetCapacity` when both sides of the figure became percentage points.
    private func ratio(_ percent: Double,
                       lowerBound: Bool = false) -> UsagePopoverView.HeadlineRatio {
        UsagePopoverView.HeadlineRatio(percent: percent, isLowerBound: lowerBound)
    }

    /// The appearance is always named, never left to the machine: the picture is
    /// no longer a template, so what colour it comes out is decided by an input —
    /// and a suite that inherited the appearance of whoever ran it would pass or
    /// fail by the time of day.
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

    /// The number sits flush with the right edge of the picture, so the `%` stays
    /// in one place while the digits in front of it come and go — and every
    /// figure the picture can draw fits the width that was measured for it.
    ///
    /// **The string is asked to fit as well, and that is what the ratio added.**
    /// While the number was the quota it had a top of 100 and three digits were
    /// all it could ever want; a ratio has no top, so a figure that outgrew the
    /// column would be drawn at a negative x and lose its leading digit to the
    /// image bounds — silently, and in the direction of calm.
    ///
    /// It is the laid-out width that is asked, and **not** where the ink starts,
    /// because where the ink starts cannot tell: measured 2026-08-24, `1000%`
    /// drawn flush right in this 27 pt picture comes back inked from 0.25 to
    /// 26.25 — the very same span as `999%` — since what falls off is the leading
    /// glyph and the one behind it has a left side bearing of its own. The
    /// bitmaps do differ, and that difference is where
    /// `testTheFigureIsCappedAtThreeDigitsAndNeverClipped` looks.
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

    /// No reading, no number — and the picture does not fall back to the weekly
    /// quota the way the popover's headline does.
    ///
    /// The two surfaces answer the same question and part here on purpose: the
    /// popover writes a caption under its lead saying which quantity it is
    /// showing, and 27 points of menu bar have no room for one. A number that is
    /// sometimes the ratio and sometimes the quota, with nothing to say which,
    /// is read as the one the item normally carries — and the wrong reading of
    /// the two is the calm one. A genuine zero *is* drawn, which is the other
    /// half of the same rule: "nothing measured" and "spending nothing" have to
    /// look different.
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

    /// The number is the spend ratio and not the week's mean — the whole of this
    /// round, asked of the drawing.
    ///
    /// Both figures are in the snapshot and they differ, so a picture drawing
    /// either one can be told from a picture drawing the other. Compared against
    /// separate renderings of the two rather than against a string, because what
    /// changed is what lands on the menu bar: the ink of `126%` is the assertion
    /// and the ink of `47%` is the control.
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

    /// The bar says the same thing the number does. Measured as area, because
    /// the outline spans the whole bar in every state and a span would not tell
    /// an empty bar from a full one.
    ///
    /// **And it stops at the refill rate**, exactly as the popover's lead bar
    /// does: past that point the length has nothing left to say and the figure
    /// under it says the rest. A scale stretched to three refills would put the
    /// point the whole reading turns on a third of the way along.
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

    /// The figure is capped at three digits, and what the cap buys is measured
    /// rather than argued.
    ///
    /// The ratio has no top — a fleet can burn many times what its week refills —
    /// while the column is a constant, because a status item that resizes itself
    /// drags every item to its left along with it. Drawn flush right, `1000%` at
    /// 32.75 pt starts at −5.75 in a 27 pt picture and the leading digit is
    /// clipped away by the image bounds. What lands is measured and not imagined
    /// (2026-08-24): the clipped `1000%` is **pixel for pixel the drawing of
    /// `000%`** — 1947 inked pixels, the same bitmap — against 2085 for `999%`.
    /// The loudest reading this item has turns into the calmest one it can draw.
    /// So `999%` is the top of the drawn scale, and it is a floor rather than a
    /// reading: the accessibility description, which has no width to run out of,
    /// says what was measured.
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

    /// The fill is a ramp over the load and not a step at capacity, and it is a
    /// ramp on a light menu bar and on a dark one both.
    ///
    /// Read off the drawn picture as a hue, because a hue is the thing the ramp
    /// is made of and a name is what the code already says. Three assertions
    /// have to hold together, and each covers a way the ramp can be broken while
    /// the others pass: the ends are **flat** (60 and 70 are one colour, 130 and
    /// 150 are one colour), the middle is **monotone** (a step would repeat a
    /// colour, a lookup table of hand-picked values could wander), and every
    /// sample matches the rule the popover paints with — which is what stops the
    /// two surfaces drifting into two ramps.
    ///
    /// A picture drawn in grey would fail rather than pass: the saturation of
    /// every sample is asserted, and `chromaticMean` returns `nil` where nothing
    /// was drawn in a colour of its own at all.
    ///
    /// The length and the colour are one quantity now, which is what this round
    /// changed: the fill is as long as the ratio and coloured by the same ratio,
    /// so every sample past the anchor is a full capsule in its own colour. It
    /// used to be the quota's length under the ratio's colour — two readings in
    /// one shape — and the ramp above the anchor was reachable only because the
    /// colour was asked separately.
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

    /// The one boundary the colour rules keep: the frame and the number are ink
    /// below capacity and take the ramp above it.
    ///
    /// Both halves matter and both are measured on both menu bars. Below, the
    /// picture has to stay calm — a status item that changed colour on every
    /// reading would be saying nothing with all of them — and the fixture is a
    /// hair under the boundary rather than well under it, so what is held is the
    /// boundary. Above, the colour is no longer one red: at capacity the frame is
    /// the ramp's green and by 130% it is the ramp's red, which is the whole of
    /// the correction.
    ///
    /// **The frame is read off `frameBand` and not off the whole bar**, which the
    /// fill's new length forced. A fixture at a mean of 0 used to leave the bar
    /// band to the frame alone; now the length is the ratio, so every sample past
    /// the anchor has a full capsule in it and the calm sample a hair under the
    /// anchor is a bar all but full — measuring the band would be measuring the
    /// fill and calling it the frame. Those rows sit above the fill's own bounds
    /// and only the stroke reaches them.
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
                // **The count is asked before anything is indexed**, and it is
                // asked as a failure rather than as a subscript. The four samples
                // are `rampSamples` filtered by the anchor, so moving the anchor
                // changes how many there are — and the anchor is this round's
                // most important constant, the one thing a mutation run has to be
                // able to examine. Indexed straight, an anchor at 112 leaves
                // three elements and takes the whole process down with
                // `Index out of range`, killing every suite after this one
                // instead of reddening.
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

    /// Past the refill rate the warning is on the frame and on the number, not
    /// on the fill alone — and what that is worth changed with this round.
    ///
    /// It used to be worth the warning existing at all. The fill's length was the
    /// quota mean, so at a mean near zero there was nothing to colour — measured
    /// at a load of 300%, the red ink was 0.00 pt² at a mean of 0, 0.25 at 1% and
    /// 2.12 at 3% — and that is the fleet just after its windows turn over, which
    /// is exactly when a 300% burn is worth knowing. With the length now the
    /// ratio itself, anything the boundary fires on has a full capsule under it,
    /// so the frame and the number are no longer the only marks: they are what
    /// separates 105% from 900%, both of which fill the bar to the same end.
    ///
    /// Asked of the frame's band and of the number's rows **separately**, and
    /// that separation is the test. Over the whole picture at once it could not
    /// fail for either half on its own: a red number satisfied it with a
    /// colourless frame and a red frame satisfied it with a colourless number.
    /// Both mutations were run and both were green — `warningColor` forced to
    /// `nil`, and the number's label asked for without a colour, which makes the
    /// whole on-demand colouring path deletable. Re-run 2026-08-24 against the
    /// ratio: both still redden this test.
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

    /// A band of the picture as it lands on the plate underneath: the pixels the
    /// drawing covers most fully, composited over that plate, and how legible the
    /// result is against it.
    ///
    /// **The most fully covered pixels rather than a fixed alpha**, because the
    /// two things this test compares are drawn at two different opacities — the
    /// calm frame at 0.55 of `labelColor`'s own 0.847, the warning at full
    /// strength — and a threshold that fitted one would find nothing of the
    /// other. Wherever a stroke is nominally drawn, its interior is where its
    /// alpha peaks; the pixels around that peak are the stroke and the rest is
    /// its antialiasing.
    ///
    /// The compositing is the point of the whole helper. The picture is drawn on
    /// transparency and the menu bar is what shows through it, so the colour a
    /// reader sees is neither the straight colour nor the stored one.
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

    /// The whole legibility of the status item, measured off the drawing on both
    /// plates at nine loads — and the rule that came out of it.
    ///
    /// **A warning may never be less legible than the calm state it replaces**,
    /// and this is where that is a measurement rather than a sentence. What was
    /// on screen before did the opposite, and it was rendered to be sure of it —
    /// the old ceiling and the old softened frame put back for one run
    /// (2026-08-18, light menu bar plate rgb 0.883): crossing capacity took the
    /// number from ink at 11.61 to 1 down to 1.62, and the frame from 4.41 to
    /// 1.35, with the worst of the band at 115% reading 1.89 and 1.41. The
    /// picture faded exactly where it was supposed to light up, in the band this
    /// fleet lives in.
    ///
    /// Three things are asked, on **both** plates, and each of them can fail on
    /// its own:
    ///
    /// 1. Every mark the ramp paints — fill, frame, number — clears
    ///    `contrastFloor(on:)` for the plate it is drawn on. That is the floor
    ///    doing its work, and it is asked of the *rendering* because the rule is
    ///    about what lands on the menu bar: the frame's own opacity is part of the
    ///    answer and the rule knows nothing about it.
    /// 2. The warning **frame** is at least as legible as the calm frame it
    ///    replaces. This is the ordering the review asked for, and it now holds by
    ///    construction rather than by arithmetic luck: the floor *is* the calm
    ///    frame's own contrast where that is the larger number. Measured, the calm
    ///    frame is 4.41 on the light plate against a floor of 4.50, and 4.67 on
    ///    the dark plate against a floor of 4.69.
    ///
    ///    **By construction as `≥`, and on the dark plate the hot end is the
    ///    equality case** — `contrastFloor(.dark)` is the analytic calm frame
    ///    exactly, 4.6924, and `legible` stops the moment it reaches the floor, so
    ///    from 124.9% up the warning aims at the very number it must not fall
    ///    under. What keeps this assertion off its knife edge is the rendering,
    ///    not the rule: the warning frame comes off the bitmap at 4.69 and the
    ///    calm one at 4.67, because the calm stroke is drawn at
    ///    `calmFrameOpacity` and loses more to partial coverage than an opaque
    ///    stroke does. A change that made the two strokes equally opaque would
    ///    take that 0.02 away and leave the comparison resting on rounding.
    /// 3. The colour is carried at all: every warning mark is chromatic, so a
    ///    floor met by driving the ramp to black on a light plate — or to white on
    ///    a dark one — would fail here rather than pass by being maximally
    ///    legible.
    ///
    /// **The guard that used to run all three on the light plate only is gone**,
    /// and it was hiding the whole defect: on the dark plate the ramp was left
    /// raw, so crossing capacity took the frame from the calm 4.67 down to 3.20 —
    /// the very fading this rule exists to forbid, surviving on half the surfaces
    /// because no assertion looked there.
    ///
    /// **What is deliberately not asserted is the same ordering for the number**,
    /// and the reason is arithmetic rather than taste: the calm number is ink at
    /// full strength — 11.61 to 1 on the light plate, 8.57 on the dark one — and
    /// no colour that keeps a hue reaches either. On the light plate the red
    /// measures 4.45 and driving it further means driving it to black, which is
    /// ink again; on the dark plate matching 8.57 asks the red for a saturation of
    /// 0.17, which is a pink and fails assertion 3 above. The floor is what is
    /// achievable; the drop is the price of a coloured number, and it is on the
    /// record here rather than hidden.
    ///
    /// **And legibility is not monotone across the warning band on a dark plate**,
    /// which is the one thing the fix could not buy. Measured: 5.36 at 100%, 6.83
    /// at 110%, 8.19 at 115%, 6.56 at 120%, 4.69 at 130% and above. The hump is
    /// the hue itself — a fully lit yellow is simply brighter against 0.2274 than
    /// a red can be made without ceasing to be red — so the band's worst load is
    /// its second-least legible mark. What the floor guarantees is the comparison
    /// that matters: no point of the band is quieter than the calm state it
    /// replaces. On the light plate the question does not arise, the whole ramp
    /// being pinned at the floor.
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

    /// A fill too narrow to see is not drawn — and the reading still reaches the
    /// reader, because it is printed under the bar.
    ///
    /// The threshold is one constant on one arithmetic (`MenuBarIcon.fillWidth`
    /// against `minimumVisibleFillWidth`), and it decides one thing: whether a
    /// shape a quarter of a point wide goes on screen as its own antialiasing. It
    /// used to decide a second thing as well — whether the description was
    /// allowed to name the ratio — because the ratio reached the picture as
    /// colour and nothing else, and a fill nobody can see carried nothing. The
    /// number is that ratio now, so `showsRatio` is gone and the description
    /// names the figure at every one of these widths.
    ///
    /// Measured rather than reasoned, at every figure either side of the
    /// threshold.
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

    /// The picture is resolved against the status item button's appearance, and
    /// the application's only while there is no button.
    ///
    /// They are not the same appearance: measured 2026-08-18,
    /// `NSApp.effectiveAppearance` was `NSAppearanceNameDarkAqua` while the
    /// status item's button was `NSAppearanceNameVibrantDark`, and forcing
    /// `NSApp.appearance` to `aqua` left the button where it was — the menu bar
    /// follows the wallpaper, not the system theme. Drawn against the app's, the
    /// ink is `labelColor` resolved in `aqua`, which is black, on a dark menu bar.
    ///
    /// Held through the drawing rather than as a name, for the reason the
    /// luminance test next door gives: what matters is that the ink came out
    /// light on a dark surface, and a name is what the code already says. The
    /// divergence in *kind* cannot be reproduced on this machine today (it needs
    /// a light theme under a dark desktop picture), so a view with an appearance
    /// of its own stands in for the button — which is exactly the property the
    /// rule turns on.
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

    /// Everything that is not the fill has to resolve against the menu bar it is
    /// drawn on, or it disappears when the bar goes dark. That was the system's
    /// job while the picture was a template; it is this file's job now.
    ///
    /// Measured as luminance rather than asserted from the colour's name: what
    /// matters is that the ink is dark on a light bar and light on a dark one,
    /// which is the property `NSColor.black` fails and `labelColor` has. The
    /// number and the frame are asked separately because they are two different
    /// mechanisms — the number's colour is baked into attributed strings laid out
    /// once at type initialisation and can only resolve late, while the frame's
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

    /// What the picture says, for a reader who cannot see it — and it no longer
    /// says "weekly quota", because the picture no longer draws one.
    ///
    /// Two things are in here that the drawing cannot carry, and both are the
    /// same fact about a description having no width: the `≥` of a ratio that is
    /// only a floor, and a figure the column would have had to cap.
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

    /// And it names the same reading the picture draws, at every figure either
    /// side of the one boundary in the colour rules.
    ///
    /// It used to have to agree with the *colour*, through `showsRatio`: the
    /// ratio reached the drawing as a shade and nothing else, so a description
    /// that named it over an uncoloured picture told the two readers two
    /// different things — measured with the gateway down over a stored 60%, the
    /// picture had not a coloured pixel in it while VoiceOver read out a number.
    /// The number is the ratio now, so the agreement is about digits: whatever
    /// the picture prints, the description contains, capping aside.
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

    /// What the owner of the picture redraws on, and what it refuses to draw at
    /// all.
    ///
    /// **It used to be a pair**, and the redraw had to watch both halves: a live
    /// token rate arriving every minute over an allowance arriving every ten, so
    /// a picture deduped on one of them held a stale ramp over a fleet that had
    /// gone past what it may spend. Both sides of the figure are now measured in
    /// the same pass out of the same series, so there is one thing to watch — and
    /// the `≥` beside it, which moves without the number and changes what the
    /// picture is allowed to claim.
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

/// The **week's** total: what it says, and what it says when it does not know.
///
/// It is no longer the row's second number — that is the rate, and `RowRateTests`
/// asks about it (§2.9). The week is drawn in two places now, the tooltip's
/// `Over 7 days` summary and the spend column of `--dump`, and this class covers
/// both plus the tooltip's hour-against-week arrangement. The layout of the row
/// itself is `RowLayoutTests`.
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

    /// A week with no hour under it — an ordinary project nobody has touched in
    /// the last 3600 s — says the week and nothing else. The row's right-hand side
    /// is blank there, and the week is still worth saying.
    ///
    /// The summary line wears `≥` on the same terms the breakdown's total does,
    /// and it is asked here because nowhere else asks it: every other fixture in
    /// this file hands the week all four counters, so the week's `≥` could have
    /// been dropped in the move to the tooltip without a single test noticing.
    /// The mark says a counter was never named, and the four are billed at
    /// different rates — a floor printed as an exact figure is the one thing the
    /// week's line cannot do.
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

    /// The two spend columns of `--dump`'s `Projects` table, held to the widest
    /// cell each of them claims to fit.
    ///
    /// Both columns in one test because the two widths are one decision: they are
    /// set to the same magnitude — four digits of millions with the `>=` a lower
    /// bound wears — and the rate's two extra characters buy `/h` rather than a
    /// digit (`ConsoleDump.spendColumnWidth` carries the measurement and the
    /// reasoning).
    ///
    /// The second half is the one worth having: one digit more does **not** fit,
    /// and `column` pads rather than cuts, so the cell that overflows is not
    /// truncated — every column to its right shifts on that row alone. Without it
    /// the first half is green for any width at or above the cell.
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

    /// And the table is held to those widths, which the test above does not do.
    ///
    /// It pins the constant to the cell; nothing pinned the composed line to the
    /// constant. Writing `8` at the call site instead of `spendColumnWidth` — the
    /// width the second review found too narrow for the reachable `>=123.45M` —
    /// left every test green while shifting every column right of the spend cell
    /// on the one row that fills it.
    ///
    /// So the property the widths exist for is what is asked: two rows whose spend
    /// cells differ in width put everything after the column at the **same
    /// offset**. Everything after it, rather than the next cell alone, because a
    /// column that gives way takes the whole rest of the line with it.
    ///
    /// The second half is what stops a *wider* literal from passing. A cell one
    /// character over the declared width shifts the rest by exactly one — `column`
    /// pads rather than cuts, which is the edge the test above names — so a column
    /// written wider than its constant is caught by the overflowing cell no longer
    /// overflowing.
    ///
    /// **The two spend columns, and only those, which is why the name says so.**
    /// The offsets are compared against a row whose spend cells are both `-`, so
    /// what this catches is a column whose width differs between the rows compared;
    /// widening `nameCell(for:width:)`, the indicator, the workspace word or the CPU
    /// cell uniformly moves the baseline with everything else and both halves stay
    /// green. Two columns here can overflow non-uniformly, and only one of them
    /// is guarded. The name is the guarded one: its cell is held to exactly 34
    /// by `testTheDumpCellKeepsTheCountWholeInsideItsColumn`. The CPU cell is
    /// the other, and nothing holds it at all — `cpuLabel` writes
    /// `"≥" + "%.0f%%"`, so a row reading `≥1000%` is six characters in a
    /// column declared 5, and `column` pads rather than cuts. Reaching it takes
    /// ten cores attributed to one session, which is why it is written down
    /// here rather than fixed in passing: the width and the fixture that would
    /// pin it are a change of their own.
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

    /// **The wording is the only thing that names the window, so it is pinned to
    /// the constant here.**
    ///
    /// Nothing divides anything (§2.9): the figure is whatever the gateway
    /// reported over `UsageStore.hourWindowSeconds`, and `/h` is the whole of the
    /// arithmetic. Move the constant to two hours and every surface prints twice
    /// the rate under the old label, with no arithmetic anywhere to go red —
    /// `testTheHourlyFigureIsAskedOverExactlyOneSlidingHour` holds the *request*,
    /// and the four label literals are invisible to it.
    ///
    /// What is new here is the pairing, not either half: the panel's suffix and
    /// the dump's are asserted by `testTheRateSaysItIsPerHour`, and the tooltip's
    /// sentence by `testTheTooltipBreaksTheHoursNumberIntoTheFourCounters`. This
    /// test is where the value and the wording are one statement, so that moving
    /// the constant produces a failure that names the strings to move with it.
    ///
    /// Three of the four are reachable and asserted below. The fourth is the
    /// `usage 1h:` label inside `ConsoleDump.printText`, which is private and
    /// prints a whole snapshot of the machine it runs on; it is named in the
    /// message instead.
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

/// A rotation that draws nothing and warns about nothing: it names one account no
/// row here is about, and says the gateway can still route to it.
///
/// Two properties, both load-bearing for a picture measured in ink bands. Naming
/// nobody the popover draws keeps every checkbox in these tests inert and every
/// switched-off note unwritten, so the rows are the rows the chart tests are
/// about. And naming somebody **eligible** keeps the orange line off the list:
/// since the warning learned to light up on a pass, a rotation of zero routable
/// accounts is a fleet with nowhere to send a request, so the obvious-looking
/// `{"accounts": []}` would put a warning under every picture measured here — a
/// stub's silence read as a verdict about the fleet. A rotation request that
/// *fails* writes a line of blame instead, which is the same problem by the other
/// road, so this answers.
private let quietRotation = """
{"accounts": [{"label": "elsewhere", "eligible": true, "disabled": false, \
"disabled_until": null, "disabled_reason": ""}]}
"""

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
///
/// `rotation` is the second question a pass asks — `/gw/status`, which the row's
/// checkbox is drawn from. Its default is `quietRotation`, for the reason written
/// there: a picture measured in ink bands must not be measuring this stub's
/// opinion of the fleet.
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

    /// Answers every history request from the fixture, the rotation from its own,
    /// and counts them all.
    ///
    /// Two fixtures rather than one because a pass asks two different questions
    /// and a stub that answers them alike cannot answer both. `GatewayStatus`
    /// decodes `accounts` strictly (`UsageModel`), and the history body has no
    /// such key, so a client that served the history to `/gw/status` too would
    /// throw on every pass: `rotationFailure` set, `switches` left `nil`, and
    /// "the gateway did not answer" the only rotation outcome this client can
    /// produce. Every state on the other side of that — a fleet named, a fleet
    /// answered empty, a switch that moves — would be unreachable here.
    ///
    /// An earlier note gave a different reason: that the history body decodes as
    /// a `GatewayStatus` naming no accounts, so one fixture would say "answered,
    /// nobody in the fleet" and blur the line between that and an answer nobody
    /// gave. That was true of the lenient `accounts` decoding and is not true of
    /// the strict one — the body no longer decodes at all — but the decision it
    /// justified is still the right one, so only the reason is rewritten.
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

    /// The whole reason this schedule is separate from `UsageStore`'s: a closed
    /// popover costs nothing. Not "almost nothing" — no request at all from
    /// anything the timer or the view model drives, which is every entry poked
    /// below: `fetch`, a change of the account list, and a change of period.
    ///
    /// **`setAccount` is the one entry that is not swept, and it is an exception
    /// on purpose rather than a hole.** It sends its request with no `isOpen`
    /// guard, and adding one would be a branch that cannot execute: its only
    /// caller is the binding inside `rotationSwitch`, a control that exists only
    /// on a popover that is up. It is also the one request here that is *meant* to
    /// outlive a close — the operator asked for it, a popover closes on any click
    /// anywhere on the screen, and that is why `close` cancels `fetchTask` and
    /// leaves `switchTasks` alone (`testASwitchAlreadySentOutlivesTheClose`).
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

        /// Returns once a request has **reached** the gate, whether or not it is
        /// let through.
        ///
        /// Which is the half that makes a race deterministic rather than likely:
        /// a test that clicks "while a pass is in the air" has to know the pass
        /// really is in the air, and the only moment that says so is the transport
        /// being entered. Started from `open`, the pass is a `Task` on the main
        /// actor whose body has not run yet, so a click sent straight after it can
        /// perfectly well be stamped first — and then the pass is genuinely the
        /// newer news and is *supposed* to win.
        func arrival() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                let already = reached
                if !already { arrivals.append(continuation) }
                lock.unlock()
                if already { continuation.resume() }
            }
        }
    }

    /// A gateway that answers the three questions separately: histories from the
    /// fixture, the rotation from `status`, and a switch from `switchAnswer` —
    /// each of which may be `nil`, which is that endpoint failing while the
    /// others go on answering.
    ///
    /// Either of the two may be held in a gate, and never both at once: what a
    /// gate buys is an order between a pass and a click, and a test holding both
    /// has stopped being able to state one.
    private func rotationClient(_ counter: RequestCounter,
                                status: String? = UsageFixtures.status,
                                switchAnswer: String? = UsageFixtures.switchAnswer,
                                gate: Gate? = nil,
                                statusGate: Gate? = nil) -> UsageClient {
        UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            counter.record(request.url)
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            let body: String?
            if url.path.hasSuffix("/history") {
                body = UsageFixtures.history
            } else if url.path == "/gw/status" {
                if let statusGate {
                    await statusGate.wait()
                    try Task.checkCancellation()
                }
                body = status
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

    /// A second click on a switch already in the air sends nothing.
    ///
    /// Which is not tidiness: the second click of a double click asks for the
    /// opposite, and with both requests out at once the account ends up wherever
    /// the network happened to deliver them — the operator's own two clicks
    /// deciding nothing. The guard is the label being in flight, so the state it
    /// is asked in is the state it exists for.
    ///
    /// The control half is the third click, after the answer has landed: without
    /// it the test would pass just as well against a model that never sends a
    /// second request at all.
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

        gateway.answers = false
        history.fetch()
        await history.fetchTask?.value
        XCTAssertEqual(history.switches?["acc3"]?.disabled, true,
                       "one failed request took the whole rotation off the screen")
        XCTAssertNotNil(history.rotationFailure, "and it was kept without a word about its age")
    }

    /// A rotation body with a hole where one account's switch should be takes the
    /// **whole** fleet to "unknown", rather than that one account to "in".
    ///
    /// The cost of the lenient reading is not one wrong row: `disabled` is what
    /// the box draws, so a missing one drew every box in the fleet ticked and
    /// armed, and a click on any of them sent a request about a state nobody had
    /// reported. Refusing the body is the state this app already knows how to
    /// draw — clear, inert, and blamed in the line underneath.
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

    /// And a rotation body with a hole where the **routing flag** goes raises no
    /// warning: it says "this app cannot say", not "there is nowhere to route".
    ///
    /// The lenient `?? false` was written when a zero count could only ever take
    /// the fleet line down, and that stopped being true in the round that made the
    /// count the verdict. Read leniently, this body — two accounts, neither
    /// switched off, both reported — comes out as a fleet with nowhere left to
    /// route and paints the loudest line on the surface out of a hole. The blame
    /// and the inert boxes are the honest reading of the same silence, and this app
    /// already draws them.
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

    /// A switch answer with no count in it blames the click and raises nothing.
    ///
    /// The same hole as next door on the worse path: this decoder runs on the
    /// operator's own click, so the lenient `?? 0` puts the orange line up in the
    /// very second they are looking at the checkbox they pressed — a false alarm
    /// with the pointer still on the control that seems to have caused it. The
    /// blame per label is what a click that would not go through leaves, and the
    /// tick does not move, both of which this surface draws already.
    ///
    /// The pass either side of the click answers `status`, where one account is
    /// routable, so the fleet has nothing to warn about at any point in this test —
    /// which is what makes the assertion a question about the hole.
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

    /// The state after a switch is the gateway's answer, and nothing else.
    ///
    /// Asked with an answer that **contradicts** the request — a disable answered
    /// with `disabled: false` — because that is the only fixture that can tell
    /// the two designs apart. Storing what was asked for looks right against
    /// every answer that agrees, and the day the gateway refuses a switch (the
    /// last usable account, an operator's rule, a race with another client) the
    /// row would show the click rather than the fleet.
    ///
    /// The contradiction is in `disabled` and in nothing else, and the count it is
    /// sent with is the contract's for this fleet at this moment — the derivation
    /// is written where the fixture is, beside the other switch answers, so that
    /// `testEverySwitchAnswerFixtureOnThisListIsABodyTheGatewayCouldHaveSent` can reach it.
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

    /// A switch the gateway would not take changes nothing, says why, and goes on
    /// saying it after a pass that went perfectly well.
    ///
    /// The first half follows from the state coming out of the answer: there is no
    /// answer, so there is nothing to write, and the row still says what the fleet
    /// last said.
    ///
    /// The second half is why the blame is kept per label rather than in the field
    /// the pass writes. A failed click has **no other mark on this surface at
    /// all** — by design the tick does not move — so the sentence naming it is the
    /// whole of the event, and a pass that succeeded used to overwrite it with
    /// `nil` on its way past. The operator was then left with a box in its old
    /// position and nothing anywhere saying their click had not worked.
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

    /// A switch that failed asks the gateway what actually happened.
    ///
    /// "Nothing changed" is true of a refused connection and **not** of a timeout,
    /// and `UsageClient.timeoutSeconds` is five: giving up on the answer is not the
    /// gateway giving up on the request, so a switch that timed out may well have
    /// been applied. Leaving the tick where it was then shows the state from before
    /// a switch that landed — confidently, with no mark of doubt on the box itself —
    /// and the operator's next click undoes what they wanted. One extra pass is the
    /// cheaper of the two.
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

    /// What the switch cost the fleet is shown, not counted and dropped.
    ///
    /// The gateway answers a switch that leaves nothing usable with a zero count,
    /// which is the one thing on this path the operator cannot work out from the
    /// checkboxes. What goes on screen is this app's own wording of that verdict:
    /// the sentence beside the count says `fleet`, which §4 keeps off every string
    /// a person reads, and being a constant it says nothing the count does not.
    ///
    /// The second click is the pair the contract sends the other way round —
    /// `eligible_accounts: 1` with `warning: null`, because `_switch_payload`
    /// writes the sentence as `None if eligible else "…"` — and the line has to go
    /// on that count. Both bodies here are ones the gateway can actually send: the
    /// pair never comes apart, and
    /// `testEverySwitchAnswerFixtureOnThisListIsABodyTheGatewayCouldHaveSent` is what holds
    /// them to it.
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

    /// A switch already on its way outlives the popover closing.
    ///
    /// The operator asked for it, and a popover going away is not a change of
    /// mind — it is what happens on the very next click anywhere else on the
    /// screen. `fetchTask` is cancelled there and this one is not, which is why
    /// they are two fields rather than one.
    ///
    /// The gate is what makes the difference visible: the request waits until
    /// this test lets it through and then asks whether it was cancelled, so a
    /// `close` that reached it comes back as a failure rather than as a slightly
    /// later success.
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
    /// `open` fires a pass at once and a switch is one short POST against a pass's
    /// `/gw/status` plus a history per account, so a click in the first fractions
    /// of a second is answered *first* and the pass lands on top of it with the
    /// state from before the click. The tick goes back where it was and stays there
    /// until the next pass, up to a minute — and what that reads as is not a
    /// flicker but "the click did nothing", so the operator clicks again and undoes
    /// by hand what they had already done.
    ///
    /// What carries that is the **ratio**, four requests of some 208 KB against one
    /// small one, and not an absolute — which moves with the window the pass asks
    /// for as well as with the fleet's stored history and the machine's load, so the
    /// window is named: a pass asks for `period.seconds` and the period defaults to
    /// `HistoryPeriod.day`. Probe of 2026-09-06 07:25Z, plain GETs, load average 5.6
    /// falling to 5.4 over the run: ten day passes back to back, issued in parallel
    /// exactly as the client issues them, took 0.052–0.083 s, against 0.011–0.017 s
    /// for ten bare `/gw/status` calls in the same run; the day histories are 86289
    /// / 9438 / 110764 bytes to the status body's 6222, 212713 in all. The figures
    /// that stood here before were the **48 h** window's — `UsageStore`'s, never
    /// this popover's. The POST is not timed at all (no live `disable`/`enable` may
    /// be fired while the fleet is being operated from the CLI); its side of the
    /// comparison is its shape. `UsageHistoryModel.applyRotation` carries the same
    /// numbers and the other two windows beside them.
    ///
    /// The gate holds `/gw/status` and the test waits for it to be **reached**
    /// before clicking. Without that wait the ordering is genuinely undecided —
    /// the pass is a `Task` on the main actor whose body has not run yet, so its
    /// request can be sent after the click, and then the pass is the newer news
    /// and is supposed to win.
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

    /// And a label with a click still in the air is left alone too.
    ///
    /// It has no answer yet to be newer than the pass, so the stamp cannot hold it
    /// — but the operator is watching that box, and letting a pass write the
    /// pre-click state under it says the same wrong thing for the length of the
    /// round trip.
    ///
    /// The second pass answers something **else** about `acc2`, because a pass
    /// that overwrote the row with what was already there and one that left it
    /// alone draw the very same picture. `acc3` moving the other way is the
    /// control that the pass landed at all.
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

    /// A pass that found somewhere to route takes the warning down.
    ///
    /// The warning is about the fleet — "is there anywhere left to send a
    /// request" — and the fleet moves without this app: an account put back from
    /// the command line, or a quota window that reset, ends the state the sentence
    /// warns about. While only a switch answer could clear it, the orange line
    /// stood from the click that raised it until the app was restarted, on every
    /// opening of the popover, with nothing beside it to say how old it was.
    ///
    /// It is also the control on the hold next door: the pass here asks *after*
    /// the click was answered, so it is the newer news and is supposed to win. A
    /// hold that kept the line up on every pass following any click at all would
    /// pass that test and fail this one.
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

    /// **The count is the verdict and the sentence is only its wording**, so a
    /// pass raises the line as well as taking it down.
    ///
    /// A fleet with nowhere to route used to say nothing at all unless this very
    /// session of this very app had been the one to empty it: somebody's
    /// `claude-gw disable` from the command line, every account in backoff at
    /// once, or a restart after one's own click all left the popover silent while
    /// every client request came back 429. The two counts are one measurement at
    /// two moments — the gateway computes `routableAccounts` and
    /// `eligible_accounts` with the same `is_eligible` — so the pass's count is
    /// as good an answer as the switch's.
    ///
    /// The fixture is a fleet **nobody has switched off**, which is the price of
    /// this and is paid on purpose: `eligible` folds the five-hour window in with
    /// the operator's switch, so the line appears with every checkbox ticked when
    /// the windows have merely filled. That is the state the sentence describes.
    ///
    /// Two mutations die here and they are the two halves of the finding. Not
    /// raising on a pass leaves the first assertion `nil`; going back to "the
    /// sentence raises and the count takes down" clears on the same pass, because
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

    /// And a pass that left before the operator's own click may not take the
    /// warning down either.
    ///
    /// The same race the tick is held against, in the half of `applyRotation`
    /// where the rule was written down and then not applied — and the cost is the
    /// worse of the two. A tick put back wrongly is repaired by the next pass a
    /// minute later; a warning taken down wrongly can be put back by nothing but
    /// another click, so it is gone until the operator happens to throw a switch
    /// again. The scene is real: the popover is open, the minute pass is in the
    /// air, the operator switches the last usable account off, the short POST
    /// answers first with the sentence, and tens of milliseconds later the pass
    /// lands carrying the fleet from before the click.
    ///
    /// The gate holds `/gw/status` and the test waits for it to be **reached**, so
    /// the pass really did leave first rather than probably.
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

    /// And two clicks of the operator's own, answered in the other order from the
    /// one they were asked in: the count that stands is the one asked for **last**.
    ///
    /// `setAccount` guards one label at a time, deliberately — a second click on a
    /// *different* account while the first is in the air is a thing an operator
    /// does, and there is nothing to stop it. But the count is the fleet's and
    /// moves with every switch, so two answers carry two readings of one quantity
    /// and the wire decides nothing about which of them measured it later. Both
    /// accounts routable, `acc2` switched off (its answer counts 1, `main` being
    /// what is left), `main` switched off without waiting (its answer counts 0,
    /// and the sentence with it); `main`'s answer lands first and the orange line
    /// goes up, `acc2`'s lands second and — unordered — takes it back down. Every client request is then
    /// answered 429 with nothing on screen saying so until the next pass, up to
    /// `UsageHistoryModel.refreshSeconds` later. It is the expensive direction of
    /// the two, for the reason `applyRotation` gives about the pass: a tick put
    /// back wrongly is repaired by the next pass, a warning taken down wrongly by
    /// nothing but another click.
    ///
    /// A gate **per label** is what makes the order a fact rather than a
    /// likelihood: each answer waits until this test lets that label through, so
    /// "asked first, answered last" is the arrangement and not the weather. The
    /// per-label writes are ordered by nothing and are meant not to be — an answer
    /// is authoritative about its own account whatever the fleet count is doing,
    /// which is what the last assertion reads.
    ///
    /// **The settling pass this ends on is answered with the fleet the two clicks
    /// left behind** — it is asked once both switches have landed, so an
    /// always-routable body is one the gateway could not have sent, and a test
    /// reading a switch off such a pass reads the fixture rather than the gateway
    /// (`UsageFixtures.statusWithBothRoutableAccountsSwitchedOff`, where that rule is
    /// written down). **No assertion here reads what that pass answered**, which is
    /// why putting it right moved no number — and each of the six is covered, in
    /// three groups. The opening one is made before either click, when the only pass
    /// ever asked is the sitting's own. The middle two are safe by something
    /// stronger than timing: the first reads `inFlight`, which no pass writes, and
    /// the second reads the count `main`'s own answer put up at a moment when the
    /// settling pass does not exist at all — `settle` is `inFlight.isEmpty &&
    /// clicksOverlapped`, `acc2` is still in the air, and so `main`'s task asks for
    /// no pass (checked with a throwaway probe beside it: `inFlight` is `["acc2"]`
    /// there and exactly one `/gw/status` request has been recorded, the sitting's
    /// own). And the three at the end are read in the same actor turn as the `await`
    /// on `acc2`'s task, before the pass started inside it can land. That is
    /// a fact about today's assertions rather than a licence — an assertion added
    /// here that does read the tick or the orange line off that pass then reads the
    /// gateway, which is the whole of what this body buys.
    ///
    /// Mutation, 2026-09-06: drop the ask-instant guard from `applyRoutable` and
    /// this is the one test of 668 that reddens — re-run the same day over the scene
    /// above, once the settling pass had stopped being answered with the fleet from
    /// before the two clicks, and it is still the one and only, now of 671.
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

    /// And the count is settled by **asking**, once the last click of two that
    /// overlapped has landed.
    ///
    /// The guard above orders two answers by the moment this app asked for them,
    /// which is the nearest thing this side has to the order the gateway measured
    /// in — and only the nearest. The gateway counts inside the handler that writes
    /// the switch, with no suspension between the two, so each answer is consistent
    /// in itself; which of two handlers ran first was settled by two connections
    /// arriving at one single-threaded loop. Processed out of send order, the true
    /// final count is in the answer to the *earlier* question, and the ask-instant
    /// refuses it either way round. So what closes the class is not an ordering rule
    /// but an observation: one pass, asked when nothing is in the air any more, and
    /// the gateway counts the fleet once for everybody.
    ///
    /// **And not before.** While another click is out, `isStale` refuses whatever
    /// count a pass brings back, so a pass fired then is 208 KB spent to be ignored
    /// — and the click still out there brings its own settling pass when it lands.
    ///
    /// **And not for a click that went out alone**, which is the other half of the
    /// gate and lives in `testALoneClickIsSettledByItsOwnAnswer` next door: two
    /// POSTs in the air at once is the whole of what the ask-instant cannot order,
    /// and `fetch` cancels the pass in flight, so settling after every click would
    /// take `isStale`'s ordering half out of reach altogether. Both clicks here
    /// overlap, which is what puts this test on the settling side of that gate.
    ///
    /// Counted in `/gw/status` requests, which is one per pass and the one thing on
    /// this path nothing else sends. A gate per label makes the middle state a fact
    /// rather than a likelihood: `acc2` is let through while `main` is still held,
    /// so the assertion about "a click still in the air" is asked in the one
    /// arrangement it is about. Each assertion is made after awaiting `fetchTask`,
    /// because a pass fired here would be a `Task` whose request has not necessarily
    /// reached the counter yet — without that wait the "no pass" half would pass
    /// under its own mutation about half the time.
    ///
    /// **And the settling pass is answered with the fleet the burst left behind**,
    /// for the reason recorded next door and at
    /// `UsageFixtures.statusWithBothRoutableAccountsSwitchedOff`: it is asked once
    /// both switches have landed, so an always-routable body is one the gateway
    /// could not have sent. **No assertion here reads that body either**, which is
    /// why putting it right moved no number: this test counts `/gw/status` requests
    /// and reads `inFlight`, and neither of those asks what a pass answered. An
    /// assertion added here that does read the tick or the count off that pass then
    /// reads the gateway rather than the fixture.
    ///
    /// Mutations, re-run 2026-09-06 against a suite of 671 — this test,
    /// `testALoneClickIsSettledByItsOwnAnswer` and
    /// `testABurstsOverlapIsNotChargedToTheNextLoneClick`, the last of
    /// which reddens under both of these and did not exist when they were first run
    /// at 670. (Every record that says 668 — one above this line, three below it and
    /// one in `UsageTests` — is older still, from the same morning, before any of
    /// the three. Counted as records, not as mentions: the one at
    /// `testNoStringOnScreenNamesTheMetricByItsInternalWord` says 668 three times
    /// and is a single sitting.) Both were run again the same day over that
    /// third test's reworked scene: its stub now answers the settling pass with the
    /// fleet the burst had just written, and it has gained a control on that pass, so
    /// which of its assertions move had to be measured rather than carried over.
    /// Deleting the settling `fetch()` reddens the last assertion here at 1 pass
    /// against 2, and in the third test its settling control and its final count,
    /// both at 1 against 2 — 2 tests, 3 assertions, nothing else in the suite.
    /// Dropping only the `inFlight.isEmpty` half of `settle` reddens the middle
    /// assertion here at 2 against 1 — a pass asked with `main` still out — and then
    /// the last one too, at 3 against 2, because the extra pass is still counted when
    /// the burst ends; the third test reddens on those same two of its three counts
    /// for the same reason, both at 3 against 2, so 2 tests and 4 assertions. Its
    /// `disabled` control stands through both, and through the other two mutations of
    /// that machine as well: it falls only to its own, which is recorded with it. The
    /// third mutation of `settle` belongs to the other half of the gate and is
    /// recorded next door. The deletion and the dropped half were then run a third
    /// time, over the scene **this**
    /// test now sets — its settling pass answered with the fleet the burst had
    /// written, as the third test's already was — and every count above came back
    /// unchanged, which is what a change that moves only what a body says is allowed
    /// to do. Allowed, not guaranteed: it was measured because the scene moved, not
    /// carried over because the reasoning said it could not.
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

    /// And a click that went out **alone** is settled by its own answer: no pass.
    ///
    /// The settling pass next door exists for the one arrangement the ask-instant
    /// cannot order — two POSTs in the air at once, whose handlers the gateway may
    /// have run in either order. A lone POST is never ordered against another POST.
    /// The only other count it can meet is a pass's, and those two are ordered
    /// correctly in both directions already: `isStale` refuses a pass whose
    /// ask-instant is older than this answer's confirmation, and `applyRoutable`
    /// refuses a count asked for earlier than the one already on screen.
    ///
    /// So a pass here would be paid for nothing — and not only in bytes. `fetch`
    /// cancels `fetchTask`, so a settling pass after **every** click destroys
    /// whatever pass is in the air, and that pass is precisely what `isStale`'s
    /// second half is written to refuse. Settle after every click and no pass asked
    /// before a confirmation can ever land, while a pass asked after one is younger
    /// than it by construction: the half stops being able to fire at all. That is
    /// what the two `testAPassThatLeftBeforeTheClick…` tests read as when it is
    /// tried — their subject becomes unreachable rather than wrong.
    ///
    /// Counted in `/gw/status` requests, one per pass. `fetchTask` is awaited before
    /// the count for the reason given next door: a pass fired here would be a `Task`
    /// whose request has not necessarily reached the counter yet.
    ///
    /// Mutation, re-run 2026-09-06 against a suite of 671 and again the same day over
    /// the reworked scene of the fourth test below: dropping the `clicksOverlapped`
    /// half of `settle`, so that every click settles, reddens **four** tests. This one
    /// by name, at 2 passes against 1; both
    /// `testAPassThatLeftBeforeTheClickDoesNotPutTheTickBack` — the tick reading
    /// `false` where the click put `true` — and `…DoesNotTakeTheWarningDown`, whose
    /// warning comes back `nil`, the pair of them having had their pass cancelled by
    /// the settling one and replaced by a pass asked after the click, which is then
    /// admitted and writes the pre-click fixture; and
    /// `testABurstsOverlapIsNotChargedToTheNextLoneClick` on its final count **alone**,
    /// at 3 against 2 — that one is the fourth, added after the **three** this record
    /// used to say, and the count is the whole of what its arrival changed. Alone is
    /// the half of it worth measuring twice: the settling control that test has since
    /// gained stays green here, where the neighbour's two mutations both redden it, so
    /// the shape of the failure inside that test is what separates this half of the
    /// gate from the other. The `testAPassThatLeftBeforeTheClick…` pair reddening is
    /// the price stated above, measured: the guard is not weakened by the mutation, it
    /// is left with nothing to refuse.
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

    /// And "sent on its own" is a fact about **this** click, not about the sitting:
    /// a burst that overlapped is charged to itself and to nothing after it.
    ///
    /// `clicksOverlapped` is recorded when the second click of a burst goes out —
    /// by the time the answers come back `inFlight` has emptied and the overlap has
    /// left no trace — so it is a flag with a life of its own, and the only place it
    /// goes out again is the line beside the one that reads it. Delete that line and
    /// the sitting's first overlapping burst arms it for good: every lone click
    /// afterwards takes the settling path, which is not merely a wasted pass.
    /// `fetch` begins with `fetchTask?.cancel()`, so each of those clicks destroys
    /// whatever pass is in the air — and a pass asked before a confirmation is
    /// exactly what `isStale`'s second half is written to refuse. That is the
    /// mechanism `testALoneClickIsSettledByItsOwnAnswer` next door keeps out of the
    /// code; without this test it walks back in through the one arrangement neither
    /// of the two covers, because that one ends when the burst lands and this one
    /// starts from a model that never had a burst.
    ///
    /// So the burst here is the neighbour's, and the third click is a *later* lone
    /// one in the same sitting: `acc2` and `main` both switched off with both POSTs
    /// in the air at once, the settling pass awaited, and then `main` put back on
    /// its own.
    ///
    /// **Every body is one the gateway could have sent at that moment**, and the
    /// count runs 2, 1, 0, 0, 1 across the five answers.
    /// `statusWithTwoRoutableAccounts` opens the sitting — `acc2` and `main`
    /// routable, `acc3` parked from the evening before, so 2. Taking `acc2` out
    /// leaves 1 (`switchAnswer`), and `main` after it leaves 0
    /// (`switchAnswerWithWarning`). The settling pass then reads the accounts table
    /// those two POSTs have just written to, so what it gets is
    /// `statusWithBothRoutableAccountsSwitchedOff`: both of them off, counting 0,
    /// agreeing with the answer that took the last one out. Putting `main` back
    /// gives 1 again (`switchAnswerPuttingTheAccountBack`).
    ///
    /// **That agreement is the whole of what the second control can read.** With
    /// `statusWithTwoRoutableAccounts` answering the settling pass — which is what
    /// stood here — `main` is back to `disabled: false` before the lone click is
    /// ever sent: `inFlight` is empty by then and both confirmations are older than
    /// that pass's `askedAt`, since it is asked from inside the last switch task
    /// after that task wrote its own, so `holds` refuses both labels and
    /// `applyRotation` overwrites the dictionary with the pass's body whole. The
    /// control then read `false` whether the lone click's answer landed, failed, or
    /// was never sent — while a *failed* click takes `setAccount`'s failure branch,
    /// where `fetch()` is called unconditionally, which is precisely the 3 passes
    /// against 2 the final assertion is written to catch. With the settling pass
    /// answering for the fleet it was actually asked of, `main` stands at
    /// `disabled: true` when the lone click goes out, and nothing but that click's
    /// own answer puts it back.
    ///
    /// No gate holds either half of the burst: `setAccount` is synchronous up to
    /// `inFlight.insert`, and the two calls stand side by side with nothing that
    /// suspends between them, so both are in the air before either can be answered.
    /// Counted in `/gw/status` requests, one per pass, and each count is taken after
    /// awaiting `fetchTask` — a pass fired here would be a `Task` whose request has
    /// not necessarily reached the counter yet.
    ///
    /// Mutations, 2026-09-06, against a suite of 671, every one of them run over the
    /// scene above rather than inferred from the one it replaced — the settling pass
    /// stopped being answered with the fleet from before the burst in the same round
    /// that wrote this record. Deleting the reset — the `if inFlight.isEmpty {
    /// clicksOverlapped = false }` of `setAccount` — still reddens this test and
    /// nothing else in the suite, at 3 passes against 2, and both controls stay
    /// green: the burst settles once as it should, and that click's answer lands —
    /// it is only charged for a pass it did not ask for.
    ///
    /// And the control's own, which is what says it can fail and what it fails for:
    /// have the stub throw for the lone `enable` instead of answering it, and the
    /// control reddens on `main` still reading `disabled: true` — the settling
    /// pass's — with the final assertion reddening after it at 3 against 2, because
    /// the failure branch fetches unconditionally. Two failures in line order, and
    /// the pair of them is what separates the two cases: a control that stands
    /// while the count is wrong means the lone click was charged for the burst, and
    /// one that falls means its own answer never landed. Against the body that
    /// stood here before, the same thrown `enable` reddens the final assertion
    /// **alone** — 1 failure, not 2 — which is exactly the reading the control was
    /// meant to rule out; measured, not remembered, by putting that always-routable
    /// `/gw/status` answer back under the same thrown `enable`, with everything else
    /// of today's scene left standing.
    ///
    /// No mutation of the settling machine moves that control: it stands under all
    /// four of them — the `fetch()` deleted, either half of `settle` dropped, the
    /// reset deleted — and falls only to the stub above it. Which is what a control
    /// is for, and it is measured across the four rather than assumed from the one
    /// it was written beside.
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

    /// A failed click's blame does not follow the operator into the next sitting.
    ///
    /// It is cleared by the next click on the same label and by nothing else, so
    /// an hour after a dead WireGuard came back — the gateway answering, every
    /// checkbox live — the grey line still read "acc2: unreachable" as though it
    /// had just happened. A fact about the past shown as the present (§2.4), with
    /// the operator's own control beside it.
    ///
    /// `open` and not `close`, which the message survives on purpose: a popover
    /// closes on any click anywhere on the screen, including one that never came
    /// near it. And nothing is lost by clearing on the way in, because `open`
    /// fires a pass in the next line — what the blame stands for is a tick that
    /// may no longer be the fleet's, and the pass is what settles that.
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

    /// And neither do the fleet's own two, for the same reason and with the same
    /// remedy one line below them.
    ///
    /// Nothing runs while the popover is shut, so on the way back in all three of
    /// these lines stand for a tick that may be an hour old — the orange one
    /// loudest of all, with no age drawn anywhere near it. The `open` that clears
    /// them fires a pass in its next line, which is exactly the thing that settles
    /// what they stand for.
    ///
    /// Both are put up first, and it takes two passes to do it: a pass that
    /// answers a fleet with nowhere to route raises the warning, and a pass that
    /// cannot ask writes the blame while **keeping** the warning — an answer
    /// replaces what is held, a pass that got none leaves it alone. The assertions
    /// after the reopen are made before the new pass has run: `open` starts it as a
    /// `Task` on this actor, so nothing has landed yet and what is read is what the
    /// operator sees on the way in.
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

    /// Neither does the rotation itself, and it is the one of the four that binds
    /// hardest.
    ///
    /// The other three are messages about a moment; this one is a **control**. An
    /// hour-old reading survives a shut popover — `close` leaves it alone and
    /// `NSPopover` keeps the content view controller — so on the way back in the
    /// boxes would be drawn from it, ticked as current and clickable, with the two
    /// lines that might have explained their age cleared in the statements just
    /// above. §2.4's rule about a confidently wrong reading weighs more on a
    /// control than on a number, because acting on one changes the fleet:
    /// `disableAccount` sends no body, and the gateway's `_parse_disable_body`
    /// reads no body, an empty body and `{}` alike as `DISABLED_NO_DEADLINE`, so a
    /// click on a stale tick turns somebody's timed parking of an account into an
    /// indefinite switch-off.
    ///
    /// Asked of the **model**, not of the paint, and that is not a shortcut: a
    /// checkbox comes out of `ImageRenderer` as the same 784 inked pixels in all
    /// four of its states, so no rendering on this surface can tell a cleared
    /// rotation from a stale one. `switchAppearance` and `switchHelp` are asked
    /// beside it because they are what `nil` costs on screen — a clear box nobody
    /// may click, and a tooltip that says the gateway did not say.
    ///
    /// The pass afterwards is the control: cleared and then filled in again is the
    /// state the operator meets, and without it the test would pass just as well
    /// against a model that never learned a rotation at all.
    ///
    /// Mutation, 2026-09-06: leave the rotation alone in `open` — delete the two
    /// lines that carry the labels in flight over and take everything else to
    /// `nil` — and this test reddens, on all four of its assertions. It is not the
    /// only one: `testAClickStillInTheAirKeepsItsRowAcrossTheReopen` next door
    /// reddens with it, 2 of 668, because that mutation removes both halves of the
    /// rule at once. The half this test owns is separated by the other mutation,
    /// `switches = nil` written back unconditionally, which leaves this one green
    /// and reddens only next door.
    ///
    /// And a third, run 2026-09-06 against a suite of 670: `switches = heldOver`
    /// with no ternary, so that an empty carry-over stands as `[:]` — "the gateway
    /// said nobody" written where this app was told nothing. It reddens the first
    /// assertion here and four more tests, five in all, every one of them on an
    /// `XCTAssertNil` reading `"[:]"`: `testARotationNobodyAnsweredIsNotAnEmpty`
    /// `Fleet`, `testARotationBodyMissingASwitchLeavesEveryBoxUnknown`,
    /// `testARotationWithNoRoutingFlagRaisesNoWarningAtAll` and, on the paint side,
    /// `testTheReasonTheSwitchesWentInertIsDrawnWithNoAccountsToDrawItUnder`. They
    /// all reach it the same way: `open` on a model that has never learned a
    /// rotation carries nothing over, and the ternary is the only thing that keeps
    /// that from becoming an answer.
    func testTheRotationItselfDoesNotSurviveIntoTheNextSitting() async {
        let counter = RequestCounter()
        let history = UsageHistoryModel(client: rotationClient(counter), defaults: freshDefaults())
        history.open(labels: ["acc2"])
        await history.fetchTask?.value
        XCTAssertEqual(history.switches?["acc3"]?.disabled, true,
                       "the first sitting learned no rotation, so there is nothing to clear")

        history.close()
        history.open(labels: ["acc2"])
        defer { history.close() }

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
    }

    /// With one exception, and it is the label the operator is waiting on: a click
    /// still in the air carries its reading across the reopen, and the new
    /// sitting's first pass may not write under it.
    ///
    /// `close` does not cancel a switch already sent — the operator asked for it —
    /// so a POST can be in the air for as long as `UsageClient.timeoutSeconds`
    /// behind a shut popover, and the popover can be opened again inside that. The
    /// hold `applyRotation` puts on an in-flight label works by laying the value
    /// this app **already has** over the pass's, so with the rotation wiped there
    /// was nothing to lay and the first half of `holds` did nothing at all: the
    /// pass `open` fires answers in a fraction of a second, well before the POST,
    /// and the box the operator is at that moment switching was drawn from the
    /// gateway's pre-click reading. Inert, so no wrong click could come of it —
    /// and confidently wrong all the same, which is the thing the whole control is
    /// built not to be (§2.4).
    ///
    /// **How this differs from `testAPassLeavesAloneALabelWithAClickStillInTheAir`,
    /// which the same hold is supposed to cover:** there the successful pass runs
    /// *before* the click and the popover never closes, so the rotation is
    /// populated when the second pass lands and the hold has something to lay.
    /// That is why it went on passing with the wipe in place. Here the close and
    /// the reopen fall between the click and the pass, which is the only order in
    /// which the dictionary is empty underneath a label in flight.
    ///
    /// The scene: `acc3` was parked for 22 hours from the command line the evening
    /// before (`status`), the operator clicks to put it back, closes the popover
    /// by clicking elsewhere and opens it again — and by then the parking has
    /// expired on its own, so the pass has something **else** to say about `acc3`.
    /// Without that difference a pass that rewrote the row with what was already
    /// there and one that left it alone would draw the very same picture.
    ///
    /// Asked of `switchAppearance` rather than of the paint, for the reason
    /// `testTheRotationItselfDoesNotSurviveIntoTheNextSitting` gives: the checkbox
    /// renders as the same blank plate in all four of its states.
    ///
    /// Mutation, 2026-09-06: go back to wiping the rotation unconditionally
    /// (`switches = nil`) and this is the one test of 668 that reddens — on the
    /// carry-over assertion and on the tick under the click alike, which is the
    /// pair that says the rule is worth something rather than only present.
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

    /// The three stamps that decide whether a pass is older news than the operator
    /// run on a clock that cannot step backwards.
    ///
    /// None of them is ever drawn — they exist only to be compared with each other
    /// — and the wall clock does step back: an NTP correction, a wake from sleep. A
    /// step back just after a switch answer leaves that answer stamped in the
    /// future, and from then on every pass looks older than it, so the gateway
    /// stops being allowed to refresh the label until the clock catches up.
    ///
    /// Asked of `Rotation.askedAt`, which reaches the other two for free.
    /// `holds` compares `switchConfirmedAt[label]` with this very field, and
    /// `applyRoutable(_:askedAt:)` takes a `ContinuousClock.Instant` and is handed
    /// this field by a pass and `setAccount`'s own local by a click — so the
    /// compiler will not let any of the three be drawn from a different clock than
    /// the rest. What a mutation back to `Date()` therefore has to change is this
    /// type, and this is where it is read.
    ///
    /// **One question, and one is enough.** An `XCTAssertFalse(askedAt is Date)`
    /// stood under the assertion below and was deleted: a value cannot be both
    /// types, so it could only fail where the first has already failed — a check
    /// that cannot answer "no" on its own, carrying the louder message of the two
    /// and reading to the next person like a working control. What it said is
    /// worth keeping, so it is said here and in the message that is left.
    func testTheStampsThatDecideAStalePassCannotStepBackwards() throws {
        let rotation = UsageHistoryModel.Rotation(state: nil, routable: nil, failure: nil,
                                                  askedAt: UsageHistoryModel.stamp())
        let askedAt = try XCTUnwrap(Mirror(reflecting: rotation).children
            .first { $0.label == "askedAt" }?.value)
        XCTAssertTrue(askedAt is ContinuousClock.Instant, """
            the hold is decided on \(type(of: askedAt)), and a wall clock steps back: one \
            correction after a switch answer and that label stops taking the gateway's word \
            until the clock catches up
            """)
    }

    /// A switch must not need the main thread either.
    ///
    /// `load` has been asked this since it existed; `switchAccount` had not, and it
    /// is the half that runs from a `Task` started inside a `@MainActor` method,
    /// which inherits the main actor. Only `nonisolated` on the declaration keeps
    /// the request off it, nothing warns under `-strict-concurrency=complete` when
    /// that is lost, and what it costs is up to `UsageClient.timeoutSeconds` — five
    /// seconds — of a popover that is open on screen and has stopped redrawing.
    ///
    /// Timed rather than open, so a regression is a red test and not a run that
    /// never comes back (§6).
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

    /// And the largest step there is — a week rolling over — survives to the
    /// sample. A filter that took the corner off this would be lying about the one
    /// event the chart exists to show.
    ///
    /// The window is what makes the whole rule true: it is hard rather than
    /// sliding, so utilisation inside one only accumulates. The live history holds
    /// two of these corners, 100 → 0 and 99 → 0, each followed by a `resets_at`
    /// exactly 7×24 h later (§4).
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

    /// The last reading is never moved, and that is a requirement rather than an
    /// omission: the freshest figure is the one thing the rule may not invent on
    /// the gateway's behalf, so the line ends at the reading that arrived (§4).
    ///
    /// Under the median this held by itself — the last element was outside the
    /// window, and a reading with holes after it was declined because the window
    /// could not reach across a `null`. This rule looks only backwards, so a hole
    /// on the right stops nothing and the exemption has to be written down. It is:
    /// the pass ends at the last reading rather than at the last element, and both
    /// forms are asked here.
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

    /// The rule's properties, asked of a series no `XCTAssertEqual` holds in place.
    ///
    /// Two loops used to stand in the test above — "the result never falls", "the
    /// filter invented nothing" — over an array pinned by an exact equality on the
    /// line before them. Green equality, and neither could fail; red equality, and
    /// they said the same thing a second time: a branch that cannot execute, in
    /// test form. So the input here is generated instead, and generated
    /// deterministically — a fixed seed through a linear congruential step, with no
    /// `random()` and no `Date` anywhere near it, because a test that fails one run
    /// in ten is not evidence of anything. Six hundred-odd samples of a level that
    /// climbs, combed by falls of one to six samples, with resets and holes through
    /// it, and a trailing-source sample deliberately last so the tail exemption is
    /// in play as well.
    ///
    /// Four properties, and every one of them the rule restated: inside a window
    /// the result never falls; no reading moved by anything but exactly +1 pp; the
    /// resets came through untouched; the last reading is where it was. Around
    /// them stand four assertions on the input and the work done, because a rule
    /// that did nothing at all would satisfy all four properties: the series has
    /// to hold a comb, at least two resets, at least one of those not into zero,
    /// and the rule has to have moved a hundred samples of it.
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

    /// The fleet's burn against its refill, as the poll hands it over. Only
    /// `percent` and the lower-bound flag reach a surface; the rest is what
    /// `--dump` prints, and it is built to be **an object production can
    /// produce** rather than copied off a probe: `refillRate` is the expression
    /// `burnAgainstRefill` computes for three contributors, `3 x 100 / 168` =
    /// 1.7857 pp/h, and `burnRate` is derived back from whatever `percent` the
    /// caller passes, so the three agree by construction.
    ///
    /// **The docblock used to describe a different pair of numbers than the code
    /// beside it builds**, and both halves were wrong. It called these "the live
    /// figures of 2026-09-05 02:50Z — three accounts over 48 h, 0.6714 pp/h
    /// burned against the 0.5952 pp/h three weeks refill": that pair is **per
    /// account** — 0.5952 is `100 / 168`, one account's share — while
    /// `FleetBurn.refillRate` is by its own docstring the fleet's. And
    /// `measuredHours: 47.9` was never that probe's either: at 02:50Z the spans
    /// were 48.0 / 34.0 / 48.0 h and the field holds the shortest, 34.0. Of the
    /// citation only `percent = 112.8` belonged to 02:50Z, and `percent` is a
    /// parameter here. So the depth below is a plausible fixture depth and is not
    /// claimed as a measurement.
    ///
    /// `static` and internal because the menu bar's own tests build the same
    /// fixture: the two surfaces read one rule, so they had better be handed one
    /// figure rather than two that can drift.
    static func burn(_ percent: Double,
                     lowerBound: Bool = false) -> FleetCapacity.FleetBurn {
        FleetCapacity.FleetBurn(percent: percent,
                                burnRate: percent / 100 * 3 * 100 / 168,
                                refillRate: 3 * 100 / 168, accounts: 3, measuredHours: 47.9,
                                isLowerBound: lowerBound)
    }

    /// A snapshot the lead block can actually be drawn from: a ratio, and
    /// histories fresh enough to state it by. Two sources rather than the three
    /// the lead needed while it was a live rate over an allowance — which is what
    /// the tests below take away one at a time.
    ///
    /// The live token rate comes along because the block prints it as a
    /// supporting reading, and it is *not* what the lead is made of: taking it
    /// away leaves the lead exactly where it was.
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

    /// The lead says what is being spent when it can, and falls back to exactly
    /// what it said before when it cannot.
    ///
    /// Every way the lead can be missing arrives here as one state — the gateway
    /// silent, no account with enough history, every account pinned at its
    /// ceiling, a fall the reset schedule cannot explain, histories nobody has
    /// confirmed for two intervals — and none of them may be turned into a
    /// number. So the fallback is the old figure, and where there is no old
    /// figure either it is the dash that has always stood there.
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

    /// **The lead is the burn against the refill, and the caption names what the
    /// hundred means.** One quantity and one division, which is the change: the
    /// block used to print a five-minute token rate as its figure and what the
    /// fleet might sustainably spend as its caption, and the bar underneath was
    /// the only place the two were ever compared. Now the figure *is* the
    /// comparison, so the colour over it cannot be describing something else.
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

    /// The lead needs the ratio and nothing else, and the surface says so by
    /// falling back when it is missing — and by *not* falling back when the
    /// supporting reading beside it is.
    ///
    /// **That second half is the change.** The lead used to be a pair, and the
    /// live token rate was one of its halves: no `tokens` block from the gateway
    /// (an older gateway, or statistics turned off) and the whole lead went back
    /// to the mean. The token rate is a supporting reading now, printed with no
    /// bar and colouring nothing, so its absence costs the lead nothing at all.
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

    /// A figure whose own half is failing is not a figure this line may state,
    /// and the fallback is the same one it uses when there has never been one.
    ///
    /// Measured with `/gw/usage` and `/gw/sessions` answering while `/history`
    /// returned HTTP 500: the menu bar dropped its colour and this line went on
    /// stating a red `≥134%` under `of weekly capacity across accounts`, with
    /// nothing on screen saying the figure had not been confirmed since the
    /// outage began. The error is not one-directional, which is the point — a
    /// frozen 134% over a fleet that has calmed down is a false alarm, and a
    /// frozen green 80% over one that has gone to 200% is the very failure this
    /// metric was added to prevent.
    ///
    /// The figure, the caption, the bar and the colour all follow the one
    /// answer, so all four are asked here rather than the string alone.
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

    /// A figure nobody has confirmed for two of its own intervals is not a
    /// figure either surface may state, and no failure is set when that happens.
    ///
    /// The state is reachable with everything nominally healthy: a `/gw/usage`
    /// outage skips the histories half whole (`UsageStore.poll` will not measure
    /// a fleet whose membership nobody just confirmed), so `historiesFailure`
    /// stays `nil`, neither stamp moves, and both surfaces guarded on the blame
    /// alone.
    /// Two hours of that presented a two-hour-old figure as current — under a
    /// caption that says "capacity" here, and as a red frame with nothing to
    /// clear it up in the menu bar.
    ///
    /// Both surfaces are asked, because the point of the rule is that it is one
    /// rule: the menu bar has no room for the footer's caveat, so a ceiling that
    /// only this side applied would leave the colour up there outliving its
    /// reading.
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

    /// The headline's colour is the load's colour, and ink when the headline is
    /// back to being the mean.
    ///
    /// Held here as a rule and in `UsagePopoverPaintTests` as a rendering — this
    /// half alone would answer correctly for a function the view had stopped
    /// calling, which is exactly the state the figure's colour was in: replacing
    /// the modifier with a flat `Color.primary` passed all 478 tests.
    ///
    /// The mean is never given `QuotaBar`'s scale, and that is asked for too: at
    /// 92% of a window that scale is red, and a red figure over green account
    /// rows would be two scales for one reading.
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

    /// The ramp as a rule: pinned to this project's own colours at its three
    /// anchors, flat outside them, and falling all the way between.
    ///
    /// The anchors are asked against the system colours themselves rather than
    /// against the four decimals the source writes them as. That is the claim
    /// worth holding — the ramp is the family `QuotaBar.color(for:)` fills an
    /// account's bar with, at its ends, rather than a palette invented for it —
    /// and it is the claim that goes stale on its own if a system colour ever
    /// moves.
    ///
    /// **What survives a plate is the hue, and that is what is asked of all
    /// three.** Both plates move the rest — the light one lowers brightness, the
    /// dark one raises it and then lowers saturation (`legible(_:on:)`) — so a
    /// test that asked for the whole colour would be asking the floor not to
    /// work. One anchor does come through untouched and it is asked for
    /// everything: the green at capacity, on the dark plate, where the ramp's own
    /// colour already measures 5.36 to 1 against a floor of 4.69. The two ends are
    /// asked for the hue and then for the values the floor leaves them at,
    /// measured 2026-08-18: on the light plate full saturation at brightness
    /// 0.7955 (blue) and 0.7451 (red), on the dark plate full brightness at
    /// saturation 0.6383 and 0.5228.
    ///
    /// The shape is held here as well as in the three renderings, and the
    /// division is the usual one: a rule a view has stopped calling would answer
    /// correctly for ever, and a rendering cannot say which of a thousand loads
    /// were sampled.
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

        // The green anchor and the one step this pair still keeps are the same
        // boundary, asked of the step rather than of the constant it reads: a
        // menu bar that warned somewhere the ramp is not yet green would be two
        // boundaries pretending to be one.
        //
        // The old form of this line compared the constant with `FleetLoad`'s own
        // copy of it and became a tautology the day that type went, which is what
        // a name-for-a-name rename does to an assertion. Asked through
        // `isOverRefill` there is a rule on the other side of the `==`.
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

            // And between the anchors the hue is *interpolated*, which is the
            // whole of how the intermediate colours are arrived at: cyan is where
            // blue and green meet halfway, yellow and orange are where green and
            // red do. A table of hand-picked colours could satisfy every
            // assertion above and still be a set of steps with the corners
            // rounded off, so the line is asked at every load rather than at the
            // samples — a quarter of a point of hue is a visible colour, and the
            // tolerance is a hundredth of that.
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

        // **The plate never moves the hue**, which is the whole of what one
        // reading drawn on two surfaces means. It does move the other two, and in
        // opposite directions, so the pair is asked for the invariant rather than
        // for equality of the colour.
        //
        // The light plate is asked for more than that: there the floor is met by
        // darkening alone, and a floor that quietly desaturated the yellow band
        // into khaki would be the very cure this replaced. On the dark plate
        // desaturation is the only lever left once brightness is spent, and where
        // it bites is measured rather than assumed — at or below 74.4% and at or
        // above 124.9% on today's anchors, which is the cold end and the hot end
        // and nothing in between.
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

    /// The floor itself, as a rule: **on every plate** every colour on the ramp
    /// reaches that plate's floor, and no colour is moved further than it has to
    /// be.
    ///
    /// **This is the rule the review asked for and the reason the ceiling went.**
    /// The ceiling clamped the ramp to the green anchor's own luminance from
    /// 76.91% to 123.55% — three quarters of the moving part — and bought contrasts of
    /// 1.55 to 1.62 to 1 doing it (2026-08-18, against white; the light plate this
    /// machine actually has is 0.883, which is lower still). What replaces it
    /// leaves the colour alone until it is *illegible* and then moves it exactly
    /// as far as the floor, which is why the yellow at 115% survives untouched on
    /// a dark plate and comes out a darker yellow rather than an olive on a light
    /// one.
    ///
    /// **The dark plate used to be exempt and that was the defect.** "Darkening
    /// cannot raise contrast on a dark plate" is true, and the conclusion drawn
    /// from it — leave the ramp raw there — left the cold end at 2.83 to 1 and the
    /// hot end at 3.20 against a calm frame of 4.69. The direction of the
    /// adjustment follows the plate now, so both ends are lifted instead: the
    /// second half of this test is what says they were lifted *as far as needed
    /// and no further*, which is the property that keeps the ramp a colour rather
    /// than a wash.
    ///
    /// The contrast is worked out here rather than asked of the source: the
    /// linearisation is the thing that was wrong, and a test that borrowed the
    /// arithmetic under test would have agreed with it in gamma space just as
    /// happily.
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

    /// The 115% colour, named by rendering rather than by adjective.
    ///
    /// `MenuBarIcon` and §4 both said "at 115% it is yellow" and neither had
    /// rendered it: under the ceiling it came out `rgb(0.622, 0.678, 0.130)`,
    /// which is olive. What it is now, measured 2026-08-18: on the dark plate the
    /// ramp's own `rgb(0.827, 0.902, 0.173)`, a yellow with a green cast at hue
    /// 66.2 degrees; on the light plate that colour darkened to the floor,
    /// `rgb(0.381, 0.415, 0.079)` — the same hue, and dark, which is what a floor
    /// on a light plate can only produce.
    ///
    /// And the load the ramp is *orange* at is a third number, unmoved by either
    /// plate: hue is interpolated straight from green to red, so it crosses 30
    /// degrees at 123.61% and the first tenth of a point drawn at or past orange
    /// is 123.7%. The ceiling never moved that and neither does the floor — what
    /// the ceiling moved was how dark 115% was drawn.
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

    /// The word this metric is called by inside the app is internal vocabulary
    /// and appears in no string a person reads (§4). Asked of the strings on the
    /// list below, which is every string these two surfaces write themselves.
    ///
    /// **The list is built by hand and cannot be built any other way.** A string
    /// on screen is whatever some `Text`, `help` or `accessibilityLabel` was
    /// handed, and there is no reading a SwiftUI body from a test: `some View` is
    /// opaque, its children are not enumerable, and `ImageRenderer` gives back
    /// pixels rather than words. So what is swept is the functions the views call,
    /// and the wire from a view to its function is held by reading it — which is
    /// the same wire, and the same argument, as `switchAppearance`'s. Two rules
    /// follow, and they are the price of the arrangement: a new string on either
    /// surface is covered only once it has been typed in here, and a string is
    /// only reachable at all if it lives in a named function rather than as a
    /// literal in a `@ViewBuilder`. `switchAccessibilityLabel` was a literal until
    /// this sweep asked for it.
    ///
    /// **What is deliberately not swept, and why.** Three strings on this surface
    /// carry words this app did not write and cannot reword: `switchNote`'s
    /// `disabled_reason`, `switchBlame`'s transport failures, and `failureText`'s.
    /// Each of those is swept for the frame this app puts around the text — the
    /// word `off`, the separators, `as of` — and not for the text itself, which is
    /// a question decided where the value is taken rather than where it is drawn:
    /// the one gateway sentence that was a constant, the switch answer's
    /// `warning`, is decoded and dropped instead of printed
    /// (`SwitchResult.warning`), and the account labels beside them are names the
    /// operator chose. Two literals stay in the view as well, the `5h` and `7d`
    /// of `windowRow`'s titles: they are a digit and a unit, they are the argument
    /// this function's own callers pass, and pulling them out would buy a sweep of
    /// four characters that cannot hold a word.
    ///
    /// **And a frame is only swept if the model built it.** Two of those frames are
    /// written in `UsageHistoryModel` rather than in the view — `"status: \(error)"`
    /// for a pass that could not ask and `"\(label): \(error)"` for a click that
    /// would not go through — so handing this sweep a finished literal that looks
    /// like one would be asking whether the test's own typing says the word. They
    /// are produced below by running a refusing client through `load` and
    /// `switchAccount`, which is where those strings are actually made.
    ///
    /// **Proved by mutation, in two sittings of 2026-09-06 — and the sitting, not
    /// the suite size beside it, is what tells the two apart.** The first, on the
    /// two entries the switch surface put on this list
    /// (`switchAccessibilityLabel` and `switchNote`), was taken before
    /// `testTheCountIsSettledByAPassOnceTheLastClickHasLanded` and
    /// `testALoneClickIsSettledByItsOwnAnswer` existed, which is the whole of why
    /// its counts read 668. Writing the word into `switchAccessibilityLabel`
    /// reddens this test and nothing else of the 668 — that one is the whole proof
    /// of the extraction, because as a literal in the view it was a string no test
    /// could reach at all. Writing it into `switchNote`'s `off` reddens this one on
    /// all three of that label's shapes and
    /// `testASwitchedOffAccountNamesItsDeadlineAndItsReason` beside it, 2 of 668:
    /// that test pins the wording, this one holds the rule the wording has to
    /// satisfy, and a wording test is not one — it would go on passing over any
    /// wording somebody chose to write down.
    ///
    /// The second sitting, later the same day and with that pair of settling tests
    /// in, covers the two entries the headline and the model put on the list:
    /// `spendRateCaption` and `"status: \(error)"`. The word written into
    /// `spendRateCaption` reddens this test and nothing else — that caption is the
    /// third of the headline's three, and it had no test of any kind on it before
    /// this line. Written into the model's `"status: \(error)"` frame it reddens
    /// this one and
    /// `testTheReasonTheSwitchesWentInertIsDrawnWithNoAccountsToDrawItUnder`, 2 of
    /// 670, the second on both its strings — that one pins the frame's wording where
    /// it is drawn, this one holds the rule, and the pair divides the same way as
    /// `switchNote`'s above.
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
        // The line under a switched-off account, in all three of its shapes. The
        // reason in the third is the gateway's word and is here to be carried
        // rather than to be judged: what is asked is the frame around it.
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
        // The orange line, and this is the whole of it: `applyRoutable` writes
        // this string and nothing else, so the sweep covers the surface again.
        // The gateway's own sentence used to reach that line through a click and
        // was let through here by a comment — a rule revoked in a comment while
        // §4 went on stating it. It is decoded and dropped now
        // (`SwitchResult.warning`).
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
        let refusedClick = await UsageHistoryModel.switchAccount(client: refusing, label: "acc2",
                                                                 enabled: false)
        // Without this the three below could be `nil`, and a sweep over three
        // empty strings reads as covered while covering nothing.
        XCTAssertNotNil(refused.rotation.failure, "the refusing client answered the rotation")
        XCTAssertNotNil(refused.failure, "the refusing client answered a history")
        XCTAssertNotNil(refusedClick.failure, "the refusing client answered the click")
        strings.append(refused.rotation.failure ?? "")
        strings.append(refused.failure ?? "")
        strings.append(refusedClick.failure ?? "")
        for text in strings {
            XCTAssertFalse(text.lowercased().contains("fleet"),
                           "\"\(text)\" says \"fleet\" to somebody who does not work on this app")
        }
    }

    /// The reset time always names its smallest unit, and never leaves a floor
    /// standing on its own.
    ///
    /// A bare unit is a floor and therefore a range: `in 1d` covers 24 hours to
    /// 48, `in 1h` covers 60 minutes to 119. Both were caught on the live screen —
    /// "19 hours? 26?" of the days, and then `5h … in 1h` in the same popover, "an
    /// hour and a half? five minutes?". So the lower unit is printed beside the
    /// higher one and printed even when it is zero, because a bare `in 4h` is
    /// exactly the ambiguity being removed.
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

    /// One account's switch, built the only way there is: `AccountSwitch` decodes
    /// and does nothing else, so a state in a test is a body from the gateway.
    ///
    /// `eligible` is written into every body even though this type has no field
    /// for it, and that is the point: it is the field next door, it is what the
    /// gateway folds a quota cool-down and a token backoff into, and a fixture
    /// that leaves it out cannot tell a reader of `disabled` from a reader of it.
    /// It defaults to the opposite of `disabled` — the ordinary fleet, where the
    /// two agree — and `main` on the morning of 2026-09-06 is what it looks like
    /// when they do not: `rotationState(eligible: false)`.
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

    /// The line under a switched-off account says the two things the gateway can
    /// add to "off", and says nothing where there is nothing to say.
    ///
    /// The deadline is drawn and never set: this app's own switch sends no body,
    /// which is the gateway's "until somebody puts it back", so a moment here can
    /// only have come from somewhere else — the command line, or a rule of the
    /// gateway's own. Showing it is the difference between an account that comes
    /// back by itself and one that waits for a person.
    ///
    /// Written by `resetLabel`, the popover's one countdown, so the wording is
    /// the wording of every other moment on this surface — and it goes in
    /// brackets because that countdown has two shapes and the bare one (`resets
    /// now`) would otherwise run straight into the word before it.
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

    /// And the box itself draws those same three states: unknown is **not**
    /// "in the rotation", and a box this app cannot fill in cannot be clicked
    /// either.
    ///
    /// Asked of the function rather than of the picture because the picture
    /// cannot answer: `ImageRenderer` draws this checkbox as a blank plate —
    /// ticked, clear, inert and inert-and-ticked all came out as the same 784
    /// inked pixels, 784 of them chromatic (measured 2026-09-06, scale 2.0, a
    /// 40×24 frame). So the tick has no ink of its own to compare, "two values
    /// of the same field" has nothing to widen, and `?? true` in place of
    /// `?? false` was invisible to every test on this surface until this one.
    /// What is still held by reading and not by a test is the one line that
    /// wires the view to this function.
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

        // The live `main` of the morning of 2026-09-06: nobody switched it off and
        // the gateway will not route to it all the same. The box follows the
        // operator's switch, because that is the thing a click here can change —
        // bound to `eligible` it would clear itself when a quota window filled and
        // then send an `enable` that changes nothing visible. It is the one shape
        // in which the two flags disagree, so it is the only one that can tell a
        // reader of either apart.
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

    /// And no input at all writes a floor on its own, a unit that overflowed, or a
    /// leading zero: swept second by second from the reset itself out to two hours
    /// and then coarsely, a step of 61 seconds, out to forty days.
    ///
    /// The dense window is where the seams are — `resets now`, the minutes on their
    /// own, the carry into `in 1h 0m`, the whole of the first hour written both
    /// ways — and it starts at zero so that `resets now` is a shape the sweep
    /// actually reaches. Past two hours nothing changes shape until the day, so the
    /// coarse step carries the property there instead: second by second all the way
    /// to three days was 311 thousand calls and the slowest test in the suite, for
    /// a stretch where every second reads like the one before it. The step is 61
    /// rather than 60 so that it does not land on the same minute boundary over and
    /// over.
    ///
    /// The assertions above are the seams the rule was written around; this is what
    /// says there are no others. The defect being removed was not at a seam at all:
    /// `in 1h` stood for everything from 3541 seconds to 7199 of them, and the old
    /// test asserted it at two of those points *on purpose*. More boundaries do not
    /// catch a shape nobody questioned, so the shape is what gets swept — four are
    /// allowed, and `in Nh` on its own is the shape that was wrong.
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
    ///
    /// `in 23h 59m` and `in 20h 44m` are on the list because the minutes beside the
    /// hours are new (§4): the widest string a plausible reset can produce is no
    /// longer a day count, and a slot measured only against day counts would say
    /// nothing about the shape that now fills every row under a day. Two of them
    /// and not one, because this label has no `monospacedDigit` and the width is
    /// the digits' own: over all 1380 strings of the shape the widest is not the
    /// latest hour but `in 20h 44m` at 53.75 pt, against `in 23h 59m`'s 53.25.
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

    /// The burn ratio is never dated by this footer, and the age it prints is
    /// the age of what is drawn.
    ///
    /// This test asserted the opposite, and it enshrined the defect: with a quota
    /// 20 s old and the histories half failing it expected `as of 5m ago`, the age
    /// of a histories stamp — over a popover where the same failure had already
    /// taken the ratio off the screen (`historiesAreFresh`), so every drawn value
    /// was seconds old and the line overstated them by as much as the process had
    /// been running. What the fold was reaching for is now impossible instead of
    /// wrong: a ratio older than `historyStaleSeconds` is not shown, so a ratio
    /// worth dating is never on screen to date.
    ///
    /// The failure still breaks the silence — but over the halves that *are*
    /// drawn, which is what the second half of this test holds.
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
        // The state that used to print an unbounded overstatement: the histories
        // half has been failing for two hours, the quota and the chart are 20 s
        // old, and the only figures on screen are those 20 s old ones.
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

    /// The weekly quota is this surface's alone since 2026-08-24, and it is
    /// rounded in one place (`UsageSnapshot.fleetSevenDayPercent`).
    ///
    /// The menu bar drew the same figure until then, under a colour that meant
    /// something else, and the pair of them needed a rule each: the icon dropped
    /// a figure whose last pass had failed, because up there is no room to say
    /// "as of an hour ago". Only the keeping half is left. The popover keeps a
    /// stale quota because the footer under it gives the age, and because the
    /// account rows below go on showing their stored percentages — gated the same
    /// way, the headline was a dash over live numbers, and the dash was the false
    /// statement of the two.
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

    /// Whether a patch is exactly the size of a frame the view asked for.
    ///
    /// The size comes from the view, and that is the half that carries the weight:
    /// a copy of the number here is what failed both colour tests with "the
    /// popover drew 0 dots" when the dot went from 7 points to 8 — pure
    /// decoration, and a message about the palette. Asked of the view's own
    /// constant, plain equality survives that change: measured, a whole number of
    /// points is a whole number of pixels at this scale, 16 for 8 as 14 for 7.
    ///
    /// A pixel of slack stood here for the sample of the bold line, which was 2.5
    /// points tall and therefore not a whole number of pixels at every scale. The
    /// sample is gone (§4) and the slack went with it — checked by mutation, the
    /// class is green with equality — because the one size still asked for is a
    /// whole number of points. A fractional one would need the slack back, and
    /// would announce itself as "drew 0 dots".
    private func isSized(_ blob: Blob, _ size: CGSize, in canvas: Canvas) -> Bool {
        Double(blob.width) == Double(size.width) * canvas.scale
            && Double(blob.height) == Double(size.height) * canvas.scale
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

    /// What the lead states in every rendering here: the live fleet's own burn
    /// against its refill at 2026-09-05 02:50Z, which the surface writes `113%` over
    /// `of the weekly refill rate`.
    private static let leadPercent = 112.8
    /// And the supporting rate under it, from 2026-08-24: `23.8M/h`.
    private static let currentRate = 23_800_000.0

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

    /// The caption under the big figure is drawn on one line, whatever the figure
    /// says.
    ///
    /// Which is what the headline was rebuilt for (§4). Beside the figure the
    /// caption fitted only while the figure was short: measured, it is 205.5 pt of
    /// ink on a 292 pt line, `52%` leaves it 219 pt and `100%` leaves 199.5, so the
    /// wide figure wrapped it — and a wrapped caption is the complaint itself,
    /// three digits being exactly the reading somebody opens this popover for. On
    /// its own row it has the whole width.
    ///
    /// Measured the way the reset slot is (§4): the same string drawn twice, once
    /// on its own and once where it lives. The top of the popover is three lines of
    /// ink — the figure, the caption, the bar — and the middle one has to be as wide
    /// as the caption drawn free, which is the caption having a line to itself and
    /// filling it.
    ///
    /// The *place* is half the measurement, and it is not spare rigour: putting the
    /// caption back beside the figure and asking only "is there a band this wide"
    /// passes at 100%, where the figure and the first wrapped line come out as one
    /// band of 205.50 pt against the caption's own 205.5 — the same figure to the
    /// pixel, by coincidence. Held as the middle of three, that layout fails at both
    /// figures: 239.00, 292.00, 292.00 at the dash, and 205.50, 84.50, 292.00 at
    /// 100%, where the second band is the tail of the wrapped caption.
    ///
    /// Over the widest figure and over none, because the two are what the layout
    /// has to hold at once.
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

    /// The lead bar is the ramp, drawn: cold blue below 70, green at capacity,
    /// red at 130 and nothing new past it.
    ///
    /// The popover is the third surface the ramp has to work on — a dark one, and
    /// the one with room to read a scale off — and this is where it is read back
    /// off the drawing rather than asked of the rule.
    ///
    /// The bar is found by its height and nothing finer, which is what makes the
    /// question answerable at all: the picture's largest patch of opaque colour
    /// is the segmented picker's background at 292 by 22 points, four times the
    /// area of a full headline bar, and the account dots are 7 by 7. Exactly
    /// `headlineBarHeight` tall there is one thing — the supporting reading's bar
    /// under it is `supportingBarHeight`, and in this fixture there is no mean
    /// for it to fill anyway.
    ///
    /// Green *at* capacity rather than red is the correction itself: the pair of
    /// loads a thousandth of a point either side of 100 used to come out green
    /// and red, and they are now one colour to three decimals of hue — which is
    /// asserted, because "the ramp is continuous" is exactly the claim a step
    /// would fail.
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

        // And the boundary that used to be here is gone: either side of capacity
        // is one colour now.
        let boundary = UsagePopoverView.greenRatioPercent
        let under = try await headlineBarHue(ratioPercent: boundary - 0.001)
        let at = try await headlineBarHue(ratioPercent: boundary)
        XCTAssertEqual(under, at, accuracy: 0.001, "the bar still steps at capacity")
    }

    /// The popover's half of the legibility evidence: the lead figure and the
    /// lead bar, measured off the drawing on both plates at nine loads.
    ///
    /// The menu bar's own test is the other half, and the two together are what
    /// "the ramp is legible where it is drawn" means — one rule, two surfaces,
    /// two plates each. What this half adds is the **plumbing**: the popover asks
    /// the environment which plate it is on, and a view that had stopped asking
    /// would paint the light plate's darkened colours onto a dark popover and
    /// pass every hue assertion in this class while doing it. So the whole colour
    /// is compared, not the hue.
    ///
    /// The floor is asked on **both** plates, and the guard that used to ask it
    /// on the light one alone went with the menu bar's — the same hole, on the
    /// same rule, on the other surface. The middle of the ramp is still untouched
    /// on the dark plate and that is asserted here as a rendering rather than
    /// only as a rule: the yellow at 115% comes back `rgb(0.827, 0.902, 0.173)`,
    /// which is the ramp's own — the colour the old ceiling turned into
    /// `rgb(0.622, 0.678, 0.130)` on every plate, including the dark ones where
    /// nothing needed it.
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

    /// **The lead bar is the burn against the refill, and it stops at the refill
    /// rate.**
    ///
    /// A scale stretched to fit three times the refill would make the refill
    /// itself — the point the whole reading turns on — a mark a third of the way
    /// along. So the bar is read off the drawing at half the refill rate, at
    /// exactly it and at three times it, and the last two have to be the same
    /// full bar.
    ///
    /// Measured rather than reasoned about, because the fill is a claim about
    /// pixels: the ratio no longer clamps itself, so what holds this is the
    /// drawing and nothing else.
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

    /// The figure over that bar is coloured too, and by the same rule.
    ///
    /// It is the one visible quantity this round added that nothing held:
    /// replacing its `foregroundStyle` with a flat `Color.primary` passed all
    /// 478 tests (2026-08-17). A test of `headlineFigureColor` alone would not
    /// have caught it either — a pure function answers correctly for ever once
    /// the view stops calling it — so the rendering is what is asked here, and
    /// the rule itself is asked next door in `UsagePopoverLabelTests`.
    ///
    /// The lead figure over that bar is coloured too, and by the same ramp.
    ///
    /// Three ratios rather than the seven the bar is asked for, because what is
    /// held here is that the figure and the bar are one rule: the shape of the
    /// ramp is the bar's test, and this one asks that the string above it goes
    /// the same way — cold at 60, green at capacity, red at 130.
    ///
    /// And with no ratio the figure has to be ink: the quota is a reading on a
    /// scale this line does not paint.
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

    /// All three readings are on screen at once: the burn ratio leading, the
    /// weekly quota under it with its own figure, its own words and its own bar,
    /// and the spend rate under that with a figure and words but no bar.
    ///
    /// Which is the correction — the branch that put the ratio in the headline
    /// took the quota off the screen rather than adding a reading beside it, and
    /// the owner asked for all of them.
    ///
    /// Measured the way the caption's own test measures: every string is drawn a
    /// second time on its own and the popover's lines of ink are compared against
    /// those widths. Eight lines above the first rule, in order — ratio figure,
    /// ratio caption, ratio bar, quota figure, quota caption, quota bar, rate
    /// figure, rate caption — and each named one asserted, so a layout that
    /// dropped a line or drew the same reading twice fails on the count *and* on
    /// the widths.
    ///
    /// The eighth line is the one that says the rate has no bar of its own: a
    /// `QuotaBar(fraction: nil)` under it would draw an empty track, which reads
    /// as a reading of zero, and it would land here as a ninth full-width line.
    ///
    /// The three figures are deliberately different strings, and the lead is at a
    /// different size (`126%` at `headlineFigureSize`, `52%` and `23.8M/h` at
    /// `supportingFigureSize`): were any two the same string at the same size, a
    /// headline that drew one reading twice would pass the assertions on them.
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

    /// The quota's bar keeps the quota's own scale, and the lead's keeps the
    /// load's ramp — two rules on one surface, each on the reading it belongs to.
    ///
    /// The fixture puts them on opposite sides on purpose: a load of 62% is cold
    /// blue on the ramp while a quota of 92% is red on `QuotaBar.color(for:)`'s
    /// 60-and-85 scale, so a headline that painted both bars by one rule cannot
    /// pass whichever rule it picked. Then the two are swapped — 126% is hot on
    /// the ramp while 52% is green on the scale — which is the same trap the
    /// other way round.
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

    /// The headline's lead figure and lead bar, as they land on the plate the
    /// popover is drawn on, at one load in one scheme.
    ///
    /// The two are the first and third lines of ink above the popover's first
    /// rule, which is the order `testTheHeadlineDrawsAllThreeReadingsAtOnce`
    /// holds. Composited over the plate for the reason the menu bar's own
    /// measurement composites: the rendering is on transparency, and what a
    /// reader sees is the popover's material through it.
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

    /// The hue of the popover's big figure, and how much of it was drawn in a
    /// colour at all.
    ///
    /// The figure is the topmost band of ink in the picture — the layout is
    /// figure, caption, bar, which is what `testTheHeadlineCaptionIsDrawnOnOneLine`
    /// holds — so the band is taken from the rendering rather than from a
    /// coordinate. Hues are centred around zero before they are averaged
    /// (`> 0.5` becomes negative), because red sits on the wrap: a mean of
    /// pixels at 0.99 and 0.01 is 0.5, which is a cyan nothing here draws.
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

    // MARK: - The line under a switched-off account

    /// The row of an account the gateway is not routing to says so, and the row
    /// of one it is says nothing extra.
    ///
    /// Asked with **two values of the same field, of different widths** rather
    /// than with the note and without it (§4). "With it and without it" answers a
    /// different question — "do these two pictures differ" — and the two states
    /// differ in the checkbox's own tick as well, so a note deleted outright
    /// would still leave the pictures unequal and the probe would report it
    /// drawn. Two reasons of different lengths hold the rest of the row fixed:
    /// the note is drawn and the wider reason takes more room, or it is not and
    /// the two pictures are the same to the pixel.
    ///
    /// Measured over every band of ink in the popover rather than at a
    /// coordinate: the row's place moves with any change of font or inset, while
    /// "exactly one line of this picture got wider" survives all of them.
    func testTheRowOfASwitchedOffAccountSaysSoAndTheRowOfALiveOneDoesNot() async throws {
        func bands(disabled: Bool, reason: String) async throws -> [Double] {
            // `elsewhere` is here so the fleet has somewhere to route and no orange
            // line joins the picture: `acc1` alone would be zero routable accounts
            // in the switched-off half and one line more than in the other.
            let rotation = """
            {"accounts": [{"label": "acc1", "eligible": \(!disabled), "disabled": \(disabled), \
            "disabled_until": null, "disabled_reason": "\(reason)"}, \
            {"label": "elsewhere", "eligible": true, "disabled": false, \
            "disabled_until": null, "disabled_reason": ""}]}
            """
            let (view, _, history) = try await popover(named: ["acc1"], asked: ["acc1"],
                                                       readings: ["acc1": 40], rotation: rotation)
            defer { history.close() }
            return inkBands(in: try canvas(view))
        }
        // Short enough that neither is truncated: the note is one line with a
        // tail truncation, and two reasons both cut off at the popover's width
        // would be the same width for a reason that has nothing to do with this.
        let narrow = try await bands(disabled: true, reason: "z")
        let wide = try await bands(disabled: true, reason: "zzzzzzzzzz")

        XCTAssertEqual(narrow.count, wide.count,
                       "the two rotations drew a different number of lines: \(narrow) / \(wide)")
        let moved = zip(narrow, wide).enumerated().filter { abs($0.element.1 - $0.element.0) > 0.5 }
        XCTAssertEqual(moved.count, 1,
                       "\(moved.count) lines of the popover follow the reason, not one: "
                       + "\(narrow) / \(wide)")
        let note = try XCTUnwrap(moved.first?.element)
        XCTAssertGreaterThan(note.1, note.0 + 10,
                             "nine more characters bought \(note.1 - note.0) pt of line")

        // And in the rotation the field is not drawn at all, so the same two
        // values give the same picture.
        let live = try await bands(disabled: false, reason: "z")
        let liveWide = try await bands(disabled: false, reason: "zzzzzzzzzz")
        XCTAssertEqual(live, liveWide,
                       "an account in the rotation drew a reason it is not disabled for")
    }

    /// The window the warning's own orange occupies in a rendering, measured.
    ///
    /// `Color.orange` asked directly reports hue 0.10136; drawn as text at 10 pt
    /// and read back off the bitmap it lands between 0.09681 and 0.09797 over the
    /// 5179 pixels the two lines of the sentence cover (2026-09-06, scale 2.0,
    /// popover width). The band below is wide enough to hold that spread and
    /// nowhere near the rest of the surface's colour, which in the same rendering
    /// runs 0.00886…0.21144.
    private static let warningHue: ClosedRange<Double> = 0.09...0.105

    /// Lines of the popover drawn entirely in the fleet warning's orange.
    ///
    /// A **line**, not a count of pixels, because this surface has other colour on
    /// it and part of that colour's range straddles the orange: the rest of the
    /// chromatic ink spans 0.00886…0.21144 in the very rendering the caller
    /// measures, and one band of it holds hues on both sides of the warning's own.
    /// A band of ink every coloured pixel of which is that orange
    /// cannot be assembled out of a wider spread, and the floor below keeps a band
    /// with no colour in it at all from answering yes by vacuity — the sentence's
    /// two lines carry 2613 and 2566 such pixels, so 100 is far under either and
    /// far over anything a rounded edge could leave behind.
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

    /// The orange line is drawn when the account list is empty.
    ///
    /// The rows come from the quota poll and the rotation from `/gw/status`, and
    /// they fail apart: with `/gw/usage` answering HTTP 500 the popover used to say
    /// "/gw/usage: HTTP 500" and nothing else, while every client request was being
    /// answered 429 and the line saying so had been drawn inside the branch that
    /// needs a list. That is not a state on the way to somewhere — it is a gateway
    /// half up, and the half that is up is the one with something to report.
    ///
    /// Asked of the line's **colour**, not of two pictures differing (§4). The
    /// usual remedy here — two values of one field, of different widths — has
    /// nothing to work with any more: since the sentence stopped arriving from the
    /// gateway, `fleetWarning` has exactly one non-`nil` value it can ever hold,
    /// `noRouteWarning`, which is one string and one width. So the question is put
    /// to the picture directly. This surface draws its warning in `.orange` and
    /// nothing else in it, and `orangeLines` says how many lines of ink are wholly
    /// that colour — a measurement that answers "the line is not there" by
    /// returning nothing, which is the property "these two pictures differ" never
    /// had.
    ///
    /// Two lines rather than one because the sentence is 114 characters at 10 pt
    /// and the popover is 320 pt wide before its padding: it wraps, and
    /// `fixedSize(horizontal: false, vertical: true)` on it is what lets it wrap
    /// rather than be cut. A truncated single line would answer 1 here, and that is
    /// worth being told about.
    ///
    /// The control is the same picture over a fleet with somewhere to route, and it
    /// is a control on the **method** and not the question: it says the count can
    /// come back zero, so the two above are the line and not an artefact of the
    /// measurement.
    ///
    /// Proved by mutation, 2026-09-06: moving the three fleet lines back inside the
    /// `else` takes the raised count from 2 to 0 and reddens this test together
    /// with the two below it — three of the suite as it stood that morning, 666,
    /// and nothing else in it. Not re-run since; the suite has grown past that
    /// number, and the figure dates the mutation rather than describing today.
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

    /// And the blame for a click that would not go through is drawn there too.
    ///
    /// Same argument as the orange line above and the same failure it was moved
    /// out of the `else` to stop: the rows come from `/gw/usage` and this line from
    /// the operator's own click, which needs no rows to have happened. A quota poll
    /// answering HTTP 500 while somebody clicks a checkbox would take the only
    /// statement that the click did not go through off the screen and leave the
    /// popover saying `/gw/usage: HTTP 500`, with the tick sitting where it was.
    ///
    /// Asked with **two values of the same field, of different widths** (§4): one
    /// unreachable reason of one character against one of ten, so the blame is
    /// `acc1: unreachable: z` against `acc1: unreachable: zzzzzzzzzz` and every
    /// other thing in the picture is held fixed. Never with the line and without
    /// it — a click that fails and a click that does not differ in more than this
    /// line, and "the two pictures differ" is a different question. Both strings
    /// are short enough to stay on one line and to be cut by nothing, so the number
    /// of bands is the same in both and exactly one of them may follow the field.
    ///
    /// Two mutations, 2026-09-06. Deleting this block outright reddens exactly this
    /// test and leaves the other 665 of that morning's 666 green — before it was
    /// written the block could be taken out for nothing. Moving the three lines back
    /// inside the `else` reddens this one, the orange line's above and the pass's
    /// below. Neither has been re-run since the suite grew past 666, so both counts
    /// date the mutation rather than describing today.
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

    /// And so is the reason the checkboxes went inert.
    ///
    /// The third of the three, and the one whose absence is worst: `/gw/status`
    /// failing is exactly what empties `switches`, so every box on the surface is
    /// drawn clear and unclickable — and drawn inside the `else`, the line that
    /// says why would be missing in precisely the state it exists for, because a
    /// gateway that cannot answer `/gw/status` is often a gateway that cannot
    /// answer `/gw/usage` either and then there are no rows.
    ///
    /// Asked the same way as the blame: **two values of the same field, of
    /// different widths**, one unreachable reason of one character against one of
    /// ten, giving `status: unreachable: z` against `status: unreachable:
    /// zzzzzzzzzz`. With the pass failing there is no rotation and no count, so the
    /// other two fleet lines are `nil` in both halves and cannot move.
    ///
    /// Two mutations, 2026-09-06, the same pair as the blame's: deleting this block
    /// reddens exactly this test out of that morning's 666, and moving the three
    /// lines back inside the `else` reddens all three of them. Not re-run since the
    /// suite grew past that number.
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

    /// The mean is drawn in ink, and no account may be handed that colour.
    ///
    /// Which is the whole reason the chart declares its own colour scale: without
    /// `chartForegroundStyleScale` the mean is a series like any other and Charts
    /// hands it a hue out of its palette, at which point the one line this popover
    /// exists to show is a colour among colours — and the number in the headline,
    /// which is that line's last point, names nothing in the picture.
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
    /// in that account's hue, one hue among hues rather than the one line in
    /// ink. Measured with the key spelled `average`, over the accounts
    /// `["average", "acc2"]`: the domain came out `["average", "acc2", "average"]`,
    /// the range `[primary, blue, orange]`, and the mean's line took the orange —
    /// the colliding account's own hue, measured as 0.097 in the mean's band.
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
