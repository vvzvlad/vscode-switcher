import Foundation

/// Reads everything Claude Code leaves on disk: live sessions, the state written
/// by our hooks, the tail of session transcripts and background subagents.
///
/// Nothing here is allowed to throw out to the caller. Files appear, disappear
/// and are rewritten under us all the time, so a failed read simply means "no
/// data for this session".
enum ClaudeSessions {

    /// Constants, not computed properties: building them costs ~13 µs and they
    /// are used several times per session on every snapshot.
    static let claudeHome: URL =
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")

    static let sessionsDirectory: URL = claudeHome.appendingPathComponent("sessions")
    static let projectsDirectory: URL = claudeHome.appendingPathComponent("projects")
    static let windowStatusDirectory: URL = claudeHome.appendingPathComponent("window-status")

    // MARK: - Slug

    /// Directory name Claude Code derives from a working directory.
    ///
    /// Every character outside `[A-Za-z0-9-]` becomes `-`, not just the path
    /// separator: `/Users/.../ukuetis_panel_fw` maps to
    /// `-Users-...-ukuetis-panel-fw`. Replacing only `/` silently loses every
    /// project whose name contains an underscore or a dot.
    static func slug(forPath path: String) -> String {
        var result = ""
        result.reserveCapacity(path.count)
        for character in path.unicodeScalars {
            let isKept = (character >= "a" && character <= "z")
                || (character >= "A" && character <= "Z")
                || (character >= "0" && character <= "9")
                || character == "-"
            result.append(isKept ? Character(character) : "-")
        }
        return result
    }

    // MARK: - Live sessions

    /// Sessions whose process is still running and which were started from the
    /// VSCode extension. Dead session files stay on disk forever and have to be
    /// filtered out. Sorted by last activity, most recent first.
    ///
    /// At most one row per `sessionId`: `DataSource.liveSlugsBySessionId` is a
    /// map and the contest veto in `DataSource.settle` relies on it
    /// (`testOneSessionIdYieldsOneLiveRow`). The directory is a parameter so
    /// tests can supply their own files.
    static func liveSessions(config: Config,
                             sessionsDirectory: URL = ClaudeSessions.sessionsDirectory) -> [ClaudeSessionInfo] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: sessionsDirectory.path) else { return [] }

        var sessions: [ClaudeSessionInfo] = []
        var seenSessionIDs = Set<String>()
        // Directory order is unspecified; sorting makes the winner of a
        // duplicate session id the same on every run.
        for name in names.sorted() where name.hasSuffix(".json") {
            let path = sessionsDirectory.appendingPathComponent(name).path
            guard let dict = JSONC.object(atPath: path),
                  let sessionId = dict["sessionId"] as? String,
                  let cwd = dict["cwd"] as? String
            else { continue }

            // Terminal sessions are dropped: the panel is about windows. The
            // contest veto in `DataSource.settle` inherits this gap.
            let entrypoint = (dict["entrypoint"] as? String) ?? ""
            guard entrypoint.hasPrefix("claude-vscode") else { continue }

            let pid = (dict["pid"] as? NSNumber)?.int32Value ?? 0
            let startedAt = (dict["startedAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            guard isSessionProcessAlive(pid: pid, startedAt: startedAt) else { continue }

            // The same session can be described by more than one file (a stale
            // `<pid>.json` left by a crash, a pid that came back). One row.
            guard seenSessionIDs.insert(sessionId).inserted else { continue }

            sessions.append(makeSession(sessionId: sessionId,
                                        pid: pid,
                                        cwd: cwd,
                                        name: dict["name"] as? String,
                                        startedAt: startedAt,
                                        config: config))
        }

        sessions.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        return sessions
    }

    /// `kill(pid, 0)` succeeds for our own processes; `EPERM` means the process
    /// exists but belongs to somebody else, which still counts as alive.
    static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Whether the pid recorded in a session file still belongs to *that*
    /// session.
    ///
    /// Session files stay on disk after the process dies and pids are reused, so
    /// "alive" alone resurrects long-dead sessions under a stranger's process.
    /// A recycled pid necessarily started after the session did, which is enough
    /// to tell the two apart. Files without `startedAt` are judged by liveness alone.
    static func isSessionProcessAlive(pid: Int32, startedAt: Date?) -> Bool {
        guard isProcessAlive(pid) else { return false }
        guard let startedAt, let processStart = processStartTime(pid) else { return true }
        // The session file is written a few seconds after `execve`, so the
        // process start is expected to be slightly *earlier* than `startedAt`.
        return processStart.timeIntervalSince(startedAt) <= processStartSlackSeconds
    }

    /// Clock slack between `kinfo_proc.p_starttime` and the `startedAt` the CLI
    /// records for itself.
    private static let processStartSlackSeconds: TimeInterval = 60

    /// Wall-clock start time of a process, from `sysctl(KERN_PROC_PID)`.
    static func processStartTime(_ pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    private static func makeSession(sessionId: String,
                                    pid: Int32,
                                    cwd: String,
                                    name: String?,
                                    startedAt: Date?,
                                    config: Config) -> ClaudeSessionInfo {
        let slug = slug(forPath: cwd)
        let transcriptPath = projectsDirectory
            .appendingPathComponent(slug)
            .appendingPathComponent("\(sessionId).jsonl").path

        let hook = hookStatus(sessionId: sessionId)
        let metrics = metricsStatus(sessionId: sessionId)
        let transcript = transcriptSummary(atPath: transcriptPath, tailBytes: config.transcriptTailBytes)

        // The pid passed `isSessionProcessAlive`, so it is not known to belong
        // to another process (unproven only if `sysctl` gave no start time).
        let resolved = resolveState(hook: hook, transcript: transcript, sessionStartedAt: startedAt)
        let model = transcript.model ?? metrics?.modelId ?? metrics?.modelName
        let context = contextUsage(transcript: transcript,
                                   metrics: metrics,
                                   configuredModel: configuredModelIdentifier(cwd: cwd))

        let subagents = subagents(slug: slug, sessionId: sessionId, config: config)

        let lastActivity = [hook?.timestamp, metrics?.timestamp, transcript.lastActivity]
            .compactMap { $0 }
            .max()

        return ClaudeSessionInfo(sessionId: sessionId,
                                 pid: pid,
                                 cwd: cwd,
                                 name: name,
                                 aiTitle: transcript.aiTitle,
                                 lastPrompt: transcript.lastPrompt,
                                 state: resolved.state,
                                 stateSource: resolved.source,
                                 model: model,
                                 contextUsedTokens: context.used,
                                 contextLimitTokens: context.limit,
                                 activeSubagents: subagents.filter(\.isActive).count,
                                 subagents: subagents,
                                 lastActivity: lastActivity)
    }

    // MARK: - Project activity

    private static let sessionNamesCache = FileDerivedCache<[String]>()

    /// When each session ever recorded for a working directory was last written.
    ///
    /// `~/.claude/projects/<slug>/` holds one `*.jsonl` per session started in
    /// that directory, and its mtime is when that session was last active.
    /// Subagent transcripts sit one level down, in `<sessionId>/subagents/`, so
    /// a flat listing sees sessions and nothing else. An empty answer is the
    /// ordinary case, not a failure: most projects have no directory here at
    /// all, and some directories hold no transcript (worktree snapshots,
    /// sessions since deleted).
    ///
    /// The listing is cached against the directory's mtime, which moves when a
    /// session file is added or removed. The timestamps are not cached:
    /// appending to a transcript does not move the directory's mtime, and the
    /// stamps decide the project order (SPEC §2.2.1). One `stat(2)` per
    /// transcript costs ~1–4 ms per pass (SPEC §2.2.1).
    static func sessionTimes(forPath path: String,
                             projectsDirectory: URL = ClaudeSessions.projectsDirectory) -> [Date] {
        let directory = projectsDirectory.appendingPathComponent(slug(forPath: path))
        // Most projects have no directory here, and `FileDerivedCache` never
        // caches a missing path; a failing `contentsOfDirectory` per project per
        // snapshot would cost more than the rest of the ranking.
        guard fileStamp(atPath: directory.path) != nil else { return [] }
        let names = sessionNamesCache.value(atPath: directory.path) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
            return names.filter { $0.hasSuffix(".jsonl") }
        }
        // String concatenation: `URL.appendingPathComponent($0).path` per file
        // costs ~10x the `stat(2)` itself.
        let base = directory.path
        return names.compactMap { fileStamp(atPath: base + "/" + $0)?.modificationDate }
    }

    /// The Claude Code work a project has seen: when the newest session of any
    /// age was written, and how many of them fall inside the window.
    ///
    /// Used only by `--dump`; the panel ranks by the newest stamp straight from
    /// `sessionTimes` (SPEC §2.2.1), so this is off the snapshot path.
    static func activity(forPath path: String,
                         windowDays: Int,
                         now: Date = Date(),
                         projectsDirectory: URL = ClaudeSessions.projectsDirectory) -> ProjectActivity {
        let times = sessionTimes(forPath: path, projectsDirectory: projectsDirectory)
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        return ProjectActivity(recentSessions: times.filter { $0 >= cutoff }.count,
                               lastSession: times.max())
    }

    // MARK: - State

    /// A transcript newer than the hook state by more than this proves the hook
    /// missed an event: the session kept writing after the last state we were
    /// told about.
    static let hookLagToleranceSeconds: TimeInterval = 90

    /// How long a `working` hook state stays believable without any newer
    /// evidence. `Stop` hooks do get lost, and a permanently spinning indicator
    /// discredits the whole list.
    static let hookWorkingMaxAgeSeconds: TimeInterval = 300

    /// How recently the transcript must have moved to count as proof that the
    /// session is alive right now. Its mtime advances on every record written,
    /// so a working agent touches it many times a minute.
    static let transcriptLivenessSeconds: TimeInterval = 120

    /// The state of a session, reconciling the hook signal with the transcript.
    ///
    /// The hook file is the freshest source but it is a level, not an event
    /// stream: whatever the last delivered hook wrote stays on disk forever. Two
    /// guards keep a stuck value out of the UI, and both use numbers that are
    /// computed anyway — the hook timestamp and the transcript mtime.
    ///
    /// `sessionStartedAt` is the third guard, aimed at the transcript: a resumed
    /// chat whose tail reads `working` has not run a turn in this process. When
    /// `newestRecordAt` (the stamp of the newest record of any type) is older
    /// than the session start, a transcript `working` is demoted to `idle`. Any
    /// prompt, dialog answer (`tool_result`) or finished replayed tool call
    /// stamps the file, so a real turn stands the rule down. The file mtime is
    /// not used: resuming touches it without appending a record.
    ///
    /// A turn still awaiting a tool result (`lastTurnAwaitingToolResult`) is
    /// exempt: a replayed call on resume has that shape until its result is
    /// written, and it is indistinguishable from a long-running tool (§2.4).
    ///
    /// Only `working` is demoted: `waiting` is true of a resumed chat.
    /// `sessionStartedAt` has no default, so a caller cannot silently drop it.
    static func resolveState(hook: HookStatus?,
                             transcript: TranscriptSummary,
                             sessionStartedAt: Date?,
                             now: Date = Date()) -> (state: AgentState, source: AgentStateSource) {
        // Computed once so that all three uses below agree on it.
        let fallbackState = transcript.fallbackState.map { state -> AgentState in
            guard state == .working,
                  !transcript.lastTurnAwaitingToolResult,
                  let sessionStartedAt,
                  let newestRecordAt = transcript.newestRecordAt,
                  newestRecordAt < sessionStartedAt
            else { return state }
            return .idle
        }
        let fromTranscript: (AgentState, AgentStateSource)? = fallbackState.map { ($0, .transcript) }

        guard let hookState = hook?.state else { return fromTranscript ?? (.idle, .unknown) }
        guard let hookTime = hook?.timestamp else { return (hookState, .hook) }

        // `waiting`, `permission` and `question` are invisible to the
        // transcript (a dialog leaves a `tool_use` tail while the file keeps
        // being touched), so only a newer hook (`Stop`, `UserPromptSubmit`,
        // `PostToolUse`, `PostToolUseFailure`) ends them (SPEC §2.6.2).
        let mayBeOverruled = hookState == .working || hookState == .idle

        // The session went on working long after the hook state was written, so
        // the hook is provably behind and the transcript is the better guess.
        if mayBeOverruled,
           let activity = transcript.lastActivity,
           activity.timeIntervalSince(hookTime) > hookLagToleranceSeconds,
           let fromTranscript {
            return fromTranscript
        }
        // Only `working` asserts activity happening right now, so only it is
        // aged out — and only when nothing else says the session is alive. A
        // transcript touched seconds ago is the strongest such signal there is,
        // and it is there even when the tail yielded no usable state: an
        // assistant record whose `stop_reason` is outside the three known
        // values, or a single record larger than the whole tail window, both
        // leave `fallbackState` empty while the session is plainly running.
        if hookState == .working, now.timeIntervalSince(hookTime) > hookWorkingMaxAgeSeconds {
            guard let activity = transcript.lastActivity,
                  now.timeIntervalSince(activity) <= transcriptLivenessSeconds
            else { return (.idle, .unknown) }
            return fromTranscript ?? (.working, .hook)
        }
        return (hookState, .hook)
    }

    // MARK: - Context window

    /// Used tokens and the window they are measured against.
    ///
    /// The two numbers must come from one source: statusLine and the transcript
    /// are sampled at different moments, and mixing them gives wrong percentages.
    /// `configuredModel` is the alias Claude Code's own settings would start a
    /// session in this directory with. It is the weakest of the sources and only
    /// ever fills in a limit nothing else could supply — see
    /// `configuredModelIdentifier(cwd:)`.
    static func contextUsage(transcript: TranscriptSummary,
                             metrics: MetricsStatus?,
                             configuredModel: String? = nil) -> (used: Int?, limit: Int?) {
        if let metrics, let used = metrics.usedTokens,
           !metricsAreStale(metrics: metrics, transcript: transcript) {
            // Nothing from the transcript is mixed in here, not even the model
            // identifier: this branch is statusLine's own reading of its own
            // moment. The configured model is not a reading of any moment — it
            // is a property of how the session was started — so it stays
            // available as the last resort.
            let isExtended = isExtendedContextModel([metrics.modelId])
            let limit = metrics.contextWindowSize
                ?? limitFromPercentage(usedTokens: used, percentage: metrics.usedPercentage)
                ?? contextLimitTokens(isExtendedContext: isExtended,
                                      configuredModel: configuredModel,
                                      usedTokens: used)
            return (used, limit)
        }
        // `message.model` in a transcript is always the plain id
        // (`claude-opus-5`); only `model.id` from statusLine carries the `[1m]`
        // suffix, so both have to be inspected. The model a session runs is not
        // a sample of a moment, so reading it from either source is safe.
        let isExtended = isExtendedContextModel([metrics?.modelId, transcript.model])
        guard let used = transcript.contextUsedTokens else { return (nil, nil) }
        return (used, contextLimitTokens(isExtendedContext: isExtended,
                                         configuredModel: configuredModel,
                                         usedTokens: used))
    }

    /// How far the transcript may run ahead of `.metrics.json` before that file
    /// stops being believed. statusLine runs on every state change, so an active
    /// session refreshes it within seconds.
    static let metricsLagToleranceSeconds: TimeInterval = 300

    /// Whether `.metrics.json` has been left behind by a statusLine that stopped
    /// running.
    ///
    /// The file survives until `SessionEnd` and is never rewritten if statusLine
    /// breaks (the user replaces their status line, uninstalls the hooks, `jq`
    /// leaves the PATH). Only claimed when the transcript can actually replace
    /// both numbers.
    static func metricsAreStale(metrics: MetricsStatus,
                                transcript: TranscriptSummary) -> Bool {
        guard transcript.contextUsedTokens != nil,
              let activity = transcript.lastActivity
        else { return false }
        // A file that does not say when it was written cannot be shown to be
        // fresh, and the transcript here demonstrably is.
        guard let written = metrics.timestamp else { return true }
        return activity.timeIntervalSince(written) > metricsLagToleranceSeconds
    }

    /// Whether any known identifier of the session's model names the extended
    /// 1M-token variant.
    ///
    /// `[1m]` is the only window marker the CLI has: every accepted form is an
    /// alias or a full id with that one suffix — `opus[1m]`, `sonnet[1m]`,
    /// `opusplan[1m]`, `fable[1m]`, `claude-opus-5[1m]`,
    /// `claude-sonnet-4-5-20250929[1m]`. So the test is for the marker, never
    /// for a known string, and an identifier without it simply comes back false.
    ///
    /// What this cannot see is a session that was moved to another model after
    /// it started: `/model` leaves no record on disk, and the only identifier a
    /// transcript carries — `message.model` — is always the plain id, never the
    /// suffixed one. (`toolUseResult.resolvedModel` does carry suffixes, but it
    /// is the model of a spawned subagent, which is routinely a different one.)
    static func isExtendedContextModel(_ identifiers: [String?]) -> Bool {
        identifiers.contains { $0?.contains("[1m]") == true }
    }

    /// Window size implied by statusLine's own percentage, used only when the
    /// same payload did not state the size outright. Both numbers describe the
    /// same moment, so this is a reading, not a guess.
    ///
    /// The percentage is rounded to a whole number (e.g. `204 244` for a 200k
    /// window), so the quotient is snapped to a known window size when the
    /// rounding interval covers one, and to two significant digits otherwise.
    static func limitFromPercentage(usedTokens: Int, percentage: Double?) -> Int? {
        guard let percentage, percentage >= 1, usedTokens > 0 else { return nil }
        let raw = Double(usedTokens) * 100 / percentage
        let scale = Double(usedTokens) * 100
        let lowest = scale / (percentage + 0.5)
        let highest = percentage > 0.5 ? scale / (percentage - 0.5) : .greatestFiniteMagnitude
        let known = [200_000, 1_000_000]
            .filter { Double($0) >= lowest && Double($0) <= highest }
            .min { abs(Double($0) - raw) < abs(Double($1) - raw) }
        if let known { return known }
        let magnitude = pow(10, max(0, log10(raw).rounded(.down) - 1))
        return Int((raw / magnitude).rounded() * magnitude)
    }

    /// Window size when statusLine did not report one.
    ///
    /// Returns `nil` unless something actually proves the window is the large
    /// one: the default is 200k, but assuming it turns every 1M session into a
    /// near-full bar. A confidently wrong percentage is worse than none, so the
    /// UI is left to show the raw token count instead.
    ///
    /// The three arguments are in descending order of authority, which is why
    /// `configuredModel` comes last: it describes the model Claude Code *would*
    /// start with, not the one this session is provably running.
    static func contextLimitTokens(isExtendedContext: Bool,
                                   configuredModel: String? = nil,
                                   usedTokens: Int) -> Int? {
        if isExtendedContext { return 1_000_000 }
        // Evidence rather than a heuristic: a 200k window cannot hold this much.
        if usedTokens > 200_000 { return 1_000_000 }
        if isExtendedContextModel([configuredModel]) { return 1_000_000 }
        return nil
    }

    // MARK: - Configured model

    /// `ANTHROPIC_MODEL` as this process inherited it, read once: the
    /// environment of a running process cannot change under it, and
    /// `ProcessInfo.environment` rebuilds the whole dictionary on every access.
    static let environmentModel: String? = nonEmpty(ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"])

    /// The model identifier Claude Code resolves for a session started in `cwd`,
    /// or `nil` when nothing pins one and the built-in default applies.
    ///
    /// A `[1m]` suffix in the configured alias requests the 1M window. It is the
    /// weakest source: `/model` and `--model` override it for a running session
    /// and nothing on disk records that (see `isExtendedContextModel`).
    ///
    /// The chain is Claude Code's own, most specific first, per `cwd`. The
    /// inherited environment comes last: a launchd agent inherits almost nothing.
    static func configuredModelIdentifier(cwd: String,
                                          claudeHome: URL = ClaudeSessions.claudeHome,
                                          environmentModel: String? = ClaudeSessions.environmentModel) -> String? {
        let projectSettings = URL(fileURLWithPath: cwd).appendingPathComponent(".claude")
        let paths = [
            projectSettings.appendingPathComponent("settings.local.json").path,
            projectSettings.appendingPathComponent("settings.json").path,
            claudeHome.appendingPathComponent("settings.json").path
        ]
        for path in paths {
            if let model = modelSetting(atPath: path) { return model }
        }
        return environmentModel
    }

    private static let settingsCache = FileDerivedCache<String?>()

    /// The model pinned by one settings file, cached against its own mtime.
    ///
    /// Settings files are read for every session on every snapshot — once a
    /// second while the panel is open — and the user-level one is tens of
    /// kilobytes of permissions and hooks. Parsing it per session per tick is
    /// exactly the kind of idle disk traffic the transcript cache exists to
    /// avoid.
    static func modelSetting(atPath path: String) -> String? {
        settingsCache.value(atPath: path) { uncachedModelSetting(atPath: path) }
    }

    private static func uncachedModelSetting(atPath path: String) -> String? {
        guard let dict = JSONC.object(atPath: path) else { return nil }
        return modelSetting(in: dict)
    }

    /// `model` is what `/model` and the settings UI write; `env.ANTHROPIC_MODEL`
    /// is the other way the same file can pin one, and it loses to an explicit
    /// `model` in that file.
    static func modelSetting(in dict: [String: Any]) -> String? {
        if let model = nonEmpty(dict["model"] as? String) { return model }
        guard let environment = dict["env"] as? [String: Any] else { return nil }
        return nonEmpty(environment["ANTHROPIC_MODEL"] as? String)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Hook state

    struct HookStatus: Sendable {
        var state: AgentState?
        var event: String?
        var timestamp: Date?
    }

    /// State written by `hooks/claude-window-status.sh`. This is the fresh
    /// source; the transcript lags behind by tens of seconds.
    static func hookStatus(sessionId: String) -> HookStatus? {
        let path = windowStatusDirectory.appendingPathComponent("\(sessionId).json").path
        guard let dict = JSONC.object(atPath: path) else { return nil }
        let state = (dict["state"] as? String).flatMap(AgentState.init(rawValue:))
        let timestamp = (dict["ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return HookStatus(state: state, event: dict["event"] as? String, timestamp: timestamp)
    }

    struct MetricsStatus: Sendable {
        var modelName: String?
        var modelId: String?
        var usedPercentage: Double?
        var usedTokens: Int?
        /// The window size Claude itself reports, which removes the 200k/1M guess.
        var contextWindowSize: Int?
        var timestamp: Date?
    }

    /// Model and context numbers cached by `hooks/statusline.sh`.
    static func metricsStatus(sessionId: String) -> MetricsStatus? {
        let path = windowStatusDirectory.appendingPathComponent("\(sessionId).metrics.json").path
        guard let dict = JSONC.object(atPath: path) else { return nil }
        return MetricsStatus(modelName: dict["modelName"] as? String,
                             modelId: dict["modelId"] as? String,
                             usedPercentage: (dict["usedPercentage"] as? NSNumber)?.doubleValue,
                             usedTokens: (dict["usedTokens"] as? NSNumber)?.intValue,
                             contextWindowSize: (dict["contextWindowSize"] as? NSNumber)?.intValue,
                             timestamp: (dict["ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
    }

    // MARK: - Transcript

    struct TranscriptSummary: Sendable {
        var aiTitle: String?
        var lastPrompt: String?
        var model: String?
        var contextUsedTokens: Int?
        var fallbackState: AgentState?
        var lastActivity: Date?
        /// Record-level `timestamp` of the newest record in the tail, of any
        /// type. "This process has written nothing here" is a stamp older than
        /// its start. Empty when the tail carries no stamp at all and when the
        /// newest one would not parse; `nil` never demotes anything (§2.4).
        var newestRecordAt: Date?
        /// Whether the turn the state above was read from still has a tool call
        /// in flight — a `tool_use` block of its own with no result written for
        /// it anywhere below. This is the one shape §2.4 refuses to judge, so
        /// Rule 2 stands down on it (§2.4).
        var lastTurnAwaitingToolResult = false
    }

    private static let transcriptCache = FileDerivedCache<TranscriptSummary>()

    /// Summarises a session transcript from its tail.
    ///
    /// Transcripts reach tens of megabytes, so only the last `tailBytes` are
    /// read and the first (almost certainly truncated) line is dropped. Lines
    /// are inspected from the end and the scan stops as soon as every field is
    /// filled, which normally costs a few dozen JSON parses.
    ///
    /// The result is cached until the file changes: a snapshot runs about once a
    /// second, and re-reading unchanged tails dominates the agent's power draw.
    static func transcriptSummary(atPath path: String, tailBytes: Int) -> TranscriptSummary {
        transcriptCache.value(atPath: path, variant: "\(tailBytes)") {
            uncachedTranscriptSummary(atPath: path, tailBytes: tailBytes)
        }
    }

    private static func uncachedTranscriptSummary(atPath path: String, tailBytes: Int) -> TranscriptSummary {
        var summary = TranscriptSummary()
        summary.lastActivity = fileStamp(atPath: path)?.modificationDate

        let lines = tailLines(atPath: path, maxBytes: tailBytes)
        guard !lines.isEmpty else { return summary }

        var needsTitle = true
        var needsPrompt = true
        var needsAssistant = true
        // Every `tool_use_id` answered below the point the scan has reached.
        // Filled going backwards, so by the time the assistant record that
        // asked is read, its answer — which is written after it — has been seen.
        var answered: Set<String> = []
        // The newest thing the user said after the last assistant record:
        // `true` an interrupt marker, `false` anything else (a prompt after a
        // marker restarts the turn), `nil` nothing yet. Read only at the
        // assistant record that clears `needsAssistant`, so anything set
        // afterwards (an earlier turn) is never seen.
        var lastUserSaidInterrupted: Bool?
        // Whether a record carrying a `timestamp` field has been met yet; not
        // the same as `newestRecordAt == nil` (see below).
        var newestStampSeen = false

        for line in lines.reversed() {
            if !needsTitle, !needsPrompt, !needsAssistant { break }
            guard line.count > 2, let object = try? JSONC.parse(line), let record = object as? [String: Any] else {
                continue
            }
            guard let type = record["type"] as? String else { continue }

            // The first stamp met is the newest. Records without a `timestamp`
            // field are skipped (resume writes several such kinds, §2.4), but a
            // field that does not parse still ends the search with `nil`: an
            // older stamp would wrongly demote a session, and `nil` demotes
            // nothing.
            //
            // `Date.ISO8601FormatStyle` because it is `Sendable`, unlike
            // `ISO8601DateFormatter`. All observed stamps have fractional
            // seconds (§2.4), so there is no fraction-less fallback.
            if !newestStampSeen, let stamp = record["timestamp"] as? String {
                newestStampSeen = true
                summary.newestRecordAt = try? Date(
                    stamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            }

            switch type {
            case "ai-title" where needsTitle:
                if let title = record["aiTitle"] as? String, !title.isEmpty {
                    summary.aiTitle = title
                    needsTitle = false
                }
            case "last-prompt" where needsPrompt:
                if let prompt = record["lastPrompt"] as? String, !prompt.isEmpty {
                    summary.lastPrompt = prompt
                    needsPrompt = false
                }
            case "assistant" where needsAssistant:
                // Sidechain entries belong to subagents and say nothing about
                // the main conversation's context or state.
                if (record["isSidechain"] as? Bool) == true { continue }
                guard let message = record["message"] as? [String: Any],
                      let model = message["model"] as? String,
                      model != "<synthetic>"
                else { continue }
                summary.model = model
                // Recorded whatever the stop reason; only Rule 2 reads it, and
                // only for `working`.
                summary.lastTurnAwaitingToolResult = awaitingToolResult(message: message, answered: answered)
                if let usage = message["usage"] as? [String: Any] {
                    let keys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                    summary.contextUsedTokens = keys.reduce(0) { total, key in
                        total + ((usage[key] as? NSNumber)?.intValue ?? 0)
                    }
                }
                switch message["stop_reason"] as? String {
                case "end_turn", "stop_sequence": summary.fallbackState = .waiting
                case "tool_use":
                    // Most tool calls mean the turn is running, but
                    // `userFacingTools` hand control back until a human answers.
                    let asked = unansweredQuestion(message: message, answered: answered)
                    // An interrupted turn is over, whatever it stopped on. The
                    // question branch is left alone: a question the user typed
                    // over is still the last thing that happened, and a wrongly
                    // cleared `question` never comes back on its own.
                    if asked {
                        summary.fallbackState = .question
                    } else {
                        summary.fallbackState = lastUserSaidInterrupted == true ? .idle : .working
                    }
                default: break
                }
                needsAssistant = false
            case "user":
                // Answers are collected from every user record, sidechain ones
                // included (SPEC §2.4): `tool_use_id` is unique, so a subagent's
                // result can never close somebody else's question.
                collectAnswers(record: record, into: &answered)
                // What the user said belongs to its own chain, mirroring the
                // sidechain test in the assistant branch. `needsAssistant` is
                // only an early-out on this hot path: most `user` records are
                // visited after it is false, and the verdict is never read then
                // (`testAMarkerOlderThanTheLastTurnChangesNothing`).
                if needsAssistant, lastUserSaidInterrupted == nil,
                   (record["isSidechain"] as? Bool) != true,
                   let verdict = interruptVerdict(record: record) {
                    lastUserSaidInterrupted = verdict
                }
                continue
            default:
                continue
            }
        }
        return summary
    }

    /// Tools whose call is a question to the user rather than work being done.
    ///
    /// `ExitPlanMode` waits for a human to approve the plan, like
    /// `AskUserQuestion`; its hook payload is unverified (SPEC §2.6.2), but here
    /// the call is read from the transcript.
    static let userFacingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// True when an assistant message asks the user something and the answer has
    /// not arrived yet.
    ///
    /// The answer is a later record, already passed by the backwards scan, so
    /// `answered` carries the `tool_use_id`s seen below this point. Matching is
    /// by id, so an unrelated tool result does not close the question.
    static func unansweredQuestion(message: [String: Any], answered: Set<String>) -> Bool {
        guard let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains { block in
            guard (block["type"] as? String) == "tool_use",
                  userFacingTools.contains((block["name"] as? String) ?? "")
            else { return false }
            guard let id = block["id"] as? String else {
                // No id to match on. Treating it as unanswered keeps the signal
                // that the agent stopped for a human; a stale question fades on
                // its own once the next assistant record lands.
                return true
            }
            return !answered.contains(id)
        }
    }

    /// True when the assistant record still has a tool call in flight: one of
    /// its own `tool_use` blocks has no result written for it below.
    ///
    /// Same id matching as `unansweredQuestion`, but over every tool: §2.4 does
    /// not judge a turn waiting for any tool, since it may be a long `Bash` and a
    /// working agent must never vanish. A `tool_use` with no id counts as in
    /// flight.
    static func awaitingToolResult(message: [String: Any], answered: Set<String>) -> Bool {
        guard let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains { block in
            guard (block["type"] as? String) == "tool_use" else { return false }
            guard let id = block["id"] as? String else { return true }
            return !answered.contains(id)
        }
    }

    /// Adds the `tool_use_id` of every tool result in a user record to `answered`.
    ///
    /// Sidechain records are collected too: ids are unique per tool call, so a
    /// subagent result can never match a question asked on the main chain.
    static func collectAnswers(record: [String: Any], into answered: inout Set<String>) {
        guard let message = record["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return }
        for block in content where (block["type"] as? String) == "tool_result" {
            if let id = block["tool_use_id"] as? String { answered.insert(id) }
        }
    }

    /// What Claude Code writes into the transcript when the user cuts a turn
    /// short: `[Request interrupted by user]` or `[Request interrupted by user
    /// for tool use]` (§2.4).
    static let interruptMarkerPrefix = "[Request interrupted"

    /// What a user record says about the turn: `true` — the user cut it short,
    /// `false` — the user said something else, so a turn is under way again,
    /// `nil` — the record is not the user speaking at all.
    ///
    /// A plain-string `content` is never the marker (§2.4): it is a prompt,
    /// slash command or injected message, and reads `false`, the safe direction
    /// (`false` keeps `working`; only `true` takes a state away).
    ///
    /// The marker appears as a `text` block or as the string content of a
    /// `tool_result`. Any other `tool_result` (including a dialog answer) says
    /// nothing and yields `nil`, so a bare result cannot end a running turn.
    /// Any other block (e.g. a pasted image) counts as speech.
    static func interruptVerdict(record: [String: Any]) -> Bool? {
        guard let message = record["message"] as? [String: Any] else { return nil }
        if message["content"] is String { return false }
        guard let content = message["content"] as? [[String: Any]] else { return nil }
        var saidSomething = false
        for block in content {
            let type = block["type"] as? String
            if type == "text", let text = block["text"] as? String,
               text.hasPrefix(interruptMarkerPrefix) {
                return true
            }
            if type == "tool_result" {
                if let text = block["content"] as? String, text.hasPrefix(interruptMarkerPrefix) {
                    return true
                }
                continue
            }
            saidSomething = true
        }
        return saidSomething ? false : nil
    }

    /// Last `maxBytes` of a file split into lines, without the first partial one.
    static func tailLines(atPath path: String, maxBytes: Int) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else { return [] }
        let window = UInt64(max(0, maxBytes))
        let offset = size > window ? size - window : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return [] }

        // Split on the 0x0A byte, not on Characters: CRLF is a single grapheme
        // that never equals "\n". Splitting bytes also avoids building the tail
        // as one big String.
        //
        // A cut in the middle of a UTF-8 sequence only damages the first line,
        // which is dropped anyway when the file was longer than the window.
        var lines = data.split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) }
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    // MARK: - Subagents

    /// The part of a subagent that never changes once it exists: identity and
    /// the metadata written when it was spawned.
    struct SubagentEntry: Sendable {
        var id: String
        var agentType: String?
        var description: String?
        var transcriptPath: String
    }

    /// One directory under `subagents/`: the agents in it and the directories
    /// below it.
    struct SubagentListing: Sendable {
        var entries: [SubagentEntry] = []
        var subdirectories: [String] = []
    }

    private static let subagentListCache = FileDerivedCache<SubagentListing>()

    /// Background subagents of a session.
    ///
    /// Each one is a pair of `agent-<id>.jsonl` and `agent-<id>.meta.json` inside
    /// `<transcript dir>/<sessionId>/subagents/` — or deeper: Workflow puts its
    /// agents in `subagents/workflows/wf_<id>/`. A subagent counts as active
    /// while its transcript was touched within `subagentActiveSeconds` and its
    /// last record does not say it stopped — either a final answer (`end_turn`
    /// or `stop_sequence`) or the interrupt marker.
    ///
    /// The last record is what matters; the age threshold is deliberately
    /// generous because a thinking model can be silent for minutes (`Config`,
    /// SPEC §3.1). The cheap age check runs first so `isFinished` (a 64 KB tail
    /// read) is skipped for old transcripts.
    ///
    /// Directory listings and `.meta.json` parses are cached against each
    /// directory's mtime; only each transcript's freshness is re-read.
    static func subagents(slug: String,
                          sessionId: String,
                          config: Config,
                          projectsDirectory: URL = ClaudeSessions.projectsDirectory) -> [SubagentInfo] {
        let directory = projectsDirectory
            .appendingPathComponent(slug)
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")
        let entries = subagentEntries(in: directory)

        var result: [SubagentInfo] = []
        for entry in entries {
            let mtime = fileStamp(atPath: entry.transcriptPath)?.modificationDate

            var isActive = false
            if let mtime, Date().timeIntervalSince(mtime) <= config.subagentActiveSeconds {
                isActive = !isFinished(transcriptPath: entry.transcriptPath)
            }

            result.append(SubagentInfo(id: entry.id,
                                       agentType: entry.agentType,
                                       description: entry.description,
                                       lastActivity: mtime,
                                       isActive: isActive))
        }
        result.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        return result
    }

    /// Every subagent under a `subagents` directory, at any depth. A missing
    /// directory is not an error: most sessions never spawn one.
    ///
    /// Each directory is cached on its own: adding an agent to
    /// `workflows/wf_<id>/` moves the mtime of that directory and of no other,
    /// so a single entry keyed on `subagents/` would hide it until something
    /// else changed at the top.
    static func subagentEntries(in directory: URL) -> [SubagentEntry] {
        let listing = subagentListCache.value(atPath: directory.path) {
            subagentListing(in: directory)
        }
        return listing.entries + listing.subdirectories.flatMap {
            subagentEntries(in: directory.appendingPathComponent($0))
        }
    }

    /// Lists one directory and reads every `.meta.json` in it.
    private static func subagentListing(in directory: URL) -> SubagentListing {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return SubagentListing()
        }
        var listing = SubagentListing()
        for name in names.sorted() {
            guard name.hasPrefix("agent-") else {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path,
                                                  isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    listing.subdirectories.append(name)
                }
                continue
            }
            guard name.hasSuffix(".jsonl") else { continue }
            let identifier = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
            let metaPath = directory.appendingPathComponent("agent-\(identifier).meta.json").path
            let meta = JSONC.object(atPath: metaPath)
            listing.entries.append(SubagentEntry(id: identifier,
                                                 agentType: meta?["agentType"] as? String,
                                                 description: meta?["description"] as? String,
                                                 transcriptPath: directory.appendingPathComponent(name).path))
        }
        return listing
    }

    private static let subagentFinishedCache = FileDerivedCache<Bool>()

    /// A subagent transcript ends either with an assistant message that stopped
    /// on its own, once the agent has delivered its answer, or with the marker
    /// left where the user cut it short. Cached like the session transcripts:
    /// an unchanged file cannot have finished since last time.
    private static func isFinished(transcriptPath: String) -> Bool {
        subagentFinishedCache.value(atPath: transcriptPath) {
            uncachedIsFinished(transcriptPath: transcriptPath)
        }
    }

    private static func uncachedIsFinished(transcriptPath: String) -> Bool {
        // A last record longer than the window leaves no whole line (SPEC §3.1);
        // then the window doubles until a line fits or it covers the file.
        var window = 64 * 1024
        var lines = tailLines(atPath: transcriptPath, maxBytes: window)
        while lines.isEmpty, let size = fileStamp(atPath: transcriptPath)?.size, UInt64(window) < size {
            window *= 2
            lines = tailLines(atPath: transcriptPath, maxBytes: window)
        }
        guard let last = lines.last,
              let object = try? JSONC.parse(last),
              let record = object as? [String: Any]
        else { return false }

        switch record["type"] as? String {
        case "user":
            // An interrupt marker as the last record ends the subagent; anything
            // appended later becomes the tail instead (SPEC §2.5).
            return interruptVerdict(record: record) == true
        case "assistant":
            // A whitelist on purpose: a text record with `stop_reason: null`
            // looks like an answer but occurs mid-turn far more often than as a
            // final record, so it stays with the clock (§3.1).
            guard let message = record["message"] as? [String: Any],
                  let stopReason = message["stop_reason"] as? String
            else { return false }
            return stopReason == "end_turn" || stopReason == "stop_sequence"
        default:
            return false
        }
    }
}

/// Size and modification time of a path, or `nil` when it cannot be stat'ed.
///
/// `stat(2)` rather than `FileManager.attributesOfItem`, which builds a whole
/// dictionary of bridged objects; this runs hundreds of times per snapshot.
func fileStamp(atPath path: String) -> (size: UInt64, modificationDate: Date)? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    let seconds = Double(info.st_mtimespec.tv_sec)
        + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
    return (size: UInt64(max(0, info.st_size)),
            modificationDate: Date(timeIntervalSince1970: seconds))
}

/// Values derived from a file, kept for as long as the file itself does not
/// change.
///
/// `(size, mtime)` is a complete key here: the derived values are pure functions
/// of the file's bytes, and a transcript is only ever appended to.
///
/// A directory works as the key too — its mtime moves exactly when an entry is
/// added or removed, which is when a listing of it changes. A file that does not
/// exist is never cached: a `subagents` directory appears the moment the session
/// spawns its first background agent.
///
/// `@unchecked Sendable`: the only mutable state is `entries`, and it is never
/// touched outside `lock`.
final class FileDerivedCache<Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        var size: UInt64
        var modificationDate: Date
        var value: Value
    }

    /// The live working set is one entry per live session, so this is only ever
    /// reached by a process that has watched sessions come and go for days.
    private static var capacity: Int { 256 }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// The cached value for `path`, computing it when the file moved. `variant`
    /// separates values derived from the same file under different parameters.
    func value(atPath path: String, variant: String = "", compute: () -> Value) -> Value {
        guard let stamp = fileStamp(atPath: path) else { return compute() }
        let key = variant.isEmpty ? path : "\(variant)|\(path)"

        lock.lock()
        if let entry = entries[key], entry.size == stamp.size,
           entry.modificationDate == stamp.modificationDate {
            defer { lock.unlock() }
            return entry.value
        }
        lock.unlock()

        let value = compute()

        lock.lock()
        // Dropping everything is fine: the next snapshot refills exactly the
        // entries that are still in use, and nothing here is expensive to redo
        // once.
        if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
        entries[key] = Entry(size: stamp.size, modificationDate: stamp.modificationDate, value: value)
        lock.unlock()
        return value
    }
}
