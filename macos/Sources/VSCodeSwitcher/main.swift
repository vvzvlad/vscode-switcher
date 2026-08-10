import Foundation

// Stage 1 builds the data layer only. The entry point is a console tool that
// dumps the assembled model so the sources can be verified without any UI; the
// panel is added on top of `DataSource` in the next stage.

let arguments = Array(CommandLine.arguments.dropFirst())

guard arguments.contains("--dump") else {
    print("""
    VSCodeSwitcher — data layer (stage 1).

      --dump          print the assembled switcher model
      --dump --json   the same as JSON

    The menu bar agent and the sliding panel are added in the next stage.
    """)
    exit(0)
}

let config = Config.load()
let snapshot = DataSource(config: config).snapshot()

if arguments.contains("--json") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(snapshot) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        FileHandle.standardError.write(Data("failed to encode snapshot\n".utf8))
        exit(1)
    }
    exit(0)
}

func formatContext(_ row: SwitcherRow) -> String {
    guard let used = row.contextUsedTokens else { return "-" }
    let thousands = Double(used) / 1000
    guard let fraction = row.contextFraction else { return String(format: "%.0fk", thousands) }
    return String(format: "%.0fk (%.0f%%)", thousands, fraction * 100)
}

func shorten(_ text: String?, _ limit: Int) -> String {
    guard let text, !text.isEmpty else { return "-" }
    let single = text.replacingOccurrences(of: "\n", with: " ")
    return single.count <= limit ? single : String(single.prefix(limit - 1)) + "\u{2026}"
}

print("Config")
print("  roots:            \(config.resolvedProjectRoots.map(\.path).joined(separator: ", "))")
print("  depth:            \(config.scanDepth)")
print("  transcript tail:  \(config.transcriptTailBytes / 1024) KiB")
print("  editor:           \(config.editorBundleID)")
print("  accessibility:    \(snapshot.accessibilityTrusted ? "granted" : "NOT GRANTED — window list will be empty")")
print("")

print("Open windows (z-order, front first): \(snapshot.openWindows.count)")
for (position, row) in snapshot.openWindows.enumerated() {
    let state = row.state.map { "\($0.rawValue)\(row.stateCount > 1 ? " x\(row.stateCount)" : "")" } ?? "-"
    print("  \(position + 1). \(row.displayName)  \(row.colorHex)  [\(state)]")
    print("      title:     \(shorten(row.window?.title, 90))")
    print("      topic:     \(shorten(row.chatTopic, 90))")
    print("      model:     \(row.model ?? "-")   context: \(formatContext(row))   subagents: \(row.activeSubagents)")
    if !row.subagentDescriptions.isEmpty {
        print("      running:   \(row.subagentDescriptions.map { shorten($0, 50) }.joined(separator: "; "))")
    }
    if row.sessions.count > 1 || !row.sessions.isEmpty {
        print("      sessions:  \(row.sessions.count)")
        for session in row.sessions {
            let context = session.contextUsedTokens.map { "\($0 / 1000)k" } ?? "-"
            print("        - \(session.state.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
                + " src=\(session.stateSource.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
                + " pid=\(session.pid) ctx=\(context) sub=\(session.activeSubagents)"
                + " \(shorten(session.topic, 46))")
        }
    }
}
print("")

let unopened = snapshot.projects.filter { $0.sessions.isEmpty }
let strayed = snapshot.projects.filter { !$0.sessions.isEmpty }
if !strayed.isEmpty {
    print("Live sessions without a window: \(strayed.count)")
    for row in strayed {
        print("  - \(row.displayName)  [\(row.state?.rawValue ?? "-")]  \(shorten(row.chatTopic, 60))")
    }
    print("")
}

print("Projects without an open window: \(unopened.count) (showing 15 most recent)")
for row in unopened.prefix(15) {
    let workspace = row.project?.workspaceFile == nil ? "git" : "workspace"
    print("  - \(row.displayName.padding(toLength: 34, withPad: " ", startingAt: 0)) \(row.colorHex)  \(workspace)")
}
