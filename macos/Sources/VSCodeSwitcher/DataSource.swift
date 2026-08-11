import Foundation

/// Joins the three independent sources — open windows, the project index and
/// live Claude sessions — into the rows the panel shows.
///
/// Threading: `snapshot()` is safe to call from any queue and is meant to be
/// called off the main one — `Task.detached { let snapshot = dataSource.snapshot() }`
/// — with the result applied on the main thread. It blocks on disk for 0.1 s or
/// more, so calling it on the main thread freezes the UI for that long.
///
/// `@unchecked Sendable`: every stored property is either a `let` holding a
/// value type or an object whose own mutable state sits behind a lock.
final class DataSource: @unchecked Sendable {
    private let config: Config
    private let index = WorkspaceIndex()

    private let snapshotLock = NSLock()
    private var lastSnapshot: SwitcherSnapshot?

    /// A caller that had to wait for a snapshot already in flight gets that
    /// snapshot instead of immediately rescanning the same disk. Short enough
    /// that a UI refreshing once a second is never served a stale list.
    private static let coalesceWindow: TimeInterval = 0.2

    init(config: Config) {
        self.config = config
    }

    /// Builds a complete snapshot. Blocking and disk-bound: call it off the main
    /// thread. Concurrent calls are serialised, and overlapping ones share a
    /// result rather than doubling the I/O.
    func snapshot() -> SwitcherSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }

        if let lastSnapshot, Date().timeIntervalSince(lastSnapshot.generatedAt) < Self.coalesceWindow {
            return lastSnapshot
        }
        let fresh = build()
        lastSnapshot = fresh
        return fresh
    }

    private func build() -> SwitcherSnapshot {
        Self.assemble(projects: index.projects(config: config),
                      windows: VSCodeWindows.listWindows(bundleID: config.editorBundleID),
                      sessions: ClaudeSessions.liveSessions(config: config),
                      accessibilityTrusted: VSCodeWindows.isAccessibilityTrusted())
    }

    /// The join itself, with the three sources already read. Pure, so the row
    /// assembly can be exercised without a disk or an Accessibility grant.
    static func assemble(projects: [ProjectInfo],
                         windows: [VSCodeWindowInfo],
                         sessions: [ClaudeSessionInfo],
                         accessibilityTrusted: Bool) -> SwitcherSnapshot {
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

        // Sessions that no window claimed. This is the normal case, not an edge
        // one: without Accessibility permission the window list is empty, and
        // reading the session pool only through the windows made every running
        // agent disappear from a panel that had already read all of it.
        var assignedSessionIDs = Set<String>()
        for assigned in sessionsByWindow.values {
            for session in assigned { assignedSessionIDs.insert(session.sessionId) }
        }
        var unassignedByProjectPath: [String: [ClaudeSessionInfo]] = [:]
        for (path, pool) in sessionsByProjectPath {
            let unassigned = pool.filter { !assignedSessionIDs.contains($0.sessionId) }
            if !unassigned.isEmpty { unassignedByProjectPath[path] = unassigned }
        }

        var openWindows: [SwitcherRow] = []
        var openProjectPaths = Set<String>()
        for window in windows {
            let key = keyForWindow[window.id]
            let project = key.flatMap { key in projects.first { $0.path == key } }
            if let project { openProjectPaths.insert(project.path) }
            openWindows.append(Self.makeWindowRow(window: window,
                                                  project: project,
                                                  sessions: sessionsByWindow[window.id] ?? []))
        }

        var projectRows: [SwitcherRow] = []
        for project in projects where !openProjectPaths.contains(project.path) {
            let sessions = unassignedByProjectPath.removeValue(forKey: project.path) ?? []
            projectRows.append(Self.makeProjectRow(project: project, sessions: sessions))
        }

        // A project can have a window and still hold sessions that window did
        // not take (its own sessions went to a different key). They join the
        // orphans rather than vanish.
        for path in unassignedByProjectPath.keys.sorted() {
            orphanSessions.append(contentsOf: unassignedByProjectPath[path] ?? [])
        }

        // Sessions whose cwd is outside every scan root belong to no project and
        // therefore to no window; they get rows of their own so a running agent
        // is never silently dropped from the list.
        for session in orphanSessions {
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
                                accessibilityTrusted: accessibilityTrusted,
                                generatedAt: Date())
    }

    private static func makeWindowRow(window: VSCodeWindowInfo,
                                      project: ProjectInfo?,
                                      sessions: [ClaudeSessionInfo]) -> SwitcherRow {
        let name = project?.displayName ?? window.rootName ?? window.title
        let color = project?.colorHex ?? WorkspaceIndex.fallbackColor(for: name)
        let active = Self.activeSession(for: window, among: sessions)
        let aggregate = Self.aggregate(sessions)

        return SwitcherRow(id: "window:\(window.id)",
                           kind: .window,
                           displayName: name,
                           colorHex: color,
                           project: project,
                           window: window,
                           sessions: sessions,
                           state: aggregate.state,
                           stateCount: aggregate.stateCount,
                           activeSubagents: aggregate.activeSubagents,
                           subagentDescriptions: aggregate.subagentDescriptions,
                           chatTopic: active?.topic ?? window.chatTopicPrefix,
                           model: active?.model,
                           contextUsedTokens: active?.contextUsedTokens,
                           contextLimitTokens: active?.contextLimitTokens,
                           lastActivity: active?.lastActivity ?? sessions.first?.lastActivity)
    }

    /// A project with no window of its own. It still carries whatever sessions
    /// run in it, so the panel shows agent state with or without Accessibility.
    private static func makeProjectRow(project: ProjectInfo, sessions: [ClaudeSessionInfo]) -> SwitcherRow {
        // `sessions` keeps the pool's order, which is most recently active first.
        let active = sessions.first
        let aggregate = Self.aggregate(sessions)

        return SwitcherRow(id: "project:\(project.path)",
                           kind: .project,
                           displayName: project.displayName,
                           colorHex: project.colorHex,
                           project: project,
                           window: nil,
                           sessions: sessions,
                           state: aggregate.state,
                           stateCount: aggregate.stateCount,
                           activeSubagents: aggregate.activeSubagents,
                           subagentDescriptions: aggregate.subagentDescriptions,
                           chatTopic: active?.topic,
                           model: active?.model,
                           contextUsedTokens: active?.contextUsedTokens,
                           contextLimitTokens: active?.contextLimitTokens,
                           lastActivity: active?.lastActivity ?? project.mtime)
    }

    /// What a row shows for a group of sessions: the highest state, how many
    /// sessions are in it, and the running subagents underneath.
    static func aggregate(_ sessions: [ClaudeSessionInfo])
        -> (state: AgentState?, stateCount: Int, activeSubagents: Int, subagentDescriptions: [String]) {
        let state = sessions.map(\.state).max()
        return (state: state,
                stateCount: state.map { value in sessions.filter { $0.state == value }.count } ?? 0,
                activeSubagents: sessions.reduce(0) { $0 + $1.activeSubagents },
                subagentDescriptions: sessions.flatMap { $0.subagents.filter(\.isActive).compactMap(\.description) })
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
