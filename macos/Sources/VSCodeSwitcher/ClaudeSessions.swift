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
        for name in names where name.hasSuffix(".json") {
            let path = sessionsDirectory.appendingPathComponent(name).path
            guard let dict = JSONC.object(atPath: path),
                  let sessionId = dict["sessionId"] as? String,
                  let cwd = dict["cwd"] as? String
            else { continue }

            let entrypoint = (dict["entrypoint"] as? String) ?? ""
            guard entrypoint.hasPrefix("claude-vscode") else { continue }

            let pid = (dict["pid"] as? NSNumber)?.int32Value ?? 0
            guard isProcessAlive(pid) else { continue }

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

        let state: AgentState
        let source: AgentStateSource
        if let hookState = hook?.state {
            state = hookState
            source = .hook
        } else if let fallback = transcript.fallbackState {
            state = fallback
            source = .transcript
        } else {
            state = .idle
            source = .unknown
        }

        let model = transcript.model ?? metrics?.modelId ?? metrics?.modelName
        let usedTokens = transcript.contextUsedTokens ?? metrics?.usedTokens
        // statusLine reports the real window size; everything else has to infer it.
        let limit = metrics?.contextWindowSize
            ?? usedTokens.map { contextLimitTokens(model: model, usedTokens: $0) }

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
                                 state: state,
                                 stateSource: source,
                                 model: model,
                                 contextUsedTokens: usedTokens,
                                 contextLimitTokens: limit,
                                 activeSubagents: subagents.filter(\.isActive).count,
                                 subagents: subagents,
                                 lastActivity: lastActivity)
    }

    /// The window is 200k by default and 1M for the extended-context variants.
    /// The model id alone is not enough — the same id serves both — so a count
    /// that already exceeds 200k proves the session runs on the large window.
    static func contextLimitTokens(model: String?, usedTokens: Int) -> Int {
        if usedTokens > 200_000 { return 1_000_000 }
        if let model, model.contains("[1m]") { return 1_000_000 }
        return 200_000
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

    /// Summarises a session transcript from its tail.
    ///
    /// Transcripts reach tens of megabytes, so only the last `tailBytes` are
    /// read and the first (almost certainly truncated) line is dropped. Lines
    /// are inspected from the end and the scan stops as soon as every field is
    /// filled, which normally costs a few dozen JSON parses.
    static func transcriptSummary(atPath path: String, tailBytes: Int) -> TranscriptSummary {
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

        // A cut in the middle of a UTF-8 sequence only damages the first line,
        // which is dropped anyway when the file was longer than the window.
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    // MARK: - Subagents

    /// Background subagents of a session.
    ///
    /// Each one is a pair of `agent-<id>.jsonl` and `agent-<id>.meta.json` inside
    /// `<transcript dir>/<sessionId>/subagents/`. A subagent counts as active
    /// while its transcript was touched recently and its last record is not a
    /// finished answer.
    static func subagents(slug: String, sessionId: String, config: Config) -> [SubagentInfo] {
        let directory = projectsDirectory
            .appendingPathComponent(slug)
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }

        var result: [SubagentInfo] = []
        for name in names where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
            let identifier = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
            let transcriptPath = directory.appendingPathComponent(name).path
            let metaPath = directory.appendingPathComponent("agent-\(identifier).meta.json").path

            let meta = JSONC.object(atPath: metaPath)
            let mtime = (try? FileManager.default.attributesOfItem(atPath: transcriptPath))?[.modificationDate] as? Date

            var isActive = false
            if let mtime, Date().timeIntervalSince(mtime) <= config.subagentActiveSeconds {
                isActive = !isFinished(transcriptPath: transcriptPath)
            }

            result.append(SubagentInfo(id: identifier,
                                       agentType: meta?["agentType"] as? String,
                                       description: meta?["description"] as? String,
                                       lastActivity: mtime,
                                       isActive: isActive))
        }
        result.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        return result
    }

    /// A subagent transcript ends with an assistant message that stopped on its
    /// own once the agent has delivered its answer.
    private static func isFinished(transcriptPath: String) -> Bool {
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
