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
    /// Last answer from the usage gateway, filled in by `UsageStore`. Read, never
    /// polled: `build()` runs once or twice a second and stays disk-bound.
    private let usage: UsageCache
    /// Test seam: replaces the disk-bound assembly, so the coalescing around it
    /// can be exercised with a build of a known duration.
    private let buildOverride: (@Sendable () -> SwitcherSnapshot)?
    /// The one place the previous CPU sweep lives. `assemble` is pure, so the
    /// state a rate needs has to be held here, beside it (SPEC §2.8).
    private let processes = ProcessSampler()

    private let snapshotLock = NSLock()
    private var lastSnapshot: SwitcherSnapshot?
    /// When `lastSnapshot` became available, as opposed to when its sources were
    /// read. Callers are coalesced against this.
    private var lastSnapshotFinishedAt: Date = .distantPast

    init(config: Config, usage: UsageCache = UsageCache()) {
        self.config = config
        self.usage = usage
        self.buildOverride = nil
    }

    init(config: Config, build: @escaping @Sendable () -> SwitcherSnapshot) {
        self.config = config
        self.usage = UsageCache()
        self.buildOverride = build
    }

    /// Builds a complete snapshot. Blocking and disk-bound: call it off the main
    /// thread. Concurrent calls are serialised, and a caller that waited out a
    /// build already in flight gets its result rather than doubling the I/O.
    ///
    /// The cache is served only to callers that arrived before the build
    /// finished, not by age: a rebuild requested by a watcher event that landed
    /// mid-build must get a fresh snapshot.
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
        // Only the newest stamp is read here: it is the sort key for `ranked`.
        // The windowed session count is `--dump`'s (`ClaudeSessions.activity`).
        let activity = Dictionary(projects.map {
            ($0.path, ProjectActivity(lastSession: ClaudeSessions.sessionTimes(forPath: $0.path).max()))
        }, uniquingKeysWith: { first, _ in first })
        // Read once: two reads of the lock-guarded value can straddle a poll and
        // hand `assemble` a directory table from one pass and a contested list
        // from the next, which is one session counted twice or not at all.
        let usageSnapshot = usage.snapshot
        // A local, so the process sweep is classified against exactly the pids
        // the rows are built from.
        let sessions = ClaudeSessions.liveSessions(config: config)
        // ~1 ms per sweep, ~6 ms on the first pass, which reads every process
        // environment (§6). No disk, no waiting.
        let load = processes.sample(sessionPIDs: Set(sessions.map(\.pid)))
        return Self.assemble(projects: projects,
                             windows: VSCodeWindows.listWindows(bundleID: config.editorBundleID),
                             sessions: sessions,
                             activity: activity,
                             // Filled by `UsageStore`'s own poll; nothing
                             // here waits for the network.
                             tokensBySlug: usageSnapshot.tokensBySlug,
                             contested: usageSnapshot.contested,
                             // The same two over the sliding hour, from the
                             // same read.
                             hourlyTokensBySlug: usageSnapshot.hourlyTokensBySlug,
                             hourlyContested: usageSnapshot.hourlyContested,
                             worktrees: Self.worktrees(of: projects),
                             cpuBySessionPID: load.cpuPercentBySessionPID,
                             orphansBySessionPID: load.orphansBySessionPID,
                             accessibilityTrusted: VSCodeWindows.isAccessibilityTrusted(),
                             generatedAt: readAt)
    }

    private static let worktreeListings = FileDerivedCache<[String]>()

    /// The worktree directories of each project: `<project>/.claude/worktrees/*`.
    ///
    /// Read here because `assemble` is pure. A slug cannot be decoded, so a
    /// worktree's slug is attributed to its project only by computing it from a
    /// directory that exists; slug prefixes would misattribute siblings
    /// (`portainer` vs `portainer-agent`). Spend of sessions started in a deleted
    /// worktree lands on no row (still visible under `start dirs:` in `--dump`).
    ///
    /// One `stat(2)` per project guards the listing, because `FileDerivedCache`
    /// never caches a missing path; the listing is cached against its mtime.
    static func worktrees(of projects: [ProjectInfo]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for project in projects {
            let directory = project.path + "/.claude/worktrees"
            guard fileStamp(atPath: directory) != nil else { continue }
            let names = worktreeListings.value(atPath: directory) {
                (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            }
            guard !names.isEmpty else { continue }
            // Not filtered to directories: that would be one `stat(2)` per entry
            // for a `.DS_Store` whose slug matches nothing anyway.
            result[project.path] = names.map { directory + "/" + $0 }
        }
        return result
    }

    /// The join itself, with the three sources already read. Pure, so the row
    /// assembly can be exercised without a disk or an Accessibility grant.
    static func assemble(projects: [ProjectInfo],
                         windows: [VSCodeWindowInfo],
                         sessions: [ClaudeSessionInfo],
                         activity: [String: ProjectActivity] = [:],
                         tokensBySlug: [String: TokenCounts] = [:],
                         contested: [ContestedSpend] = [],
                         hourlyTokensBySlug: [String: TokenCounts] = [:],
                         hourlyContested: [ContestedSpend] = [],
                         worktrees: [String: [String]] = [:],
                         cpuBySessionPID: [Int32: Double] = [:],
                         orphansBySessionPID: [Int32: Int] = [:],
                         accessibilityTrusted: Bool,
                         generatedAt: Date = Date()) -> SwitcherSnapshot {
        let projectsByRootName = Dictionary(grouping: projects, by: \.rootName)
        // Built once for both loops below: each of them asks about every
        // directory it has against every project there is.
        let projectPrefixes = Self.prefixes(of: projects)

        // Spend is keyed by the slug of the directory each session was started
        // in, matched forwards from projects and worktrees, never decoded
        // (`ClaudeSessions.slug(forPath:)` is not injective). A row's number
        // means "started in", not "spent in" (`UsageIndex`).
        let projectPathsBySlug = Self.projectPathsBySlug(projects: projects, worktrees: worktrees)
        let liveSlugsBySessionId = Self.liveSlugsBySessionId(of: sessions)
        // The same maps and function for both windows, so attribution has one
        // policy per snapshot (§2.9).
        let week = Self.spread(tokensBySlug: tokensBySlug,
                               contested: contested,
                               projectPathsBySlug: projectPathsBySlug,
                               liveSlugsBySessionId: liveSlugsBySessionId)
        let hour = Self.spread(tokensBySlug: hourlyTokensBySlug,
                               contested: hourlyContested,
                               projectPathsBySlug: projectPathsBySlug,
                               liveSlugsBySessionId: liveSlugsBySessionId)
        let usageByProjectPath = week.byProjectPath
        let usageBySlugOutsideProjects = week.bySlugOutsideProjects
        let hourlyUsageByProjectPath = hour.byProjectPath
        let hourlyUsageBySlugOutsideProjects = hour.bySlugOutsideProjects

        var sessionsByProjectPath: [String: [ClaudeSessionInfo]] = [:]
        for session in sessions {
            guard let project = Self.project(for: session.cwd,
                                             in: projects,
                                             prefixes: projectPrefixes)
            else { continue }
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

        // Each window row carries the whole spend of its project, so two windows
        // on one project show the same number. This is intentional: the gateway
        // accounts by session, and sessions reach windows only through the
        // `distribute` heuristic (SPEC §8), so a per-window share would be a guess.
        var openWindows: [SwitcherRow] = []
        var openProjectPaths = Set<String>()
        for window in windows {
            let key = keyForWindow[window.id]
            let project = key.flatMap { key in projects.first { $0.path == key } }
            if let project { openProjectPaths.insert(project.path) }
            openWindows.append(Self.makeWindowRow(window: window,
                                                  project: project,
                                                  sessions: sessionsByWindow[window.id] ?? [],
                                                  usage: project.flatMap { usageByProjectPath[$0.path] },
                                                  hourlyUsage: project.flatMap { hourlyUsageByProjectPath[$0.path] },
                                                  cpu: cpuBySessionPID,
                                                  orphans: orphansBySessionPID))
        }

        // A project with no window of its own keeps its sessions; without
        // Accessibility permission the window list is empty.
        var projectRows: [SwitcherRow] = []
        for project in projects where !openProjectPaths.contains(project.path) {
            let pool = (sessionsByProjectPath[project.path] ?? [])
                .filter { !claimedSessionIDs.contains($0.sessionId) }
            for session in pool { claimedSessionIDs.insert(session.sessionId) }
            projectRows.append(Self.makeProjectRow(project: project,
                                                   sessions: pool,
                                                   usage: usageByProjectPath[project.path],
                                                   hourlyUsage: hourlyUsageByProjectPath[project.path],
                                                   cpu: cpuBySessionPID,
                                                   orphans: orphansBySessionPID))
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
            let aggregate = Self.aggregate(group, cpu: cpuBySessionPID, orphans: orphansBySessionPID)
            let slug = ClaudeSessions.slug(forPath: cwd)
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
                                          lastActivity: group.compactMap(\.lastActivity).max(),
                                          // Exact match on the row's own
                                          // directory slug.
                                          usage: usageBySlugOutsideProjects[slug],
                                          cpuPercent: aggregate.cpuPercent,
                                          cpuIsLowerBound: aggregate.cpuIsLowerBound,
                                          orphanCount: aggregate.orphanCount,
                                          // The hour's figure by the same key
                                          // (§2.2.1).
                                          hourlyUsage: hourlyUsageBySlugOutsideProjects[slug]))
        }

        return SwitcherSnapshot(openWindows: Self.rankedWindows(openWindows),
                                projects: Self.rankedOrphans(orphanRows)
                                    + Self.ranked(projectRows, activity: activity),
                                accessibilityTrusted: accessibilityTrusted,
                                generatedAt: generatedAt,
                                ambiguousUsage: week.ambiguous,
                                ambiguousUsageSessions: week.ambiguousSessions,
                                ambiguousHourlyUsage: hour.ambiguous,
                                ambiguousHourlySessions: hour.ambiguousSessions)
    }

    /// One window's spend, spread over the projects: the slug table folded onto
    /// project paths, whatever it could not place kept under its own slug, and the
    /// contested sessions settled against the same map.
    ///
    /// Called once per window (week and hour) so both use one attribution policy
    /// (SPEC §2.9). Both maps are passed in so the two calls share them; only the
    /// inputs differ, each contested list already narrowed to its window
    /// (`UsageIndex.narrowToWindow`).
    private static func spread(tokensBySlug: [String: TokenCounts],
                               contested: [ContestedSpend],
                               projectPathsBySlug: [String: String],
                               liveSlugsBySessionId: [String: String])
        -> (byProjectPath: [String: TokenCounts],
            bySlugOutsideProjects: [String: TokenCounts],
            ambiguous: TokenCounts,
            ambiguousSessions: Int) {
        var byProjectPath: [String: TokenCounts] = [:]
        var bySlugOutsideProjects: [String: TokenCounts] = [:]
        for (slug, tokens) in tokensBySlug {
            guard let path = projectPathsBySlug[slug] else {
                bySlugOutsideProjects[slug] = tokens
                continue
            }
            byProjectPath[path] = (byProjectPath[path] ?? .zero) + tokens
        }

        // The sessions filed under more than one slug, already narrowed to this
        // window, so a list of slugs may be down to one or to none. Settled here
        // and nowhere earlier, because settling them needs the project list and
        // the live sessions.
        let settled = Self.settle(contested: contested,
                                  projectPathsBySlug: projectPathsBySlug,
                                  liveSlugsBySessionId: liveSlugsBySessionId)
        for (path, tokens) in settled.tokensByProjectPath {
            byProjectPath[path] = (byProjectPath[path] ?? .zero) + tokens
        }
        return (byProjectPath, bySlugOutsideProjects, settled.ambiguous, settled.ambiguousSessions)
    }

    /// `slug → project path`, for every project and every worktree of one.
    ///
    /// The only direction the slug can be travelled in. Worktrees are entered
    /// first and the projects' own directories second, so that a project always
    /// wins its own slug: two projects can slug alike (the replacement is not
    /// injective — `a_b` and `a.b` both give `a-b`), and a project's own
    /// directory is a better claim on its slug than somebody's worktree.
    static func projectPathsBySlug(projects: [ProjectInfo],
                                   worktrees: [String: [String]]) -> [String: String] {
        var index: [String: String] = [:]
        for project in projects {
            for worktree in worktrees[project.path] ?? [] {
                index[ClaudeSessions.slug(forPath: worktree)] = project.path
            }
        }
        for project in projects {
            index[ClaudeSessions.slug(forPath: project.path)] = project.path
        }
        return index
    }

    /// `session id → the slug of the directory the running session started in`,
    /// for the sessions that are running right now.
    ///
    /// `~/.claude/sessions/<pid>.json` is where Claude Code writes that directory,
    /// and it is the *first* of the three things called `cwd` (§2.7): the start
    /// directory of the process, which is the one the transcript is filed under —
    /// not the directory of the moment, which walks about while the session runs.
    /// The app already trusts this file completely; a row exists on the panel
    /// because of it.
    ///
    /// One answer per session id is guaranteed upstream: `liveSessions` yields
    /// at most one row per id (`testOneSessionIdYieldsOneLiveRow`).
    ///
    /// Only VSCode-started sessions are here, so a terminal session's contest
    /// goes unvetoed. That is safe for a veto, which only refuses, but it is no
    /// backstop (`UsageIndex.narrowToWindow`).
    static func liveSlugsBySessionId(of sessions: [ClaudeSessionInfo]) -> [String: String] {
        var starts: [String: String] = [:]
        for session in sessions where starts[session.sessionId] == nil {
            starts[session.sessionId] = ClaudeSessions.slug(forPath: session.cwd)
        }
        return starts
    }

    /// Attributes the sessions filed under more than one slug, or admits that
    /// nothing here knows. `entry.slugs` is already narrowed to the lives written
    /// to inside this window, so it may hold one slug or none.
    ///
    /// A resumed session in another directory keeps its `session_id` and copies
    /// the old history under the new slug, so the copies are one session. Slugs
    /// that map to one project (a project and its worktree) are attributed to it.
    /// Two projects, no project, or a project plus an unrecognised slug go to
    /// `ambiguous`: counted, reported by `--dump`, put on no row. mtime and size
    /// do not tell the copies apart, and comparing records would mean reading
    /// whole transcripts, which the transcript layer never does.
    ///
    /// `liveSlugsBySessionId` (from `~/.claude/sessions/<pid>.json`) is a veto, not
    /// a chooser: if it names a slug outside `entry.slugs`, the entry is ambiguous.
    /// It runs before `claimants`, so it can also refuse a project/worktree pair;
    /// that costs a number, never a wrong row.
    ///
    /// Pure and separate from `assemble` so the rule can be tested directly. No
    /// default for `liveSlugsBySessionId`, like `spread`: both windows must be
    /// settled under the same policy.
    static func settle(contested: [ContestedSpend],
                       projectPathsBySlug: [String: String],
                       liveSlugsBySessionId: [String: String])
        -> (tokensByProjectPath: [String: TokenCounts], ambiguous: TokenCounts, ambiguousSessions: Int) {
        var tokensByProjectPath: [String: TokenCounts] = [:]
        var ambiguous = TokenCounts.zero
        var ambiguousSessions = 0

        for entry in contested {
            // A running session says where its current life started. If that is not
            // among the lives that could have spent in this window, the live record
            // and the transcripts describe two different situations, and nothing
            // here may pick between them.
            if let live = liveSlugsBySessionId[entry.sessionId], !entry.slugs.contains(live) {
                ambiguous = ambiguous + entry.tokens
                ambiguousSessions += 1
                continue
            }
            let claimants = Set(entry.slugs.map { projectPathsBySlug[$0] })
            // One real claimant: `[nil]` means no slug matched a project, and an
            // empty set means no copy was written to in this window.
            guard claimants.count == 1, let path = claimants.first ?? nil else {
                ambiguous = ambiguous + entry.tokens
                ambiguousSessions += 1
                continue
            }
            tokensByProjectPath[path] = (tokensByProjectPath[path] ?? .zero) + entry.tokens
        }
        return (tokensByProjectPath, ambiguous, ambiguousSessions)
    }

    private static func makeWindowRow(window: VSCodeWindowInfo,
                                      project: ProjectInfo?,
                                      sessions: [ClaudeSessionInfo],
                                      usage: TokenCounts?,
                                      hourlyUsage: TokenCounts?,
                                      cpu: [Int32: Double],
                                      orphans: [Int32: Int]) -> SwitcherRow {
        let name = project?.displayName ?? window.rootName ?? window.title
        let color = project?.colorHex ?? WorkspaceIndex.fallbackColor(for: name)
        let active = Self.activeSession(for: window, among: sessions)
        let aggregate = Self.aggregate(sessions, cpu: cpu, orphans: orphans)

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
                           lastActivity: active?.lastActivity ?? sessions.first?.lastActivity,
                           usage: usage,
                           cpuPercent: aggregate.cpuPercent,
                           cpuIsLowerBound: aggregate.cpuIsLowerBound,
                           orphanCount: aggregate.orphanCount,
                           hourlyUsage: hourlyUsage)
    }

    /// A project with no window of its own. It still carries whatever sessions
    /// run in it, so the panel shows agent state with or without Accessibility.
    private static func makeProjectRow(project: ProjectInfo,
                                       sessions: [ClaudeSessionInfo],
                                       usage: TokenCounts?,
                                       hourlyUsage: TokenCounts?,
                                       cpu: [Int32: Double],
                                       orphans: [Int32: Int]) -> SwitcherRow {
        // `sessions` keeps the pool's order, which is most recently active first.
        let active = sessions.first
        let aggregate = Self.aggregate(sessions, cpu: cpu, orphans: orphans)

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
                           lastActivity: active?.lastActivity ?? project.mtime,
                           usage: usage,
                           cpuPercent: aggregate.cpuPercent,
                           cpuIsLowerBound: aggregate.cpuIsLowerBound,
                           orphanCount: aggregate.orphanCount,
                           hourlyUsage: hourlyUsage)
    }

    /// What a row shows for a group of sessions: the highest state, the running
    /// subagents, and what their processes are doing.
    ///
    /// The process tables are keyed by session pid, the only key the sweep has
    /// (SPEC §2.8). CPU is `nil` unless at least one session was measured; a sum
    /// over only some of them is kept and flagged with `cpuIsLowerBound`, like
    /// `usageIsLowerBound`. No defaults on the tables, so a row constructor that
    /// forgets them fails to compile.
    static func aggregate(_ sessions: [ClaudeSessionInfo],
                          cpu: [Int32: Double],
                          orphans: [Int32: Int])
        -> (state: AgentState?, activeSubagents: Int, subagentDescriptions: [String],
            cpuPercent: Double?, cpuIsLowerBound: Bool, orphanCount: Int) {
        let measured = sessions.compactMap { cpu[$0.pid] }
        return (state: sessions.map(\.state).max(),
                activeSubagents: sessions.reduce(0) { $0 + $1.activeSubagents },
                subagentDescriptions: sessions.flatMap { $0.subagents.filter(\.isActive).compactMap(\.description) },
                cpuPercent: measured.isEmpty ? nil : measured.reduce(0, +),
                cpuIsLowerBound: !measured.isEmpty && measured.count < sessions.count,
                orphanCount: sessions.reduce(0) { $0 + (orphans[$1.pid] ?? 0) })
    }

    // MARK: - Ranking

    /// Orders the open windows by the newest `lastActivity` among their chats,
    /// newest first, rather than by Accessibility z-order (what was clicked last).
    /// That stamp includes the hook state file, so a window whose chat is blocked
    /// on a question still rises. The row's own `lastActivity` is only the shown
    /// chat's. Rows with no chat go last in arrival order, including sibling
    /// windows `distribute` gave no session to.
    static func rankedWindows(_ rows: [SwitcherRow]) -> [SwitcherRow] {
        // Ties fall back to the arrival index: `sorted` is not stable, and rows
        // must not swap places between snapshots.
        rows.enumerated().sorted { left, right in
            let leftActivity = left.element.sessions.compactMap(\.lastActivity).max()
            let rightActivity = right.element.sessions.compactMap(\.lastActivity).max()
            switch (leftActivity, rightActivity) {
            case let (leftDate?, rightDate?) where leftDate != rightDate: return leftDate > rightDate
            case (.some, nil): return true
            case (nil, .some): return false
            default: return left.offset < right.offset
            }
        }.map(\.element)
    }

    /// Orders the orphan `cwd:` rows, which go ahead of every project row: they
    /// exist only because an agent is running there.
    ///
    /// Most urgent state first (question, permission, waiting, working, idle),
    /// then most recent activity, then the path, which is unique.
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

    /// Orders the projects that have no window by the mtime of their newest
    /// session transcript, newest first: where work last happened, not how much
    /// (`recentSessions` is not used here) nor the directory mtime, which does not
    /// move when files inside change. Projects with no session go last in the
    /// order the index handed over, kept via the arrival index because `sorted`
    /// is not stable.
    static func ranked(_ rows: [SwitcherRow], activity: [String: ProjectActivity]) -> [SwitcherRow] {
        rows.enumerated().sorted { ranksAbove($0, $1, activity: activity) }.map(\.element)
    }

    /// The comparison `ranked` sorts by, exposed so the arrival-index tie-break
    /// can be tested directly: the current `sorted` happens to keep equal
    /// elements in place, so tests through it would not catch its removal.
    static func ranksAbove(_ left: (offset: Int, element: SwitcherRow),
                           _ right: (offset: Int, element: SwitcherRow),
                           activity: [String: ProjectActivity]) -> Bool {
        let leftLast = left.element.project.flatMap { activity[$0.path] }?.lastSession
        let rightLast = right.element.project.flatMap { activity[$0.path] }?.lastSession
        switch (leftLast, rightLast) {
        case let (leftDate?, rightDate?) where leftDate != rightDate: return leftDate > rightDate
        case (.some, nil): return true
        case (nil, .some): return false
        default: return left.offset < right.offset
        }
    }

    // MARK: - Matching

    /// The containment prefix of every project (its path plus `/`), built once,
    /// in the order the projects came in.
    ///
    /// The separator matters: without it `asakusa_lab` would contain
    /// `asakusa_lab_glaze_resolver`. `ProjectMatchingTests` covers it.
    ///
    /// Hoisted out of `project(for:in:prefixes:)` so `assemble` does not build a
    /// string per (directory, project) pair. A plain `[String]` parallel to
    /// `projects`, not an array of `(project, prefix)` pairs: copying the
    /// `ProjectInfo` struct out of each pair costs several times the walk.
    static func prefixes(of projects: [ProjectInfo]) -> [String] {
        projects.map { $0.path + "/" }
    }

    /// The project a working directory belongs to: an exact match, otherwise the
    /// deepest project the path sits inside.
    ///
    /// `prefixes` is `prefixes(of:)` over the same list, by position, passed in
    /// so the caller decides how often it is built.
    ///
    /// One walk: an exact match returns at once, the deepest prefix is a running
    /// maximum. The answer must not depend on project order;
    /// `ProjectMatchingTests` asks both orders.
    static func project(for cwd: String,
                        in projects: [ProjectInfo],
                        prefixes: [String]) -> ProjectInfo? {
        // The walk indexes `projects` by `prefixes.indices`, so a length mismatch
        // would crash or match against the wrong projects.
        precondition(prefixes.count == projects.count,
                     "prefixes must be prefixes(of:) the very projects being searched")
        var deepestIndex = -1
        var deepestLength = 0
        for index in prefixes.indices {
            if projects[index].path == cwd { return projects[index] }
            guard cwd.hasPrefix(prefixes[index]) else { continue }
            // First maximum wins; two projects cannot share a path anyway.
            let length = prefixes[index].count
            if length > deepestLength {
                deepestIndex = index
                deepestLength = length
            }
        }
        return deepestIndex >= 0 ? projects[deepestIndex] : nil
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
