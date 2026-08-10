import Foundation

/// Joins the three independent sources — open windows, the project index and
/// live Claude sessions — into the rows the panel shows.
final class DataSource {
    private let config: Config
    private let index = WorkspaceIndex()

    init(config: Config) {
        self.config = config
    }

    /// Builds a complete snapshot. Blocking and disk-bound: call it off the main
    /// thread.
    func snapshot() -> SwitcherSnapshot {
        let projects = index.projects(config: config)
        let windows = VSCodeWindows.listWindows(bundleID: config.editorBundleID)
        let sessions = ClaudeSessions.liveSessions(config: config)

        let projectsByRootName = Dictionary(grouping: projects, by: \.rootName)
        var sessionsByProjectPath: [String: [ClaudeSessionInfo]] = [:]
        var orphanSessions: [ClaudeSessionInfo] = []
        for session in sessions {
            if let project = Self.project(for: session.cwd, in: projects) {
                sessionsByProjectPath[project.path, default: []].append(session)
            } else {
                orphanSessions.append(session)
            }
        }

        // Windows in z-order, grouped by project so several windows on the same
        // project can share out that project's sessions.
        var windowsByKey: [String: [VSCodeWindowInfo]] = [:]
        var keyForWindow: [String: String] = [:]
        for window in windows {
            let project = window.rootName.flatMap { projectsByRootName[$0]?.first }
            let key = project?.path ?? "rootName:\(window.rootName ?? window.title)"
            windowsByKey[key, default: []].append(window)
            keyForWindow[window.id] = key
        }

        var sessionsByWindow: [String: [ClaudeSessionInfo]] = [:]
        for (key, groupWindows) in windowsByKey {
            let pool = sessionsByProjectPath[key] ?? []
            for (window, assigned) in Self.distribute(sessions: pool, over: groupWindows) {
                sessionsByWindow[window] = assigned
            }
        }

        var openWindows: [SwitcherRow] = []
        var openProjectPaths = Set<String>()
        for window in windows {
            let key = keyForWindow[window.id]
            let project = key.flatMap { key in projects.first { $0.path == key } }
            if let project { openProjectPaths.insert(project.path) }
            openWindows.append(makeWindowRow(window: window,
                                             project: project,
                                             sessions: sessionsByWindow[window.id] ?? []))
        }

        var projectRows: [SwitcherRow] = []
        for project in projects where !openProjectPaths.contains(project.path) {
            projectRows.append(SwitcherRow(id: "project:\(project.path)",
                                           kind: .project,
                                           displayName: project.displayName,
                                           colorHex: project.colorHex,
                                           project: project,
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
                                           lastActivity: project.mtime))
        }

        // Sessions whose cwd is outside every scan root would otherwise vanish;
        // they are surfaced as rows of their own so nothing is silently lost.
        for session in orphanSessions where !windows.contains(where: { sessionsByWindow[$0.id]?.contains(where: { $0.sessionId == session.sessionId }) == true }) {
            let name = (session.cwd as NSString).lastPathComponent
            projectRows.append(SwitcherRow(id: "session:\(session.sessionId)",
                                           kind: .project,
                                           displayName: name,
                                           colorHex: WorkspaceIndex.fallbackColor(for: name),
                                           project: nil,
                                           window: nil,
                                           sessions: [session],
                                           state: session.state,
                                           stateCount: 1,
                                           activeSubagents: session.activeSubagents,
                                           subagentDescriptions: session.subagents.filter(\.isActive).compactMap(\.description),
                                           chatTopic: session.topic,
                                           model: session.model,
                                           contextUsedTokens: session.contextUsedTokens,
                                           contextLimitTokens: session.contextLimitTokens,
                                           lastActivity: session.lastActivity))
        }

        return SwitcherSnapshot(openWindows: openWindows,
                                projects: projectRows,
                                accessibilityTrusted: VSCodeWindows.isAccessibilityTrusted(),
                                generatedAt: Date())
    }

    private func makeWindowRow(window: VSCodeWindowInfo,
                               project: ProjectInfo?,
                               sessions: [ClaudeSessionInfo]) -> SwitcherRow {
        let name = project?.displayName ?? window.rootName ?? window.title
        let color = project?.colorHex ?? WorkspaceIndex.fallbackColor(for: name)
        let active = Self.activeSession(for: window, among: sessions)

        let state = sessions.map(\.state).max()
        let stateCount = state.map { value in sessions.filter { $0.state == value }.count } ?? 0
        let activeSubagents = sessions.reduce(0) { $0 + $1.activeSubagents }
        let descriptions = sessions.flatMap { $0.subagents.filter(\.isActive).compactMap(\.description) }

        return SwitcherRow(id: "window:\(window.id)",
                           kind: .window,
                           displayName: name,
                           colorHex: color,
                           project: project,
                           window: window,
                           sessions: sessions,
                           state: state,
                           stateCount: stateCount,
                           activeSubagents: activeSubagents,
                           subagentDescriptions: descriptions,
                           chatTopic: active?.topic ?? window.chatTopicPrefix,
                           model: active?.model,
                           contextUsedTokens: active?.contextUsedTokens,
                           contextLimitTokens: active?.contextLimitTokens,
                           lastActivity: active?.lastActivity ?? sessions.first?.lastActivity)
    }

    // MARK: - Matching

    /// The project a working directory belongs to: an exact match, otherwise the
    /// deepest project the path sits inside.
    static func project(for cwd: String, in projects: [ProjectInfo]) -> ProjectInfo? {
        if let exact = projects.first(where: { $0.path == cwd }) { return exact }
        return projects
            .filter { cwd.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
    }

    /// Spreads a project's sessions over the windows that show that project.
    ///
    /// A window title carries the active chat topic truncated with an ellipsis,
    /// so the session whose topic starts with that prefix is the one visible in
    /// that window. Sessions nobody claimed go to the frontmost window.
    static func distribute(sessions: [ClaudeSessionInfo],
                           over windows: [VSCodeWindowInfo]) -> [(String, [ClaudeSessionInfo])] {
        guard !windows.isEmpty else { return [] }
        guard windows.count > 1 else { return [(windows[0].id, sessions)] }

        var remaining = sessions
        var assigned: [String: [ClaudeSessionInfo]] = [:]
        for window in windows {
            guard let index = remaining.firstIndex(where: { matches(window: window, session: $0) }) else { continue }
            assigned[window.id] = [remaining.remove(at: index)]
        }
        if !remaining.isEmpty {
            assigned[windows[0].id, default: []].append(contentsOf: remaining)
        }
        return windows.map { ($0.id, assigned[$0.id] ?? []) }
    }

    /// The session shown in a window: the topic match if there is one, otherwise
    /// the most recently active session assigned to it.
    static func activeSession(for window: VSCodeWindowInfo,
                              among sessions: [ClaudeSessionInfo]) -> ClaudeSessionInfo? {
        sessions.first { matches(window: window, session: $0) } ?? sessions.first
    }

    private static func matches(window: VSCodeWindowInfo, session: ClaudeSessionInfo) -> Bool {
        guard let prefix = window.chatTopicPrefix, let topic = session.topic else { return false }
        let trimmed = prefix
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{2026}. "))
            .trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 4 else { return false }
        return topic.hasPrefix(trimmed)
    }
}
