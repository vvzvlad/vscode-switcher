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
    /// built from. `spendColumnWidth` and `rateColumnWidth` were pinned to the
    /// widest cell they claim to fit, and nothing pinned the *table* to them.
    /// Writing a literal here instead of the constant — an 8, which is what the
    /// column was before anybody measured it and is too narrow for the reachable
    /// `>=123.45M` — shifted every column to the right of it on the rows that fill
    /// the cell, and the whole suite stayed green, all 627 tests of it as it stood
    /// while this line had no test at all. What the width exists for is that the
    /// columns line up, so that is what
    /// `testTheSpendColumnsHoldTheTableToTheWidthTheyDeclare` asks, of this string.
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
        // Every half in one line: each reason names its own endpoint already,
        // and the dump acts on none of them.
        if let failure = usage.failureText {
            print("  unavailable:      \(failure)")
        }
        if usage.since != .distantPast {
            print("  window:           applied since \(age(of: usage.since)) ago"
                + (usage.truncated ? ", truncated by the gateway's cap" : ""))
        }
        print("  fleet 7d:         \(percent(usage.fleetSevenDayMean))")
        print("  spend rate:       \(rateLine(now: usage.fleetTokenRate, allowance: usage.sustainable))")
        let accounts = usage.accounts.map {
            "\($0.label) 5h \(percent($0.fiveHour?.utilization)) 7d \(percent($0.sevenDay?.utilization))"
        }
        print("  accounts:         \(accounts.isEmpty ? "-" : accounts.joined(separator: "   "))")
        print("  total:            \(formatTokens(usage.total))")
        // Both windows, because both are spread over the rows: the week feeds the
        // tooltip and the projects column, the hour feeds the line the panel draws.
        print("  start dirs:       \(usage.tokensBySlug.count) over 7d,"
            + " \(usage.hourlyTokensBySlug.count) in the last hour")
        print("  no local session: \(usage.unmatchedSessions) sessions, \(formatTokens(usage.unmatched))")
        let week = ambiguousLine(window: "7d",
                                 sessions: snapshot.ambiguousUsageSessions,
                                 tokens: snapshot.ambiguousUsage)
        let hour = ambiguousLine(window: "1h",
                                 sessions: snapshot.ambiguousHourlySessions,
                                 tokens: snapshot.ambiguousHourlyUsage)
        print("  " + week)
        print("  " + hour)
        print("")
    }

    /// The line that names the spend nothing may claim: sessions filed under two
    /// slugs that belong to two different projects.
    ///
    /// Printed whether or not there are any, exactly like `no local session`
    /// above it. A bucket that appears only when it is non-empty teaches nobody
    /// it exists, and the misattribution this one replaced was invisible by
    /// construction. It is no longer the empty bucket it was when it was written,
    /// either: on 2026-08-27 this machine printed 16 sessions and 637.15M
    /// input-equivalent over the week, so the premise that the duplicated
    /// identifiers here are all older than the gateway's window no longer holds.
    /// §2.7 keeps the figure, its drift over the day, and the fact that why the
    /// bucket grew is not established.
    ///
    /// Internal so a test can hold the text: `printUsage` prints whatever the
    /// gateway said about the machine the dump runs on, and a machine with a
    /// contested session is not a state a test run can arrange for itself.
    ///
    /// One line per window, and both are printed, because the two buckets can hold
    /// different sets of sessions: the two `/gw/sessions` calls fail apart, so an
    /// hour's contested session need not appear in the week's bucket at all. The
    /// gateway's 200-consumer cap on the week would do the same and is not doing
    /// it today — both readings are on `SwitcherSnapshot.ambiguousHourlyUsage`.
    /// Two short lines rather than one long one for the same reason every other
    /// line here is short — the label column is what makes the section readable.
    static func ambiguousLine(window: String, sessions: Int, tokens: TokenCounts) -> String {
        "\(column("ambiguous \(window):", 18))\(sessions) sessions, \(formatTokens(tokens))"
    }

    private static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0) } ?? "-"
    }

    /// The pair of rates the popover leads with, and everything the second of
    /// them was built from.
    ///
    /// The two halves are printed apart because they can be missing apart: the
    /// current rate arrives with the quota once a minute and needs no estimating
    /// at all, the allowance arrives with the histories once every ten minutes
    /// and is a chain of four measurements. `-` on either side is the state the
    /// popover falls back to the weekly quota in, and the tail says which link
    /// of the chain is the one that moved.
    ///
    /// Raw digits rather than the `23.8M/h` the surface writes: this line exists
    /// to be checked against the gateway by hand, and a rounded million cannot
    /// be. The exchange rate is the one figure here that no other line carries,
    /// and it is the whole conversion — points into tokens.
    ///
    /// **The tail is the whole of what used to be a second line.** A `weekly
    /// load:` line stood above this one and printed a week's *estimated* demand
    /// against a supply, naming which of two estimators had produced it; both
    /// estimators are gone, because the gateway measures the demand and the first
    /// figure on this line is that measurement. What the old line carried that
    /// this one has to keep is the qualification: a ratio is only as good as how
    /// many accounts stood behind it and how deep the shallowest of their
    /// histories went, so both are printed, and `>=` marks a figure that is only
    /// a floor — the panel's `≥` spelled for a terminal, as the token columns
    /// already are.
    private static func rateLine(now: Double?, allowance: FleetCapacity.SustainableRate?) -> String {
        let current = now.map { String(format: "%.0f tokens/h ie", $0) } ?? "-"
        guard let allowance else { return current + " of - sustainable" }
        let ratio = now.map {
            String(format: " (%@%.0f%%)", allowance.isLowerBound ? ">=" : "",
                   $0 / allowance.tokensPerHour * 100)
        } ?? ""
        return current
            + String(format: " of %.0f tokens/h ie sustainable", allowance.tokensPerHour) + ratio
            + String(format: ", %.3fM tokens/pp", allowance.tokensPerPoint / 1e6)
            + String(format: ", %.3f pp/h over %d work h/day", allowance.allowedWorkRate, allowance.workHoursPerDay)
            + String(format: " + %d sleeping h at %.3f pp/h", allowance.sleepHoursPerDay, allowance.sleepRate)
            + String(format: ", %d accounts over %.1f h", allowance.accounts, allowance.measuredHours)
    }

    /// One set of counters: the input-equivalent total, then the four raw
    /// numbers it was folded from.
    ///
    /// The four are never summed raw — they are billed at different rates — and
    /// a total that had an unnamed counter in it is a lower bound, which is what
    /// the leading `>=` says. A counter the gateway did not name prints as `?`,
    /// not as `0`.
    ///
    /// Counters that name nothing at all print as a bare `-`, the same dash the
    /// projects column shows: `0 ie (in ?, out ?, cw ?, cr ?)` is the sum of
    /// nothing known dressed up as a measurement, and it read as a flat
    /// contradiction on the line it turns up on most — `no local session: 0
    /// sessions`, whose counters are `TokenCounts.zero` precisely because there
    /// were none to add.
    ///
    /// Internal so a test can hold that dash: the failing case is what the dump
    /// prints on a machine whose gateway is down, which is not a state a test
    /// run can arrange for itself.
    static func formatTokens(_ counts: TokenCounts) -> String {
        guard !counts.knowsNothing else { return "-" }
        let parts = [("in", counts.input), ("out", counts.output),
                     ("cw", counts.cacheCreation), ("cr", counts.cacheRead)]
            .map { "\($0.0) \($0.1.map { compact(Double($0)) } ?? "?")" }
        return "\(counts.isComplete ? "" : ">=")\(compact(counts.weighted())) ie"
            + " (\(parts.joined(separator: ", ")))"
    }

    /// The width of the "Projects" table's two spend columns.
    ///
    /// **What today's machine reaches is far short of them, and that is measured
    /// rather than assumed** (live `--dump`, 2026-08-27): over all 103 rows of the
    /// section the widest week cell was `46.62M`, six characters, and the rate
    /// column printed `-` on every one of them — every project that had spent in
    /// the last hour had a window open, and a row with a window is not in this
    /// table. The same two formatters on the nine window rows above reached
    /// `252.57M` and `4.84M/h`, seven characters each. The previous width, 8, was
    /// justified the other way round — by a worst case nobody had measured — and
    /// was already too narrow for `>=123.45M`.
    ///
    /// **What the widths are set to is the widest cell each column can hold**, and
    /// it is the same magnitude for both: `>=9999.99M` is exactly ten characters,
    /// `>=9999.99M/h` exactly twelve, so the two extra characters here pay for
    /// `/h` and buy no extra digits. Four digits of millions with the `>=` a lower
    /// bound wears, in other words. One digit more overflows — `>=12345.67M`,
    /// eleven characters — and `column` pads rather than cuts, so an overflowing
    /// cell shifts every column to its right instead of being truncated. That edge
    /// is real rather than decorative because `compactTokens` has no `B` step:
    /// millions simply keep growing digits. Reaching it takes one project spending
    /// 10^10 input-equivalent tokens inside the window, against 2015.86M for the
    /// whole fleet's week on the day of the measurement.
    ///
    /// Named rather than written at the call site so that
    /// `testTheSpendColumnsAreAsWideAsTheWidestCellTheyClaimToFit` can hold them to
    /// exactly that: a width with its justification in a comment and nothing asking
    /// about it is a width nobody is guarding. That test pins the constant to the
    /// cell and nothing more, though, so a literal written at the call site put the
    /// too-narrow column back with the whole suite green — what pins the table to
    /// the constants is `testTheSpendColumnsHoldTheTableToTheWidthTheyDeclare`, which
    /// asks `projectRow` whether its columns line up.
    static let spendColumnWidth = 10
    /// The rate column beside it — see `spendColumnWidth` for both.
    static let rateColumnWidth = 12

    /// The spend column of the "Projects" section: one input-equivalent number,
    /// or a dash when the row has none.
    ///
    /// Carries the same `>=` as the windows section above it. It went missing
    /// here for a while, and a lower bound that looks like an exact figure in
    /// one of two sections is worse than either — the two columns are read
    /// against each other.
    ///
    /// Internal for the same reason as `formatTokens`: which rows carry spend at
    /// all depends on what the gateway says about the machine the dump runs on.
    static func usageCell(for row: SwitcherRow) -> String {
        guard let value = row.usageInputEquivalent else { return "-" }
        return (row.usageIsLowerBound ? ">=" : "") + compact(value)
    }

    /// The rate column beside it: what the row spent over the last sliding hour,
    /// which is what the panel's second line now draws (§2.9).
    ///
    /// Same shape as `usageCell` and the same `>=` — the panel's `≥` spelled for a
    /// terminal — with the `/h` the panel writes, because a rate printed without
    /// its unit next to a total is two numbers that cannot be told apart.
    ///
    /// Internal for the same reason as `usageCell`: which rows carry an hour's
    /// spend at all depends on what the gateway says about the machine the dump
    /// runs on.
    static func rateCell(for row: SwitcherRow) -> String {
        guard let value = row.hourlyInputEquivalent else { return "-" }
        return (row.hourlyIsLowerBound ? ">=" : "") + compact(value) + "/h"
    }

    /// The snapshot the dump reports: the second one, a tick after the first.
    ///
    /// The CPU figure is a rate, and a rate is a difference between two sweeps
    /// of the process table (SPEC §2.8). The agent takes a sweep a second and
    /// always has a predecessor; a single-pass dump would print a dash on every
    /// row for want of one. So the first snapshot is thrown away.
    ///
    /// The two builds are `SnapshotStore.activeInterval` apart, which is the
    /// panel's own interval while it is on screen — the window is taken from the
    /// panel's tick rather than chosen by the dump.
    ///
    /// It is not *equal* to the panel's window, and saying it was would be a
    /// claim about code this function cannot see. The sweep happens partway
    /// through each build, so the gap between the two sweeps is this sleep plus
    /// the tail of the first build and the head of the second — the 40–180 ms of
    /// disk that `index.projects` and `sessionTimes` spend (§6), on both sides.
    /// A rate measured over 1.1 s and labelled as being over 1.0 s is off by
    /// that fraction and no more, which is well inside what the figure is read
    /// for; making the sleep chase the difference would need the build to report
    /// when its sweep happened, which is machinery for a rounding error.
    ///
    /// A function rather than four lines inside `run` so that a test can hold
    /// it to two calls: deleting the first pass costs nothing anywhere else,
    /// and the dump would quietly print `-` down the whole column.
    static func measuredSnapshot(_ take: () -> SwitcherSnapshot) -> SwitcherSnapshot {
        _ = take()
        Thread.sleep(forTimeInterval: SnapshotStore.activeInterval)
        return take()
    }

    /// The CPU column: what the row's sessions are burning, or a dash.
    ///
    /// The panel's own label, so the dash and the number appear on exactly the
    /// rows the panel shows them on — including the rows below one percent,
    /// which print `-` here because that is what the panel draws there
    /// (`SwitcherRowView.cpuLabel`). A dump that reported a tenth of a core the
    /// panel is deliberately silent about would be a second opinion about the
    /// same row.
    ///
    /// Internal so a test can hold it: which rows are burning anything at all
    /// depends on the machine the dump runs on.
    static func cpuCell(for row: SwitcherRow) -> String {
        SwitcherRowView.cpuLabel(for: row) ?? "-"
    }

    /// `21.30M`, `914k`, `512`: the coarsest unit that still tells two numbers
    /// apart at a glance. The panel's rows write the same figure, so the
    /// formatting lives in one place — the same arrangement `countLabel` is in,
    /// and for the same reason: a dump that rounds differently from the panel
    /// describes a row the panel does not draw.
    private static func compact(_ value: Double) -> String {
        SwitcherRowView.compactTokens(value)
    }

    /// The name column of the "Projects" section: the name, then the count in
    /// brackets when something is running, padded out to exactly `width`.
    ///
    /// The name is what gives way when the pair is too long, as in the panel:
    /// the brackets stay whole and the name is cut to what is left of the cell.
    /// Cutting the name to the full width first and appending the brackets
    /// afterwards made the cell as wide as the two together, on every row where
    /// the two do not fit in 34 — from 23 characters of name with a one-digit
    /// count, and 48 against a column of 34 for the longest name with a
    /// three-digit one. `column` pads without cutting, so every column after it
    /// shifted right on those rows alone. Which rows can have a count at all is
    /// worth being exact about: the
    /// orphan rows `rankedOrphans` puts at the top of the section — they are
    /// orphans by `id`, `cwd:<path>`, and by name just the last component of
    /// that path — and, further down the same list, any ordinary project that
    /// has no window open but does have a live session in it.
    ///
    /// Internal rather than private so a test can hold it to that: `printText`
    /// prints a whole snapshot of the machine it runs on, and the rows that
    /// carry a count are exactly the rows a test run cannot count on having.
    static func nameCell(for row: SwitcherRow, width: Int) -> String {
        let label = SwitcherRowView.countLabel(for: row)
        let budget = label.map { max(1, width - ($0.count + 1)) } ?? width
        return column(shorten(row.displayName, budget) + (label.map { " " + $0 } ?? ""), width)
    }

    /// Pads a cell to the column width, and never cuts it short.
    ///
    /// `String.padding(toLength:)` truncates whatever is longer than the length
    /// it is given, silently: `attention 100` used to print as `attention 10`,
    /// which is a diagnostic dump lying about the number it exists to report.
    /// Anything that genuinely has to be cut is cut visibly, by `shorten`.
    private static func column(_ text: String, _ width: Int) -> String {
        guard text.count < width else { return text }
        return text + String(repeating: " ", count: width - text.count)
    }

    /// Sessions inside the activity window and when the newest one was written.
    /// The second is what `DataSource.ranked` sorts this section by; the count is
    /// printed alongside because it says how much work the project has seen,
    /// which is worth knowing even though it no longer decides the order.
    ///
    /// The stamp is printed to the second, and in days only for what is older
    /// than a day. Whole days alone — which is what this printed while the count
    /// was the key — cannot explain the order it is printed in: the key is a
    /// sub-second mtime, and the top of a live list is several rows of "last 0d
    /// ago" in an order nothing in the dump accounts for. The dump exists to
    /// verify the data layer, so it has to show the number the data layer sorted
    /// by; below a day that means hours, minutes and seconds, and above it the
    /// days are what the eye wants.
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
