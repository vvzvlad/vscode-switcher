import Foundation

/// Reads everything Claude Code leaves on disk: live sessions, the state written
/// by our hooks, the tail of session transcripts and background subagents.
///
/// Nothing here is allowed to throw out to the caller. Files appear, disappear
/// and are rewritten under us all the time, so a failed read simply means "no
/// data for this session".
enum ClaudeSessions {

    static var claudeHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static var sessionsDirectory: URL { claudeHome.appendingPathComponent("sessions") }
    static var projectsDirectory: URL { claudeHome.appendingPathComponent("projects") }
    static var windowStatusDirectory: URL { claudeHome.appendingPathComponent("window-status") }

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
    static func liveSessions(config: Config) -> [ClaudeSessionInfo] {
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
    /// to tell the two apart. Files without `startedAt` keep the old behaviour.
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
                                    config: Config) -> ClaudeSessionInfo {
        let slug = slug(forPath: cwd)
        let transcriptPath = projectsDirectory
            .appendingPathComponent(slug)
            .appendingPathComponent("\(sessionId).jsonl").path

        let hook = hookStatus(sessionId: sessionId)
        let metrics = metricsStatus(sessionId: sessionId)
        let transcript = transcriptSummary(atPath: transcriptPath, tailBytes: config.transcriptTailBytes)

        let resolved = resolveState(hook: hook, transcript: transcript)
        let model = transcript.model ?? metrics?.modelId ?? metrics?.modelName
        let context = contextUsage(transcript: transcript, metrics: metrics)

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
    static func resolveState(hook: HookStatus?,
                             transcript: TranscriptSummary,
                             now: Date = Date()) -> (state: AgentState, source: AgentStateSource) {
        let fromTranscript: (AgentState, AgentStateSource)? = transcript.fallbackState.map { ($0, .transcript) }

        guard let hookState = hook?.state else { return fromTranscript ?? (.idle, .unknown) }
        guard let hookTime = hook?.timestamp else { return (hookState, .hook) }

        // `waiting` and `permission` describe a condition the transcript cannot
        // see: while a permission dialog sits on screen the last assistant
        // record still says `tool_use` and the file keeps being touched, so
        // every touch older than the tolerance used to turn the orange
        // indicator off. Only a newer hook — `Stop`, `UserPromptSubmit` — takes
        // those two states away.
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
    /// are sampled at different moments, and a numerator from one with a
    /// denominator from the other produced percentages such as `194k (97%)` for
    /// a session using 19% of a 1M window.
    static func contextUsage(transcript: TranscriptSummary,
                             metrics: MetricsStatus?) -> (used: Int?, limit: Int?) {
        if let metrics, let used = metrics.usedTokens,
           !metricsAreStale(metrics: metrics, transcript: transcript) {
            // Nothing from the transcript is mixed in here, not even the model
            // identifier: this branch is statusLine's own reading of its own
            // moment.
            let isExtended = isExtendedContextModel([metrics.modelId])
            let limit = metrics.contextWindowSize
                ?? limitFromPercentage(usedTokens: used, percentage: metrics.usedPercentage)
                ?? contextLimitTokens(isExtendedContext: isExtended, usedTokens: used)
            return (used, limit)
        }
        // `message.model` in a transcript is always the plain id
        // (`claude-opus-5`); only `model.id` from statusLine carries the `[1m]`
        // suffix, so both have to be inspected. The model a session runs is not
        // a sample of a moment, so reading it from either source is safe.
        let isExtended = isExtendedContextModel([metrics?.modelId, transcript.model])
        guard let used = transcript.contextUsedTokens else { return (nil, nil) }
        return (used, contextLimitTokens(isExtendedContext: isExtended, usedTokens: used))
    }

    /// How far the transcript may run ahead of `.metrics.json` before that file
    /// stops being believed. statusLine runs on every state change, so an active
    /// session refreshes it within seconds.
    static let metricsLagToleranceSeconds: TimeInterval = 300

    /// Whether `.metrics.json` has been left behind by a statusLine that stopped
    /// running.
    ///
    /// The file survives until `SessionEnd` and is never rewritten if statusLine
    /// breaks — the user replaces their own status line, uninstalls the hooks
    /// (`--uninstall` does not delete metrics), `jq` leaves the PATH. Its numbers
    /// then stay authoritative forever: a stale `5k` against a transcript at
    /// `460k` rendered as a confident `2.5%`. Only claimed when the transcript
    /// can actually replace both numbers.
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
    static func isExtendedContextModel(_ identifiers: [String?]) -> Bool {
        identifiers.contains { $0?.contains("[1m]") == true }
    }

    /// Window size implied by statusLine's own percentage, used only when the
    /// same payload did not state the size outright. Both numbers describe the
    /// same moment, so this is a reading, not a guess.
    ///
    /// The percentage arrives rounded to a whole number, so the quotient carries
    /// that rounding: a real payload gave `204 244` for a 200k window. A limit
    /// is a round number in every window Claude offers, so the quotient is
    /// snapped — to a known window size when the rounding interval covers one,
    /// and to two significant digits otherwise.
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
    static func contextLimitTokens(isExtendedContext: Bool, usedTokens: Int) -> Int? {
        if isExtendedContext { return 1_000_000 }
        // Evidence rather than a heuristic: a 200k window cannot hold this much.
        if usedTokens > 200_000 { return 1_000_000 }
        return nil
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
    /// second and would otherwise re-read several megabytes of unchanged tails
    /// every time, which is what the menu bar agent's power draw comes down to.
    static func transcriptSummary(atPath path: String, tailBytes: Int) -> TranscriptSummary {
        transcriptCache.value(atPath: path, variant: "\(tailBytes)") {
            uncachedTranscriptSummary(atPath: path, tailBytes: tailBytes)
        }
    }

    private static func uncachedTranscriptSummary(atPath path: String, tailBytes: Int) -> TranscriptSummary {
        var summary = TranscriptSummary()
        summary.lastActivity = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date

        let lines = tailLines(atPath: path, maxBytes: tailBytes)
        guard !lines.isEmpty else { return summary }

        var needsTitle = true
        var needsPrompt = true
        var needsAssistant = true

        for line in lines.reversed() {
            if !needsTitle, !needsPrompt, !needsAssistant { break }
            guard line.count > 2, let object = try? JSONC.parse(line), let record = object as? [String: Any] else {
                continue
            }
            guard let type = record["type"] as? String else { continue }

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
                if let usage = message["usage"] as? [String: Any] {
                    let keys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
                    summary.contextUsedTokens = keys.reduce(0) { total, key in
                        total + ((usage[key] as? NSNumber)?.intValue ?? 0)
                    }
                }
                switch message["stop_reason"] as? String {
                case "end_turn", "stop_sequence": summary.fallbackState = .waiting
                case "tool_use": summary.fallbackState = .working
                default: break
                }
                needsAssistant = false
            default:
                continue
            }
        }
        return summary
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

        // Split on the 0x0A byte, not on Characters: `String.split(separator:)`
        // compares graphemes, and CRLF is a single grapheme that never equals
        // "\n", so a CRLF transcript would come back as one giant "line" and the
        // whole session summary would silently disappear. Splitting bytes also
        // avoids materialising the tail as one big String.
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

    private static let subagentListCache = FileDerivedCache<[SubagentEntry]>()

    /// Background subagents of a session.
    ///
    /// Each one is a pair of `agent-<id>.jsonl` and `agent-<id>.meta.json` inside
    /// `<transcript dir>/<sessionId>/subagents/`. A subagent counts as active
    /// while its transcript was touched recently and its last record is not a
    /// finished answer.
    ///
    /// The directory listing and the `.meta.json` parses are cached against the
    /// directory's own mtime, which moves exactly when an entry is added or
    /// removed. This was the last uncached hot path: nine live sessions meant
    /// re-listing nine directories and re-parsing 152 metadata files on every
    /// snapshot, about 9 ms of a 44 ms build. Only the freshness of each
    /// transcript is re-read, because that is what changes between snapshots.
    static func subagents(slug: String, sessionId: String, config: Config) -> [SubagentInfo] {
        let directory = projectsDirectory
            .appendingPathComponent(slug)
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")
        let entries = subagentListCache.value(atPath: directory.path) {
            subagentEntries(in: directory)
        }

        var result: [SubagentInfo] = []
        for entry in entries {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: entry.transcriptPath))?[.modificationDate]
                as? Date

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

    /// Lists a `subagents` directory and reads every `.meta.json` in it. A
    /// missing directory is not an error: most sessions never spawn one.
    static func subagentEntries(in directory: URL) -> [SubagentEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var entries: [SubagentEntry] = []
        for name in names.sorted() where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
            let identifier = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
            let metaPath = directory.appendingPathComponent("agent-\(identifier).meta.json").path
            let meta = JSONC.object(atPath: metaPath)
            entries.append(SubagentEntry(id: identifier,
                                         agentType: meta?["agentType"] as? String,
                                         description: meta?["description"] as? String,
                                         transcriptPath: directory.appendingPathComponent(name).path))
        }
        return entries
    }

    private static let subagentFinishedCache = FileDerivedCache<Bool>()

    /// A subagent transcript ends with an assistant message that stopped on its
    /// own once the agent has delivered its answer. Cached like the session
    /// transcripts: an unchanged file cannot have finished since last time.
    private static func isFinished(transcriptPath: String) -> Bool {
        subagentFinishedCache.value(atPath: transcriptPath) {
            uncachedIsFinished(transcriptPath: transcriptPath)
        }
    }

    private static func uncachedIsFinished(transcriptPath: String) -> Bool {
        let lines = tailLines(atPath: transcriptPath, maxBytes: 64 * 1024)
        guard let last = lines.last,
              let object = try? JSONC.parse(last),
              let record = object as? [String: Any],
              record["type"] as? String == "assistant",
              let message = record["message"] as? [String: Any],
              let stopReason = message["stop_reason"] as? String
        else { return false }
        return stopReason == "end_turn" || stopReason == "stop_sequence"
    }
}

/// Values derived from a file, kept for as long as the file itself does not
/// change.
///
/// `(size, mtime)` is a complete key here: the derived values are pure functions
/// of the file's bytes, and a transcript is only ever appended to. Without this
/// every snapshot re-read and re-parsed several megabytes of tails that could
/// not possibly have changed.
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
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modificationDate = attributes[.modificationDate] as? Date
        else { return compute() }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let key = variant.isEmpty ? path : "\(variant)|\(path)"

        lock.lock()
        if let entry = entries[key], entry.size == size, entry.modificationDate == modificationDate {
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
        entries[key] = Entry(size: size, modificationDate: modificationDate, value: value)
        lock.unlock()
        return value
    }
}
