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
        let snapshot = DataSource(config: config, usage: cache).snapshot()
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
            if let usage = row.usage {
                print("      usage:     \(formatTokens(usage))")
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
                print("  - \(title(row))  \(indicator(row))  [\(stateBreakdown(row))]  \(shorten(row.chatTopic, 60))")
            }
            print("")
        }

        // In the order the panel shows them, which is what the ranking is for.
        print("Projects section: \(snapshot.projects.count) (showing 15, most recently worked in first)")
        for row in snapshot.projects.prefix(15) {
            let workspace = row.project?.workspaceFile == nil ? "git" : "workspace"
            // The indicator is printed here too, because this is where the rule
            // "no chat, no subagent, no icon" is worth seeing: most of this
            // section is projects nobody has run an agent in.
            print("  - \(nameCell(for: row, width: 34)) \(row.colorHex)"
                + "  \(column(indicator(row), 12))"
                + "  \(column(workspace, 9))"
                + "  \(column(usageCell(for: row), 8))"
                + "  \(activity(row, config: config))")
        }
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
        print("  weekly load:      \(loadLine(usage.fleetLoad))")
        let accounts = usage.accounts.map {
            "\($0.label) 5h \(percent($0.fiveHour?.utilization)) 7d \(percent($0.sevenDay?.utilization))"
        }
        print("  accounts:         \(accounts.isEmpty ? "-" : accounts.joined(separator: "   "))")
        print("  total:            \(formatTokens(usage.total))")
        print("  start dirs:       \(usage.tokensBySlug.count)")
        print("  no local session: \(usage.unmatchedSessions) sessions, \(formatTokens(usage.unmatched))")
        print("  \(ambiguousLine(sessions: snapshot.ambiguousUsageSessions, tokens: snapshot.ambiguousUsage))")
        print("")
    }

    /// The line that names the spend nothing may claim: sessions filed under two
    /// slugs that belong to two different projects.
    ///
    /// Printed whether or not there are any, exactly like `no local session`
    /// above it. A bucket that appears only when it is non-empty teaches nobody
    /// it exists, and this one is empty most weeks — the duplicated identifiers
    /// on this machine are all older than the gateway's window — while the
    /// misattribution it replaced was invisible by construction.
    ///
    /// Internal so a test can hold the text: `printUsage` prints whatever the
    /// gateway said about the machine the dump runs on, and a machine with a
    /// contested session is not a state a test run can arrange for itself.
    static func ambiguousLine(sessions: Int, tokens: TokenCounts) -> String {
        "ambiguous:        \(sessions) sessions, \(formatTokens(tokens))"
    }

    private static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0) } ?? "-"
    }

    /// The week's demand against the week's supply, with everything the figure
    /// is qualified by written out beside it.
    ///
    /// `>=` rather than the panel's `≥`, the way the token columns are already
    /// spelled here: this line goes to a terminal. The two numbers after it are
    /// not decoration — a load is only as good as how many accounts stood behind
    /// it and how deep the shallowest of their histories went, and a dump that
    /// printed the percentage alone would hide an answer measured over one
    /// account out of three.
    ///
    /// **It names the estimator, and then everything that estimator was built
    /// from.** Two of them can produce this figure and the setting that picks
    /// them is a line in a file (§2.7); without the name, a number that moved
    /// because the window moved is indistinguishable from one that moved because
    /// the fleet did. The projection's tail is what it takes to rebuild the
    /// estimate by hand — both rates, the split of the day, and how many work
    /// hours the recent rate actually reached back over.
    private static func loadLine(_ load: FleetLoad?) -> String {
        guard let load else { return "-" }
        let head = (load.isLowerBound ? ">=" : "")
            + String(format: "%.0f%% of capacity", load.percent)
            + String(format: ", %d accounts over %.1f h", load.accounts, load.measuredHours)
        guard let projection = load.projection else { return head + ", window average" }
        return head + String(format: ", projected from %.1f work h at %.3f pp/h",
                             projection.recentWorkHours, projection.recentWorkRate)
            + String(format: " + %d sleeping h at %.3f pp/h (work %d h/day)",
                     projection.sleepHoursPerDay, projection.sleepRate, projection.workHoursPerDay)
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
