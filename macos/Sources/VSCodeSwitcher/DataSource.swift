import Foundation

/// Joins the three independent sources — open windows, the project index and
/// live Claude sessions — into the rows the panel shows.
///
/// Threading: `snapshot()` is safe to call from any queue and is meant to be
/// called off the main one — `Task.detached { let snapshot = dataSource.snapshot() }`
/// — with the result applied on the main thread. It blocks on disk for 0.1 s or
/// more, so calling it on the main thread freezes the UI for that long.
///
/// `@unchecked Sendable`: `config` and `index` are a `let` value type and an
/// object with its own lock; `lastSnapshot` is mutable and is read and written
/// only while `snapshotLock` is held.
final class DataSource: @unchecked Sendable {
    private let config: Config
    private let index = WorkspaceIndex()
    /// Test seam: replaces the disk-bound assembly, so the coalescing around it
    /// can be exercised with a build of a known duration.
    private let buildOverride: (@Sendable () -> SwitcherSnapshot)?

    private let snapshotLock = NSLock()
    private var lastSnapshot: SwitcherSnapshot?
    /// When `lastSnapshot` became available, as opposed to when its sources were
    /// read. Callers are coalesced against this.
    private var lastSnapshotFinishedAt: Date = .distantPast

    init(config: Config) {
        self.config = config
        self.buildOverride = nil
    }

    init(config: Config, build: @escaping @Sendable () -> SwitcherSnapshot) {
        self.config = config
        self.buildOverride = build
    }

    /// Builds a complete snapshot. Blocking and disk-bound: call it off the main
    /// thread. Concurrent calls are serialised, and a caller that waited out a
    /// build already in flight gets its result rather than doubling the I/O.
    ///
    /// The comparison is against the moment this call was made, not the age of
    /// the cached snapshot. A fixed window after a build finished also served
    /// the cache to callers that arrived *after* it — including the rebuild
    /// `SnapshotStore` fires when a watcher event landed mid-build, which then
    /// got back the very snapshot that had asked it to retry. The hook state
    /// change reached the panel only on the next timer tick, which made the
    /// file system watcher pointless.
    func snapshot() -> SwitcherSnapshot {
        snapshot(requestedAt: Date())
    }

    /// The rule itself, with the caller's arrival time passed in. Test seam:
    /// pinning that instant is what makes "queued up behind a build" and
    /// "arrived after it" two exact cases instead of two races against the
    /// scheduler and the clock.
    func snapshot(requestedAt: Date) -> SwitcherSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }

        if let lastSnapshot, lastSnapshotFinishedAt >= requestedAt { return lastSnapshot }
        let fresh = build()
        lastSnapshot = fresh
        lastSnapshotFinishedAt = Date()
        return fresh
    }

    private func build() -> SwitcherSnapshot {
        if let buildOverride { return buildOverride() }
        // Stamped before the sources are read, not after: the assembly takes
        // 40–180 ms, and a snapshot that claims to be from the moment it
        // finished is younger than its own data.
        let readAt = Date()
        let projects = index.projects(config: config)
        let activity = Dictionary(projects.map {
            ($0.path, ClaudeSessions.activity(forPath: $0.path,
                                              windowDays: config.activityWindowDays,
                                              now: readAt))
        }, uniquingKeysWith: { first, _ in first })
        return Self.assemble(projects: projects,
                             windows: VSCodeWindows.listWindows(bundleID: config.editorBundleID),
                             sessions: ClaudeSessions.liveSessions(config: config),
                             activity: activity,
                             accessibilityTrusted: VSCodeWindows.isAccessibilityTrusted(),
                             generatedAt: readAt)
    }

    /// The join itself, with the three sources already read. Pure, so the row
    /// assembly can be exercised without a disk or an Accessibility grant.
    static func assemble(projects: [ProjectInfo],
                         windows: [VSCodeWindowInfo],
                         sessions: [ClaudeSessionInfo],
                         activity: [String: ProjectActivity] = [:],
                         accessibilityTrusted: Bool,
                         generatedAt: Date = Date()) -> SwitcherSnapshot {
        let projectsByRootName = Dictionary(grouping: projects, by: \.rootName)
        var sessionsByProjectPath: [String: [ClaudeSessionInfo]] = [:]
        for session in sessions {
            guard let project = Self.project(for: session.cwd, in: projects) else { continue }
            sessionsByProjectPath[project.path, default: []].append(session)
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

        // Every session that ended up on a row. What is left over at the end is
        // the definition of an orphan, which makes the assembly total: a
        // running agent can never be silently dropped from the list.
        var claimedSessionIDs = Set<String>()
        for assigned in sessionsByWindow.values {
            for session in assigned { claimedSessionIDs.insert(session.sessionId) }
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

        // A project with no window of its own keeps its sessions. This is the
        // normal case, not an edge one: without Accessibility permission the
        // window list is empty, and reading the session pool only through the
        // windows made every running agent disappear from a panel that had
        // already read all of it.
        var projectRows: [SwitcherRow] = []
        for project in projects where !openProjectPaths.contains(project.path) {
            let pool = (sessionsByProjectPath[project.path] ?? [])
                .filter { !claimedSessionIDs.contains($0.sessionId) }
            for session in pool { claimedSessionIDs.insert(session.sessionId) }
            projectRows.append(Self.makeProjectRow(project: project, sessions: pool))
        }

        // Sessions whose cwd is outside every scan root belong to no project and
        // therefore to no window. They are grouped by working directory and
        // aggregated exactly like the sessions that did land in a project:
        // six agents in one directory are one place to look, not six identical
        // rows. Built in path order; `rankedOrphans` decides the order shown.
        let orphansByCwd = Dictionary(grouping: sessions.filter { !claimedSessionIDs.contains($0.sessionId) },
                                      by: \.cwd)
        var orphanRows: [SwitcherRow] = []
        for cwd in orphansByCwd.keys.sorted() {
            let group = orphansByCwd[cwd] ?? []
            let name = (cwd as NSString).lastPathComponent
            let active = group.first
            let aggregate = Self.aggregate(group)
            orphanRows.append(SwitcherRow(id: "cwd:\(cwd)",
                                          kind: .project,
                                          displayName: name,
                                          colorHex: WorkspaceIndex.fallbackColor(for: name),
                                          project: nil,
                                          window: nil,
                                          sessions: group,
                                          state: aggregate.state,
                                          activeSubagents: aggregate.activeSubagents,
                                          subagentDescriptions: aggregate.subagentDescriptions,
                                          chatTopic: active?.topic,
                                          model: active?.model,
                                          contextUsedTokens: active?.contextUsedTokens,
                                          contextLimitTokens: active?.contextLimitTokens,
                                          lastActivity: group.compactMap(\.lastActivity).max()))
        }

        return SwitcherSnapshot(openWindows: openWindows,
                                projects: Self.rankedOrphans(orphanRows)
                                    + Self.ranked(projectRows, activity: activity),
                                accessibilityTrusted: accessibilityTrusted,
                                generatedAt: generatedAt)
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
                           activeSubagents: aggregate.activeSubagents,
                           subagentDescriptions: aggregate.subagentDescriptions,
                           chatTopic: active?.topic,
                           model: active?.model,
                           contextUsedTokens: active?.contextUsedTokens,
                           contextLimitTokens: active?.contextLimitTokens,
                           lastActivity: active?.lastActivity ?? project.mtime)
    }

    /// What a row shows for a group of sessions: the highest state among them
    /// and the subagents running underneath.
    ///
    /// The row folds this into one indicator (`SwitcherRow.status`); the
    /// per-chat detail it does not draw is read straight off `sessions`, by the
    /// tooltip and by `--dump`.
    static func aggregate(_ sessions: [ClaudeSessionInfo])
        -> (state: AgentState?, activeSubagents: Int, subagentDescriptions: [String]) {
        (state: sessions.map(\.state).max(),
         activeSubagents: sessions.reduce(0) { $0 + $1.activeSubagents },
         subagentDescriptions: sessions.flatMap { $0.subagents.filter(\.isActive).compactMap(\.description) })
    }

    // MARK: - Ranking

    /// Orders the orphan `cwd:` rows, which are put ahead of every project row.
    ///
    /// An orphan row exists only because an agent is running in that directory:
    /// take the sessions away and the row is gone, which is not true of a
    /// project row. So the rows that are made of live agents come first, and the
    /// two orderings — agent state here, sessions-per-month there — never have
    /// to be compared against each other.
    ///
    /// They used to be appended at the very end. The thirty-row cap hid
    /// everything below it and so dragged them up to roughly position 31 by
    /// accident; once the cap went, a live agent in a scratch directory landed
    /// at position 93 of 93 — four screens down, at the moment it was wanted
    /// most.
    ///
    /// Among themselves: the most urgent state first (`question` over
    /// `permission` over `waiting` over `working` over `idle`), then the most
    /// recent activity, then the path. Paths are unique, so the order is fully
    /// determined and does not depend on the sort being stable.
    static func rankedOrphans(_ rows: [SwitcherRow]) -> [SwitcherRow] {
        rows.sorted { left, right in
            // An orphan group is never empty, so `state` is never `nil` here;
            // the default only keeps the comparison a total order.
            let leftState = left.state ?? .idle
            let rightState = right.state ?? .idle
            if leftState != rightState { return leftState > rightState }
            let leftActivity = left.lastActivity ?? .distantPast
            let rightActivity = right.lastActivity ?? .distantPast
            if leftActivity != rightActivity { return leftActivity > rightActivity }
            return left.id < right.id
        }
    }

    /// Orders the projects that have no window by how much Claude Code work has
    /// happened in them lately.
    ///
    /// Directory mtime, which is what this used to be, answers almost nothing:
    /// it does not move when a file inside the project is edited, so the order
    /// looked arbitrary — a project worked in all week could sit below one last
    /// touched in spring. The number of sessions started in the last few weeks
    /// does answer it, and a hard window rather than a decayed sum is what keeps
    /// a project with a big enough past from floating at the top forever.
    ///
    /// Three groups, in this order: worked in during the window, ranked by how
    /// many sessions; worked in before it, ranked by the newest of them; never
    /// worked in at all, left in the directory-mtime order they arrived in.
    /// Rows keep that arrival order whenever the activity cannot separate them,
    /// so the sort is stable in effect even though `sorted` is not.
    static func ranked(_ rows: [SwitcherRow], activity: [String: ProjectActivity]) -> [SwitcherRow] {
        rows.enumerated().sorted { left, right in
            let leftActivity = left.element.project.flatMap { activity[$0.path] } ?? ProjectActivity()
            let rightActivity = right.element.project.flatMap { activity[$0.path] } ?? ProjectActivity()
            if leftActivity.recentSessions != rightActivity.recentSessions {
                return leftActivity.recentSessions > rightActivity.recentSessions
            }
            if leftActivity.lastSession != rightActivity.lastSession {
                return (leftActivity.lastSession ?? .distantPast) > (rightActivity.lastSession ?? .distantPast)
            }
            return left.offset < right.offset
        }.map(\.element)
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
