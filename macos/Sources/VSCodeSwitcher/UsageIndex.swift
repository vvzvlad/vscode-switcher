import Foundation

/// Where each Claude Code session ran, and how the gateway's per-session figures
/// fold onto those directories.
///
/// The gateway accounts by `session_id` and knows nothing about projects — it
/// never sees a working directory. The join is done here, against what Claude
/// Code leaves on disk: `~/.claude/projects/<slug>/<sessionId>.jsonl`.
enum UsageIndex {

    /// How much of a transcript's head is read looking for the working
    /// directory. Transcripts reach tens of megabytes and are never read whole;
    /// `cwd` is written into the records themselves, so the first few kilobytes
    /// carry it.
    static let headBytes = 64 * 1024

    private static let listingCache = FileDerivedCache<[String]>()
    private static let cwdCache = CwdCache()

    /// Absolute working directory of each of the given sessions.
    ///
    /// Sessions with no local transcript are simply absent from the result: the
    /// agent nodes run their own Claude Code elsewhere and report to the same
    /// gateway, which is ordinary rather than an error.
    ///
    /// The directory *listings* are cached against directory mtime, which moves
    /// exactly when a session file appears or disappears — that is, exactly when
    /// a listing changes. Timestamps are never cached that way (appending to an
    /// open transcript moves neither), but nothing here reads a timestamp: only
    /// names.
    static func cwdBySessionId(for sessionIds: Set<String>,
                               projectsDirectory: URL = ClaudeSessions.projectsDirectory) -> [String: String] {
        guard !sessionIds.isEmpty else { return [:] }

        var result: [String: String] = [:]
        var wanted: Set<String> = []
        for sessionId in sessionIds {
            // A resolved session needs no file at all on later polls: its
            // working directory was fixed when it started.
            if let cwd = cwdCache.value(for: sessionId) {
                result[sessionId] = cwd
            } else {
                wanted.insert(sessionId)
            }
        }
        guard !wanted.isEmpty else { return result }

        for (sessionId, path) in transcriptPaths(for: wanted, projectsDirectory: projectsDirectory) {
            guard let cwd = cwd(fromTranscriptAtPath: path) else { continue }
            cwdCache.store(cwd, for: sessionId)
            result[sessionId] = cwd
        }
        return result
    }

    /// Transcript path of each wanted session, by walking the slug directories.
    ///
    /// The slug is a working directory with every character outside `[A-Za-z0-9-]`
    /// replaced by `-`, which is not reversible — two directories can share one
    /// slug and nothing can be read back out of it. So the directories are only
    /// ever used to *find* files, and the working directory comes from inside
    /// the transcript.
    ///
    /// Subagent transcripts sit one level below, in `<sessionId>/subagents/`, so
    /// a flat listing of each slug directory sees sessions and nothing else.
    private static func transcriptPaths(for sessionIds: Set<String>,
                                        projectsDirectory: URL) -> [String: String] {
        let root = projectsDirectory.path
        let slugs = listingCache.value(atPath: root) {
            (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        }

        var found: [String: String] = [:]
        for slug in slugs {
            let directory = root + "/" + slug
            let names = listingCache.value(atPath: directory) {
                let listed = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
                return listed.filter { $0.hasSuffix(".jsonl") }
            }
            for name in names {
                let sessionId = String(name.dropLast(".jsonl".count))
                guard sessionIds.contains(sessionId), found[sessionId] == nil else { continue }
                found[sessionId] = directory + "/" + name
            }
            if found.count == sessionIds.count { break }
        }
        return found
    }

    /// The working directory a transcript records for itself, read from its
    /// head.
    ///
    /// Every record carries `cwd`, but the very first line can be a `summary`
    /// record that does not, so the head is scanned line by line until one does.
    /// The last line of a full window is dropped rather than parsed — the window
    /// may have cut it in half, and a line that merely ends there looks exactly
    /// the same from inside.
    ///
    /// That drop needs a line to fall back on, so it does not fire when the
    /// window holds only one: a first line longer than the whole window is
    /// parsed, truncated as it is, and rejected by `JSONSerialization` — the
    /// prefix of a JSON object is an unterminated object and never a valid one.
    /// Two different reasons, one answer: such a transcript comes back `nil`.
    /// Accepted rather than fixed. The session lands in
    /// `fold`'s `unmatched` — spend with no owner on this machine, shown as
    /// such — which is the honest outcome; the alternatives are growing the
    /// window until some transcript exceeds that one too, or parsing a truncated
    /// record and attributing the spend to whatever path the cut left behind.
    /// It has not been seen in the wild: the first records of a transcript are
    /// short, and the megabyte-sized lines are tool results far down the file.
    ///
    /// Internal, and with `headBytes` a parameter, so that the window can be
    /// made small enough for a test to straddle it: the behaviour that matters
    /// here is what happens at the far edge of a file that is never read whole
    /// (transcripts reach tens of megabytes), and a test that fits inside the
    /// window tests nothing.
    static func cwd(fromTranscriptAtPath path: String,
                    headBytes: Int = UsageIndex.headBytes) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headBytes), !data.isEmpty else { return nil }

        // Split on the 0x0A byte rather than on Characters: a CRLF file would
        // otherwise come back as one line, and a cut in the middle of a UTF-8
        // sequence would be a decoding problem instead of a dropped line.
        var lines = data.split(separator: 0x0A)
        // `lines.count > 1`: with a single line there is nothing left to read
        // after dropping it, so it is handed to the parser instead — which
        // rejects it, because a cut JSON object is not a JSON object.
        if data.count >= headBytes, lines.count > 1 { lines.removeLast() }

        for line in lines {
            guard line.count > 2,
                  let object = try? JSONC.parse(String(decoding: line, as: UTF8.self)),
                  let record = object as? [String: Any],
                  let cwd = record["cwd"] as? String,
                  !cwd.isEmpty
            else { continue }
            return cwd
        }
        return nil
    }

    /// Folds per-session figures into per-directory ones.
    ///
    /// Several sessions share a working directory routinely — different chats in
    /// the same project, and worktrees of it — so this is a sum, and a sum that
    /// keeps track of what the gateway left unnamed (`TokenCounts.isComplete`).
    /// Sessions with no local transcript go to `unmatched`, which is spend with
    /// no owner on this machine rather than spend to be dropped.
    static func fold(sessions: [GatewaySession], cwdBySessionId: [String: String])
        -> (tokensByCwd: [String: TokenCounts], unmatched: TokenCounts, unmatchedSessions: Int) {
        var tokensByCwd: [String: TokenCounts] = [:]
        var unmatched = TokenCounts.zero
        var unmatchedSessions = 0

        for session in sessions {
            guard let cwd = cwdBySessionId[session.sessionId] else {
                unmatched = unmatched + session.tokens
                unmatchedSessions += 1
                continue
            }
            tokensByCwd[cwd] = (tokensByCwd[cwd] ?? .zero) + session.tokens
        }
        return (tokensByCwd, unmatched, unmatchedSessions)
    }
}

/// `sessionId → cwd`, kept for the life of the process.
///
/// A session's working directory is written into its first records and cannot
/// change afterwards, so an entry never goes stale. Failures are deliberately
/// not remembered: a transcript that could not be read this minute — being
/// written, not yet flushed, on a volume that went away — may well be readable
/// the next.
///
/// Unbounded on purpose: the working set is the sessions the gateway reports for
/// its window, a couple of hundred short strings at most.
///
/// `@unchecked Sendable`: the dictionary is only ever touched under the lock.
private final class CwdCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for sessionId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[sessionId]
    }

    func store(_ cwd: String, for sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        values[sessionId] = cwd
    }
}
