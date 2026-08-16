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
        // Only the stamp is read on this path: it is the sort key and `ranked`
        // looks at nothing else. The other half of `ProjectActivity` — how many
        // sessions fall inside `activityWindowDays` — belongs to `--dump`, which
        // computes it itself through `ClaudeSessions.activity`; counting it here
        // meant a pass over the transcript stamps of all 99 projects on every
        // snapshot for a number nobody on this path would read.
        //
        // Not a saving worth measuring, and measured anyway so that nobody puts
        // it back believing it was: the count over the live 408 transcripts is
        // 0.0095 ms against the 1.25 ms `stat(2)` spends over the 362 reachable
        // from the index — different passes over different populations, so the
        // pair is an order of magnitude and not a ratio (SPEC §2.2.1, §6). What
        // is wrong with it is that it is work with no reader, and
        // `config.activityWindowDays` reaching in here to parametrise it.
        let activity = Dictionary(projects.map {
            ($0.path, ProjectActivity(lastSession: ClaudeSessions.sessionTimes(forPath: $0.path).max()))
        }, uniquingKeysWith: { first, _ in first })
        // Read once: two reads of the lock-guarded value can straddle a poll and
        // hand `assemble` a directory table from one pass and a contested list
        // from the next, which is one session counted twice or not at all.
        let usageSnapshot = usage.snapshot
        return Self.assemble(projects: projects,
                             windows: VSCodeWindows.listWindows(bundleID: config.editorBundleID),
                             sessions: ClaudeSessions.liveSessions(config: config),
                             activity: activity,
                             // A plain dictionary read under a lock: the poll
                             // that fills it lives in `UsageStore`, on its own
                             // minute-long timer, and nothing on this path
                             // waits for a network.
                             tokensBySlug: usageSnapshot.tokensBySlug,
                             contested: usageSnapshot.contested,
                             worktrees: Self.worktrees(of: projects),
                             accessibilityTrusted: VSCodeWindows.isAccessibilityTrusted(),
                             generatedAt: readAt)
    }

    private static let worktreeListings = FileDerivedCache<[String]>()

    /// The worktree directories of each project: `<project>/.claude/worktrees/*`.
    ///
    /// Read here rather than inside `assemble` because `assemble` is pure and
    /// this is the disk. It exists at all because a slug cannot be decoded: the
    /// only way to know that
    /// `-Users-x-switcher--claude-worktrees-usage-ui` belongs to `switcher` is to
    /// have computed that slug from a directory that is there. Matching slug
    /// *prefixes* instead would look equivalent and is not — the separator is
    /// gone, so `-Users-x-portainer-` prefixes the slug of `portainer-agent`,
    /// which is the sibling trap `prefixes(of:)` exists to avoid, one alphabet
    /// down.
    ///
    /// The consequence to know about: a worktree that has been deleted is a slug
    /// nothing can claim, and the spend of the sessions started in it lands on no
    /// row. Four such slugs sit in `~/.claude/projects` today. Accepted — the
    /// alternative is guessing from a name — and visible, because those sessions
    /// still count under `start dirs:` in `--dump` while appearing on no row.
    ///
    /// One `stat(2)` per project, and only the projects that have the directory
    /// are listed; the listing itself is cached against its own mtime, which
    /// moves exactly when a worktree is added or removed. The guard is not
    /// optional politeness: `FileDerivedCache` never caches a path that does not
    /// exist, so without it every project would run a `contentsOfDirectory` that
    /// could only fail, once or twice a second, and building those `NSError`s is
    /// the cost §2.2.1 already caught once.
    ///
    /// Measured 2026-08-17 over the live 104 projects and their 44 worktrees,
    /// `swiftc -O -whole-module-optimization`, best of 25 passes: 0.104 ms as it
    /// stands, 0.727 ms with the guard gone and the listing re-read every pass.
    /// For scale, the `stat(2)` walk over the transcripts in the same build is
    /// 1.25 ms and the whole snapshot spends 40–180 ms on disk (SPEC §6).
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
                         worktrees: [String: [String]] = [:],
                         accessibilityTrusted: Bool,
                         generatedAt: Date = Date()) -> SwitcherSnapshot {
        let projectsByRootName = Dictionary(grouping: projects, by: \.rootName)
        // Built once for both loops below: each of them asks about every
        // directory it has against every project there is.
        let projectPrefixes = Self.prefixes(of: projects)

        // Spend arrives keyed by the slug directory Claude Code filed each
        // session under, which is the directory the session was *started* in.
        // The slug is matched forwards — the slug of each project, and of each
        // worktree of one — never decoded, because it cannot be
        // (`ClaudeSessions.slug(forPath:)` is not injective).
        //
        // "Started in" is the whole claim a row's number makes, and it is not
        // "spent in": a session moves between directories while it runs, and the
        // gateway hands back one aggregate per session with nothing to split it
        // by (`UsageIndex`).
        let projectPathsBySlug = Self.projectPathsBySlug(projects: projects, worktrees: worktrees)
        var usageByProjectPath: [String: TokenCounts] = [:]
        var usageBySlugOutsideProjects: [String: TokenCounts] = [:]
        for (slug, tokens) in tokensBySlug {
            guard let path = projectPathsBySlug[slug] else {
                usageBySlugOutsideProjects[slug] = tokens
                continue
            }
            usageByProjectPath[path] = (usageByProjectPath[path] ?? .zero) + tokens
        }

        // The sessions filed under more than one slug. Settled here and nowhere
        // earlier, because settling them needs the project list.
        let settled = Self.settle(contested: contested, projectPathsBySlug: projectPathsBySlug)
        for (path, tokens) in settled.tokensByProjectPath {
            usageByProjectPath[path] = (usageByProjectPath[path] ?? .zero) + tokens
        }

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

        // Each window row carries the whole spend of its project, which means two
        // windows on one project show the same number twice. That is the chosen
        // answer, not an oversight left to be tidied up later: the spend belongs
        // to the project, not to a window.
        //
        // Splitting it is what cannot be done honestly. The gateway accounts by
        // session and knows nothing of windows; sessions reach a window only
        // through `distribute`, which matches the chat topic against a title
        // prefix VSCode has already truncated and hands everything it could not
        // place to the frontmost window (SPEC §8). A per-window "share" would be
        // that heuristic with a figure attached — a guess printed as a
        // measurement, which is the one thing this whole layer refuses to do.
        // Both rows are labelled with the project's name, so the same number on
        // both reads as what it is.
        var openWindows: [SwitcherRow] = []
        var openProjectPaths = Set<String>()
        for window in windows {
            let key = keyForWindow[window.id]
            let project = key.flatMap { key in projects.first { $0.path == key } }
            if let project { openProjectPaths.insert(project.path) }
            openWindows.append(Self.makeWindowRow(window: window,
                                                  project: project,
                                                  sessions: sessionsByWindow[window.id] ?? [],
                                                  usage: project.flatMap { usageByProjectPath[$0.path] }))
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
            projectRows.append(Self.makeProjectRow(project: project,
                                                   sessions: pool,
                                                   usage: usageByProjectPath[project.path]))
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
                                          lastActivity: group.compactMap(\.lastActivity).max(),
                                          // The row's own directory, slugged the
                                          // same way Claude Code slugged it when
                                          // it filed the transcript. Forwards
                                          // again, and exact: an orphan row *is*
                                          // a directory, and anything below it
                                          // the gateway knows about would be a
                                          // row of its own if an agent were
                                          // running there.
                                          usage: usageBySlugOutsideProjects[ClaudeSessions.slug(forPath: cwd)]))
        }

        return SwitcherSnapshot(openWindows: Self.rankedWindows(openWindows),
                                projects: Self.rankedOrphans(orphanRows)
                                    + Self.ranked(projectRows, activity: activity),
                                accessibilityTrusted: accessibilityTrusted,
                                generatedAt: generatedAt,
                                ambiguousUsage: settled.ambiguous,
                                ambiguousUsageSessions: settled.ambiguousSessions)
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

    /// Decides what to do with the sessions filed under more than one slug:
    /// attribute them, or admit that nothing here knows.
    ///
    /// A `session_id` is not unique across `~/.claude/projects/`, and the copies
    /// under two slugs are one session rather than two. Resuming a session in
    /// another directory keeps its identifier, opens a file under the new slug
    /// and seeds it with a copy of the old history — which is why both copies
    /// begin with the same record, to the millisecond, and why the head of the
    /// new one names the *old* directory. So there is one aggregate to place and
    /// two directories with a claim on it, and only the project list can say
    /// whether that is a disagreement at all: `<project>` and
    /// `<project>/.claude/worktrees/<name>` are two slugs and one project, which
    /// is an answer.
    ///
    /// Two projects is not an answer, and nothing here tries to make one. The
    /// tempting tie-breaks are the file's mtime and its size, and both are
    /// coin-flips with a straight face: the live pair `83804075` has its two
    /// copies written one minute apart, and the bigger copy of `65f9afa1` is the
    /// one whose records mostly name the *other* project's directory. Comparing
    /// the records themselves would mean reading transcripts whole — up to
    /// 40 MB on this machine (measured 2026-08-17), which is the one thing the
    /// transcript layer must never do.
    /// So such spend goes to `ambiguous`: counted, reported by `--dump`, and put
    /// on no row.
    ///
    /// Also `ambiguous` when the slugs claim *no* project between them — two
    /// directories outside every scan root are two different orphan rows, and
    /// the spend belongs to neither more than the other — and when one slug is a
    /// project and the other is not, which is the same "one aggregate, two
    /// lives" with one of the lives simply unrecognised.
    ///
    /// Pure, and separate from `assemble`, so the rule can be asked directly:
    /// through the assembly a wrong answer surfaces as a number missing from a
    /// row, which is also what a dozen unrelated mistakes look like.
    static func settle(contested: [ContestedSpend],
                       projectPathsBySlug: [String: String])
        -> (tokensByProjectPath: [String: TokenCounts], ambiguous: TokenCounts, ambiguousSessions: Int) {
        var tokensByProjectPath: [String: TokenCounts] = [:]
        var ambiguous = TokenCounts.zero
        var ambiguousSessions = 0

        for entry in contested {
            let claimants = Set(entry.slugs.map { projectPathsBySlug[$0] })
            // One claimant, and a real one: `[nil]` is "no slug matched
            // anything", which is agreement about nothing.
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
                                      usage: TokenCounts?) -> SwitcherRow {
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
                           lastActivity: active?.lastActivity ?? sessions.first?.lastActivity,
                           usage: usage)
    }

    /// A project with no window of its own. It still carries whatever sessions
    /// run in it, so the panel shows agent state with or without Accessibility.
    private static func makeProjectRow(project: ProjectInfo,
                                       sessions: [ClaudeSessionInfo],
                                       usage: TokenCounts?) -> SwitcherRow {
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
                           lastActivity: active?.lastActivity ?? project.mtime,
                           usage: usage)
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

    /// Orders the open windows by the last message written in them, newest
    /// first.
    ///
    /// The z-order the Accessibility API reports is the stack of what was
    /// clicked, not of what is happening: a window untouched since morning sits
    /// on top merely because it was focused last. The panel is opened to find
    /// the window something is going on in, so the key is the newest
    /// `ClaudeSessionInfo.lastActivity` among the row's chats — and that is not
    /// the transcript mtime alone but the newest of the three stamps a session
    /// has (`ClaudeSessions.load`): the hook state file, the metrics file and
    /// the transcript. The hook writes first and by seconds, which is the point:
    /// a chat that has just been asked a question freezes its transcript while
    /// the hook records the block, and the window it sits in has to rise anyway.
    ///
    /// The row's own `lastActivity` is not that key: it belongs to the *shown*
    /// chat, and a window whose visible chat is idle can hold another that
    /// answered a second ago.
    ///
    /// A row with no chat has no activity at all and goes to the end in the
    /// z-order it arrived in. Two consequences worth naming. A window opened by
    /// hand, with no agent in it, sinks below every window that has one — that
    /// is the rule working. And a *second* window of a busy project can sink
    /// there too: `distribute` hands a session to the window whose title prefix
    /// matches its topic and gives the leftovers to the first window, so a
    /// sibling window that matched nothing ends up with no sessions. Deliberate:
    /// such a row already shows no state, no topic and no indicator, because the
    /// data layer genuinely does not know which chat it is looking at. Ranking
    /// it by the project's pool instead would hoist an empty row above windows
    /// whose activity is known — a guess dressed as an answer.
    static func rankedWindows(_ rows: [SwitcherRow]) -> [SwitcherRow] {
        // Ties fall back to the arrival index rather than to nothing: `sorted`
        // is not stable, so windows the activity cannot separate — every
        // window without a chat, and any two stamped in the same second — would
        // otherwise be free to swap places between two snapshots a second
        // apart, which is the reshuffling this ordering exists to stop.
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

    /// Orders the orphan `cwd:` rows, which are put ahead of every project row.
    ///
    /// An orphan row exists only because an agent is running in that directory:
    /// take the sessions away and the row is gone, which is not true of a
    /// project row. So the rows that are made of live agents come first, and the
    /// two orderings — agent state here, time of the last session there — never
    /// have to be compared against each other.
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

    /// Orders the projects that have no window by when Claude Code work last
    /// happened in them, newest first.
    ///
    /// Directory mtime, which is what this used to be, answers almost nothing:
    /// it does not move when a file inside the project is edited, so the order
    /// looked arbitrary — a project worked in all week could sit below one last
    /// touched in spring. What that rules out is the *directory's* mtime as a
    /// source, not time as the question. The key here is the mtime of the
    /// newest session transcript, which is exactly the moment someone last
    /// worked in the project.
    ///
    /// The number of sessions inside `activityWindowDays`, which this sorted by
    /// until now, answers a different question — how much was done here, not
    /// where the work is — and the two come apart in practice: a project closed
    /// a week ago with 36 sessions behind it held the top of the list, above the
    /// one being typed in at that moment. `recentSessions` survives as a number
    /// `--dump` prints and counts for itself; on this path it is not even
    /// computed. It is not kept as a second key either, because it could never
    /// fire: it would take
    /// two transcripts written in the same instant, and mtime is sub-second,
    /// while the tie that does happen — `nil` against `nil` — has a count of
    /// zero on both sides by construction.
    ///
    /// Projects that never hosted a session have no time at all and go to the
    /// end, keeping the directory-mtime order the index handed over. That order
    /// is spelled out through the arrival index rather than left to the sort:
    /// `sorted` is not stable, so rows the key cannot separate would otherwise
    /// be free to swap places between two snapshots a second apart.
    static func ranked(_ rows: [SwitcherRow], activity: [String: ProjectActivity]) -> [SwitcherRow] {
        rows.enumerated().sorted { ranksAbove($0, $1, activity: activity) }.map(\.element)
    }

    /// The comparison `ranked` sorts by, spelled out as a function so that the
    /// tie-break can be checked directly.
    ///
    /// Going through `sorted` cannot check it. `sorted` is only *documented* as
    /// unstable; today's implementation keeps equal elements in place anyway, so
    /// deleting the arrival-index line leaves every test of this ranking green
    /// and hands the order over to whatever the next standard library does with
    /// it. Asked here, the comparison has to answer both ways round: rows the
    /// stamps cannot separate are ordered by arrival, and the mirrored call has
    /// to say the opposite.
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

    /// The containment prefix of every project — its path plus the separator —
    /// built once, in the order the projects came in.
    ///
    /// The separator is the whole of the rule: without it `hasPrefix` matches
    /// half a path component, and this machine holds the pairs that turn into a
    /// wrong answer — `asakusa_lab` beside `asakusa_lab_glaze_resolver`,
    /// `portainer` beside `portainer-agent`. The younger project's spend and
    /// every session of it would be attributed to the older one's row.
    /// `ProjectMatchingTests` is what holds it; nothing did before, and
    /// deleting the `+ "/"` left the whole suite green.
    ///
    /// `project(for:in:prefixes:)` is asked the same question for every working
    /// directory `assemble` is handed — the gateway's directories and every live
    /// session's — and each question walks the whole project list. Building
    /// `path + "/"` inside that walk allocates one string per (directory,
    /// project) pair: 200 directories against 99 projects is 19 800 strings,
    /// once or twice a second.
    ///
    /// A plain `[String]` parallel to `projects`, and not an array of
    /// `(project, prefix)` pairs, which is what this was written as first.
    ///
    /// Measured 2026-08-16, Apple M4, Swift 6.2.4, a standalone harness built
    /// with `swiftc -O -whole-module-optimization` holding the three variants
    /// and a verbatim copy of `ProjectInfo`. The measured region is one whole
    /// pass of `assemble`: build whatever the variant hoists, once, then ask
    /// every directory. 99 projects under one parent, so every comparison walks
    /// a 29-character shared prefix before it can differ; 200 directories, of
    /// which 60% are project paths exactly, 30% sit in a worktree below one and
    /// 10% match nothing. Best of 25 passes, three independent runs:
    ///
    /// - 0.96 / 1.05 / 1.14 ms with `path + "/"` inside the loop,
    /// - 0.87 / 0.90 / 0.94 ms hoisted into an array of pairs,
    /// - 0.14 / 0.15 / 0.17 ms as it stands.
    ///
    /// Same three over a shape where nothing matches exactly, so every question
    /// walks the whole list: 1.87–1.98, 1.24–1.33, 0.20–0.22 ms.
    ///
    /// What the pair array costs is the *struct in it*, not the pairing: the
    /// identical walk over `(path, prefix)` strings, with `projects[index]`
    /// returned at the end, measures 0.14–0.15 ms — the parallel array's time.
    /// Walking the pairs by index rather than by value does not help (0.82–0.85
    /// ms), so it is the element being copied out of the array, and the element
    /// is a six-field struct with five refcounted strings in it.
    ///
    /// This comment used to claim the pair array measured *slower than the
    /// concatenation it replaced*, and that is recorded here because it did not
    /// reproduce: two independent re-measurements — a reviewer's harness and
    /// this one — both put the pairs ahead of the concatenation and both put
    /// this variant six to nine times ahead of either. Only the ranking that
    /// survived is stated above.
    ///
    /// For scale, the whole `stat(2)` walk over 362 transcripts is 1.25 ms
    /// (SPEC §6). Today the gateway names 8 directories against the index's 96
    /// projects (`--dump`), and at that size the whole question is 0.021 ms for
    /// the concatenation, 0.012 for this and 0.027 for the pair array — which
    /// is the one place the pairs genuinely lose, and they lose on building
    /// 96 copies of a struct rather than on the walk. So this is not bought for
    /// today's list; it is bought because the shape — a string built inside a
    /// loop over every project — is the one §2.2.1 already caught once.
    static func prefixes(of projects: [ProjectInfo]) -> [String] {
        projects.map { $0.path + "/" }
    }

    /// The project a working directory belongs to: an exact match, otherwise the
    /// deepest project the path sits inside.
    ///
    /// `prefixes` is `prefixes(of:)` over the very same list, positional: index
    /// `i` of one is index `i` of the other. Passed in rather than derived here
    /// so that the caller decides how many times it is built — which is the
    /// point of having it at all.
    ///
    /// One walk rather than the two it used to be (`first(where:)` for the exact
    /// match, then `filter`), because an exact match returns immediately and the
    /// deepest prefix is a running maximum: the `filter` built an array per
    /// working directory to take one element out of it.
    ///
    /// That rewrite is what makes the *walk* depend on the order the projects
    /// arrive in — the exact match short-circuits it, the deepest prefix
    /// accumulates through it. The answer must not depend on that order, and
    /// that is precisely what `ProjectMatchingTests` holds: both cases are
    /// asked with the project list both ways round, because a mutation of the
    /// rule can answer one of the two orders correctly by luck — taking the
    /// first containing project instead of the deepest passes "deep first" and
    /// fails only the other way round.
    static func project(for cwd: String,
                        in projects: [ProjectInfo],
                        prefixes: [String]) -> ProjectInfo? {
        // The positional pairing is an invariant a doc comment cannot enforce,
        // and the walk indexes `projects` by `prefixes.indices`: a shorter
        // `projects` is an out-of-range crash in code that runs once or twice a
        // second, and a longer one silently matches paths against the wrong
        // projects. One integer comparison per call says so at the door.
        precondition(prefixes.count == projects.count,
                     "prefixes must be prefixes(of:) the very projects being searched")
        var deepestIndex = -1
        var deepestLength = 0
        for index in prefixes.indices {
            if projects[index].path == cwd { return projects[index] }
            guard cwd.hasPrefix(prefixes[index]) else { continue }
            // First maximum wins, as `max(by:)` did before it: two projects
            // cannot share a path, so ties are impossible anyway.
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
