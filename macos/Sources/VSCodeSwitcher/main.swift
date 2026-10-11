import AppKit
import Foundation

// Entry point. Without arguments the process becomes the menu bar agent; with
// `--dump` it stays a console tool that prints the assembled model, which is how
// the data layer is verified without any UI in the way.

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    VSCodeSwitcher: a switcher panel for VSCode windows.

      (no arguments)    run the menu bar agent
      --no-windows      run without editor windows: the list is built from
                        projects and live sessions only, as when Accessibility
                        access is missing
      --dump            print the assembled model and exit
      --dump --json     the same, as JSON
    """)
    exit(0)
}

var startupConfig = Config.load()
if arguments.contains("--no-windows") {
    // Debug aid: an identifier no application answers to, which is how the
    // panel looks when the Accessibility permission is missing.
    startupConfig.editorBundleID = "xyz.vvzvlad.vscode-switcher.no-such-editor"
}

if arguments.contains("--dump") {
    ConsoleDump.run(config: startupConfig, json: arguments.contains("--json"))
    exit(0)
}

// Top-level code is not main-actor isolated, but everything AppKit touches has
// to be; the hop is explicit and immediate because this *is* the main thread.
MainActor.assumeIsolated { AgentEntryPoint.run(config: startupConfig) }

/// Starts the menu bar agent and keeps the delegate alive: `NSApplication`
/// holds its delegate weakly.
enum AgentEntryPoint {
    @MainActor private static var delegate: AppDelegate?

    @MainActor static func run(config: Config) {
        let application = NSApplication.shared
        let delegate = AppDelegate(config: config)
        Self.delegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

/// The former stage 1 entry point, kept as a diagnostic mode.
enum ConsoleDump {

    static func run(config: Config, json: Bool) {
        // One synchronous poll of the gateway, with the client's own five second
        // timeout on each call. The agent polls in the background once a minute;
        // `--dump` has no run loop to wait on, and no second chance to print.
        // A gateway that is not there prints a line and changes nothing else.
        let usage = UsageStore.pollOnce(config: config)
        let cache = UsageCache()
        cache.store(usage)
        let source = DataSource(config: config, usage: cache)
        let snapshot = measuredSnapshot { source.snapshot() }
        if json {
            printJSON(snapshot)
        } else {
            printText(config: config, snapshot: snapshot, usage: usage)
        }
    }

    private static func printJSON(_ snapshot: SwitcherSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else {
            FileHandle.standardError.write(Data("failed to encode snapshot\n".utf8))
            exit(1)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func printText(config: Config, snapshot: SwitcherSnapshot, usage: UsageSnapshot) {
        print("Config")
        print("  roots:            \(config.resolvedProjectRoots.map(\.path).joined(separator: ", "))")
        print("  depth:            \(config.scanDepth)")
        print("  transcript tail:  \(config.transcriptTailBytes / 1024) KiB")
        print("  editor:           \(config.editorBundleID)")
        print("  usage gateway:    \(config.usageBaseURL)")
        print("  accessibility:    \(snapshot.accessibilityTrusted ? "granted" : "NOT GRANTED — window list will be empty")")
        print("")

        printUsage(usage, snapshot: snapshot)

        print("Open windows (last message first): \(snapshot.openWindows.count)")
        for (position, row) in snapshot.openWindows.enumerated() {
            print("  \(position + 1). \(title(row))  \(row.colorHex)  \(indicator(row))  [\(stateBreakdown(row))]")
            print("      title:     \(shorten(row.window?.title, 90))")
            print("      topic:     \(shorten(row.chatTopic, 90))")
            print("      model:     \(row.model ?? "-")   context: \(formatContext(row))   subagents: \(row.activeSubagents)")
            print("      cpu:       \(cpuCell(for: row))   orphan processes: \(row.orphanCount)")
            if let usage = row.usage {
                print("      usage 7d:  \(formatTokens(usage))")
            }
            // The window the panel actually draws, on the same terms as the week
            // above it: both sets of four counters, so either can be checked
            // against the gateway by hand.
            if let hourly = row.hourlyUsage {
                print("      usage 1h:  \(formatTokens(hourly))")
            }
            if !row.subagentDescriptions.isEmpty {
                print("      running:   \(row.subagentDescriptions.map { shorten($0, 50) }.joined(separator: "; "))")
            }
            if !row.sessions.isEmpty {
                print("      sessions:  \(row.sessions.count)")
                for session in row.sessions {
                    let context = session.contextUsedTokens.map { "\($0 / 1000)k" } ?? "-"
                    print("        - \(column(session.state.rawValue, 10))"
                        + " src=\(column(session.stateSource.rawValue, 10))"
                        + " pid=\(session.pid) ctx=\(context) sub=\(session.activeSubagents)"
                        + " \(shorten(session.topic, 46))")
                }
            }
        }
        print("")

        let strayed = snapshot.projects.filter { !$0.sessions.isEmpty }
        if !strayed.isEmpty {
            print("Live sessions without a window: \(strayed.count)")
            for row in strayed {
                // Bracket then percentage, in the order the panel's title line
                // puts them: `title` carries the bracket, and the CPU follows
                // it. These are the rows with agents on them, so leaving the
                // figure off here was leaving it off exactly where it is worth
                // reading.
                print("  - \(title(row))  \(cpuCell(for: row))"
                    + "  \(indicator(row))  [\(stateBreakdown(row))]  \(shorten(row.chatTopic, 60))")
            }
            print("")
        }

        // In the order the panel shows them, which is what the ranking is for.
        print("Projects section: \(snapshot.projects.count) (showing 15, most recently worked in first)")
        for row in snapshot.projects.prefix(15) {
            print(projectRow(for: row, config: config))
        }
    }

    /// One row of the "Projects" table, composed rather than printed.
    ///
    /// A function so that a test can hold the assembled line to the widths it is
    /// built from: `testTheSpendColumnsHoldTheTableToTheWidthTheyDeclare` checks
    /// that the columns line up.
    static func projectRow(for row: SwitcherRow, config: Config) -> String {
        let workspace = row.project?.workspaceFile == nil ? "git" : "workspace"
        // The indicator is printed here too, because this is where the rule
        // "no chat, no subagent, no icon" is worth seeing: most of this
        // section is projects nobody has run an agent in.
        return "  - \(nameCell(for: row, width: 34)) \(row.colorHex)"
            + "  \(column(indicator(row), 12))"
            + "  \(column(workspace, 9))"
            + "  \(column(usageCell(for: row), spendColumnWidth))"
            // The rate the panel's own second line draws, beside the week it
            // replaced there.
            + "  \(column(rateCell(for: row), rateColumnWidth))"
            // The orphan count is not a column of its own: it is inside the
            // brackets `nameCell` already prints, exactly as the panel
            // prints it.
            + "  \(column(cpuCell(for: row), 5))"
            + "  \(activity(row, config: config))"
    }

    /// What the gateway said, before it was spread over the rows.
    ///
    /// Printed even when the poll failed: the line that says why is the point of
    /// the section on the machine where the relay is down.
    ///
    /// The assembled snapshot comes in alongside it because one of these figures
    /// is only known once the projects are: whether two copies of one session
    /// disagree about which *project* it started in cannot be answered by the
    /// poll, which has never seen a project (`DataSource.settle`).
    private static func printUsage(_ usage: UsageSnapshot, snapshot: SwitcherSnapshot) {
        // The header carries the promise every figure below it makes, because
        // the figures themselves cannot: a session's tokens are counted against
        // the project it was *started* in, not the ones it spent them in.
        print("Usage (claude_gw) — a session's spend counts against the project it was started in")
        for line in usageLines(usage, snapshot: snapshot) { print(line) }
        print("")
    }

    /// The section's rows, composed rather than printed.
    ///
    /// Split out of `printUsage` so a test can check that every figure in the
    /// section starts in one column, which only the assembled rows can show.
    /// Indented here rather than by the caller so the test measures the line as
    /// it is printed.
    static func usageLines(_ usage: UsageSnapshot, snapshot: SwitcherSnapshot) -> [String] {
        var lines: [String] = []
        // Every half in one line: each reason names its own endpoint already,
        // and the dump acts on none of them.
        if let failure = usage.failureText {
            lines.append("  " + label("unavailable:") + failure)
        }
        if usage.since != .distantPast {
            lines.append("  " + label("window:") + "applied since \(age(of: usage.since)) ago"
                + (usage.truncated ? ", truncated by the gateway's cap" : ""))
        }
        lines.append("  " + label("fleet 7d:") + percent(usage.fleetSevenDayMean))
        lines.append("  " + label("burn vs refill:") + burnLine(usage.fleetBurn))
        lines.append("  " + label("spend rate:") + spendRateLine(usage.fleetTokenRate))
        let accounts = usage.accounts.map {
            "\($0.label) 5h \(percent($0.fiveHour?.utilization)) 7d \(percent($0.sevenDay?.utilization))"
        }
        lines.append("  " + label("accounts:") + (accounts.isEmpty ? "-" : accounts.joined(separator: "   ")))
        lines.append("  " + label("total:") + formatTokens(usage.total))
        // Both windows, because both are spread over the rows: the week feeds the
        // tooltip and the projects column, the hour feeds the line the panel draws.
        lines.append("  " + label("start dirs:") + "\(usage.tokensBySlug.count) over 7d,"
            + " \(usage.hourlyTokensBySlug.count) in the last hour")
        lines.append("  " + unmatchedLine(window: "7d",
                                          sessions: usage.unmatchedSessions,
                                          tokens: usage.unmatched))
        lines.append("  " + unmatchedLine(window: "1h",
                                          sessions: usage.hourlyUnmatchedSessions,
                                          tokens: usage.hourlyUnmatched))
        lines.append("  " + ambiguousLine(window: "7d",
                                          sessions: snapshot.ambiguousUsageSessions,
                                          tokens: snapshot.ambiguousUsage))
        lines.append("  " + ambiguousLine(window: "1h",
                                          sessions: snapshot.ambiguousHourlySessions,
                                          tokens: snapshot.ambiguousHourlyUsage))
        return lines
    }

    /// The width of the label column this whole section is read by. `column` pads
    /// and never truncates, so a label wider than this shifts its figure right.
    /// Held by `testTheUsageSectionsFiguresAllStartInOneColumn`, which asks the
    /// assembled section (`usageLines`).
    static let usageLabelWidth = 21

    private static func label(_ text: String) -> String { column(text, usageLabelWidth) }

    /// The line that names the spend nothing may claim: sessions filed under more
    /// than one slug that `DataSource.settle` could not place
    /// (`SwitcherSnapshot.ambiguousUsage` lists the ways in).
    ///
    /// Printed whether or not there are any, like `no local session`: a bucket
    /// that appears only when non-empty teaches nobody it exists.
    ///
    /// Internal so a test can hold the text: a machine with a contested session is
    /// not a state a test run can arrange for itself.
    ///
    /// One line per window, because the two buckets hold different sessions: each
    /// window narrows its contest by its own start, and the two `/gw/sessions`
    /// calls fail apart.
    static func ambiguousLine(window: String, sessions: Int, tokens: TokenCounts) -> String {
        label("ambiguous \(window):") + "\(sessions) sessions, \(formatTokens(tokens))"
    }

    /// The line that names spend whose session has no transcript on this machine —
    /// the agent nodes, mostly. Real spend with no local owner rather than an
    /// error; one line per window, printed empty for the same reason
    /// `ambiguousLine` is.
    static func unmatchedLine(window: String, sessions: Int, tokens: TokenCounts) -> String {
        label("no local session \(window):") + "\(sessions) sessions, \(formatTokens(tokens))"
    }

    private static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0) } ?? "-"
    }

    /// The figure the popover and the menu bar lead with, with both sides of its
    /// division and everything that qualifies it.
    ///
    /// `-` is the state the popover falls back to the weekly quota in
    /// (`FleetCapacity.burnAgainstRefill`).
    ///
    /// Both rates are printed, not only the quotient, so the figure can be checked
    /// by hand: the burn is a difference of published readings, and the refill is
    /// `accounts × 100 / 168`. The account count and shallowest depth qualify it,
    /// and `>=` marks a floor (the panel's `≥` spelled for a terminal).
    private static func burnLine(_ burn: FleetCapacity.FleetBurn?) -> String {
        guard let burn else { return "-" }
        return String(format: "%.0f%%", burn.percent.rounded())
            + (burn.isLowerBound ? " (>=)" : "")
            + String(format: ", %d accounts over %.1f h", burn.accounts, burn.measuredHours)
            + String(format: ", %.3f pp/h burned vs %.3f pp/h refilled",
                     burn.burnRate, burn.refillRate)
    }

    /// What the fleet is spending right now, as the gateway measured it over its
    /// own five minutes — the supporting reading under the popover's lead.
    ///
    /// Raw digits rather than the `23.8M/h` the surface writes, so the line can be
    /// checked against the gateway by hand.
    private static func spendRateLine(_ tokensPerHour: Double?) -> String {
        tokensPerHour.map { String(format: "%.0f tokens/h ie", $0) } ?? "-"
    }

    /// One set of counters: the input-equivalent total, then the four raw
    /// numbers it was folded from.
    ///
    /// The four are never summed raw (they are billed at different rates); a
    /// total with an unnamed counter in it is a lower bound, marked `>=`, and an
    /// unnamed counter prints as `?`, not `0`. Counters that name nothing at all
    /// print as a bare `-`, like the projects column.
    ///
    /// Internal so a test can hold that dash: a down gateway is not a state a test
    /// run can arrange for itself.
    static func formatTokens(_ counts: TokenCounts) -> String {
        guard !counts.knowsNothing else { return "-" }
        let parts = [("in", counts.input), ("out", counts.output),
                     ("cw", counts.cacheCreation), ("cr", counts.cacheRead)]
            .map { "\($0.0) \($0.1.map { compact(Double($0)) } ?? "?")" }
        return "\(counts.isComplete ? "" : ">=")\(compact(counts.weighted())) ie"
            + " (\(parts.joined(separator: ", ")))"
    }

    /// The width of the "Projects" table's two spend columns: the widest cell each
    /// can hold. `>=9999.99M` is ten characters and `>=9999.99M/h` twelve; one
    /// digit more overflows, and `column` pads rather than cuts, so an overflowing
    /// cell shifts every column to its right. `compactTokens` has no `B` step.
    ///
    /// Held by `testTheSpendColumnsAreAsWideAsTheWidestCellTheyClaimToFit` (the
    /// constant against the cell) and
    /// `testTheSpendColumnsHoldTheTableToTheWidthTheyDeclare` (the table against
    /// the constants).
    static let spendColumnWidth = 10
    /// The rate column beside it — see `spendColumnWidth` for both.
    static let rateColumnWidth = 12

    /// The spend column of the "Projects" section: one input-equivalent number,
    /// or a dash when the row has none.
    ///
    /// Carries the same `>=` as the windows section above it: the two columns are
    /// read against each other.
    ///
    /// Internal for the same reason as `formatTokens`: which rows carry spend at
    /// all depends on what the gateway says about the machine the dump runs on.
    static func usageCell(for row: SwitcherRow) -> String {
        guard let value = row.usageInputEquivalent else { return "-" }
        return (row.usageIsLowerBound ? ">=" : "") + compact(value)
    }

    /// The rate column beside it: what the row spent over the last sliding hour,
    /// which is what the panel's second line draws (§2.9).
    ///
    /// Same shape as `usageCell` and the same `>=`, with the `/h` the panel
    /// writes so the rate cannot be mistaken for a total. Internal for the same
    /// reason as `usageCell`.
    static func rateCell(for row: SwitcherRow) -> String {
        guard let value = row.hourlyInputEquivalent else { return "-" }
        return (row.hourlyIsLowerBound ? ">=" : "") + compact(value) + "/h"
    }

    /// The snapshot the dump reports: the second one, a tick after the first.
    ///
    /// The CPU figure is a rate between two sweeps of the process table (SPEC
    /// §2.8); a single pass would print a dash on every row. The two builds are
    /// `SnapshotStore.activeInterval` apart, plus the 40–180 ms of disk each build
    /// spends around its sweep (§6), so the window is slightly longer than the
    /// panel's.
    ///
    /// A function so that a test can hold it to two calls.
    static func measuredSnapshot(_ take: () -> SwitcherSnapshot) -> SwitcherSnapshot {
        _ = take()
        Thread.sleep(forTimeInterval: SnapshotStore.activeInterval)
        return take()
    }

    /// The CPU column: what the row's sessions are burning, or a dash.
    ///
    /// The panel's own label (`SwitcherRowView.cpuLabel`), so the dash and the
    /// number appear on exactly the rows the panel shows them on, including `-`
    /// below one percent. Internal so a test can hold it.
    static func cpuCell(for row: SwitcherRow) -> String {
        SwitcherRowView.cpuLabel(for: row) ?? "-"
    }

    /// `21.30M`, `914k`, `512`: the coarsest unit that still tells two numbers
    /// apart at a glance. Shared with the panel's rows so the dump rounds as the
    /// panel does.
    private static func compact(_ value: Double) -> String {
        SwitcherRowView.compactTokens(value)
    }

    /// The name column of the "Projects" section: the name, then the count in
    /// brackets when something is running, padded out to exactly `width`.
    ///
    /// The name gives way when the pair is too long, as in the panel: the
    /// brackets stay whole and the name is cut to what is left, so the cell never
    /// exceeds `width`. Rows with a count are the orphan rows `rankedOrphans` puts
    /// at the top and any project with no window but a live session.
    ///
    /// Internal so a test can hold it: rows that carry a count are rows a test run
    /// cannot count on having.
    static func nameCell(for row: SwitcherRow, width: Int) -> String {
        let label = SwitcherRowView.countLabel(for: row)
        let budget = label.map { max(1, width - ($0.count + 1)) } ?? width
        return column(shorten(row.displayName, budget) + (label.map { " " + $0 } ?? ""), width)
    }

    /// Pads a cell to the column width, and never cuts it short.
    ///
    /// `String.padding(toLength:)` would truncate silently; anything that has to
    /// be cut is cut visibly, by `shorten`.
    private static func column(_ text: String, _ width: Int) -> String {
        guard text.count < width else { return text }
        return text + String(repeating: " ", count: width - text.count)
    }

    /// Sessions inside the activity window and when the newest one was written.
    /// The second is what `DataSource.ranked` sorts this section by; the count is
    /// printed alongside because it says how much work the project has seen.
    ///
    /// The stamp is printed to the second below a day and in days above it, so
    /// the dump shows the sub-second mtime order the data layer sorted by.
    private static func activity(_ row: SwitcherRow, config: Config) -> String {
        guard let path = row.project?.path else { return "outside the scan roots" }
        let activity = ClaudeSessions.activity(forPath: path, windowDays: config.activityWindowDays)
        guard let last = activity.lastSession else { return "no sessions" }
        return "\(activity.recentSessions) in \(config.activityWindowDays)d, last \(age(of: last)) ago"
    }

    /// How long ago something was, in the coarsest unit that still separates it
    /// from its neighbours: `4h 12m 03s` inside a day, `8d 3h` beyond one.
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let (days, hours) = (seconds / 86_400, seconds % 86_400 / 3600)
        guard days == 0 else { return "\(days)d \(hours)h" }
        return String(format: "%dh %02dm %02ds", hours, seconds % 3600 / 60, seconds % 60)
    }

    /// The folded indicator the row draws on its right. A row with no chat and
    /// no subagent draws none, and prints as `-` here.
    private static func indicator(_ row: SwitcherRow) -> String {
        row.status?.rawValue ?? "-"
    }

    /// The row's title as the panel writes it: the name, then the count in
    /// brackets when something is running. Same helper the view uses, so the
    /// dump cannot describe a row the panel does not draw.
    private static func title(_ row: SwitcherRow) -> String {
        guard let label = SwitcherRowView.countLabel(for: row) else { return row.displayName }
        return "\(row.displayName) \(label)"
    }

    /// Every state the row's chats are in, most urgent first. The row itself
    /// stopped showing this breakdown — the tooltip and this dump are where it
    /// lives now, which is why it is counted here rather than carried on the
    /// row: `sessions` already holds every state, and a second copy of the same
    /// facts is a second thing that can be wrong.
    private static func stateBreakdown(_ row: SwitcherRow) -> String {
        guard !row.sessions.isEmpty else { return "-" }
        return AgentState.allCases.reversed()
            .map { state in (state, row.sessions.filter { $0.state == state }.count) }
            .filter { $0.1 > 0 }
            .map { "\($0.0.rawValue)\($0.1 > 1 ? " x\($0.1)" : "")" }
            .joined(separator: " ")
    }

    private static func formatContext(_ row: SwitcherRow) -> String {
        guard let used = row.contextUsedTokens else { return "-" }
        let thousands = Double(used) / 1000
        guard let fraction = row.contextFraction else { return String(format: "%.0fk", thousands) }
        return String(format: "%.0fk (%.0f%%)", thousands, fraction * 100)
    }

    private static func shorten(_ text: String?, _ limit: Int) -> String {
        guard let text, !text.isEmpty else { return "-" }
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count <= limit ? single : String(single.prefix(limit - 1)) + "\u{2026}"
    }
}
