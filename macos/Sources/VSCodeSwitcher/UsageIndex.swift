import Foundation

/// Which directories hold each Claude Code session's transcript, and how the
/// gateway's per-session figures fold onto those directories.
///
/// The gateway accounts by `session_id` and knows nothing about projects — it
/// never sees a working directory. The join is done here, against what Claude
/// Code leaves on disk: `~/.claude/projects/<slug>/<sessionId>.jsonl`. Nothing
/// in this file opens a transcript; the *name of the directory* is the whole
/// signal, and the directories are listed, never read.
///
/// That is a deliberate retreat from reading the file, and it is worth spelling
/// out why, because the head of a transcript looks like a better answer and is
/// not one. `cwd` is a field of every record rather than a property of the
/// session: a session walks between directories while it runs — 28 of the 30
/// local sessions in the live 7-day window touched more than one, median 4 and
/// maximum 18 (measured 2026-08-17). Worse, when a session is *resumed* in
/// another directory Claude Code keeps the identifier, opens a file under the
/// new slug and seeds it with a copy of the old history: both copies then begin
/// with the same record, to the millisecond, and neither the first record nor
/// the last of the new copy need name the directory it sits in. On the live pair
/// `65f9afa1` the copy under the `research-mcp` slug opens on `home-network` and
/// ends on `ukuetis_site`. A head read would have answered `home-network` for a
/// file that belongs to `research-mcp` — confidently, and wrongly.
///
/// The slug cannot be wrong that way: Claude Code writes the file under the slug
/// of the directory the session was started in, so the directory name *is* the
/// record of where this life of the session began. It is a one-way function
/// (`ClaudeSessions.slug(forPath:)` replaces every character outside
/// `[A-Za-z0-9-]`, not just the separator), so it is never decoded — the match
/// runs forwards, from each known project to its slug (`DataSource`).
///
/// So the promise every figure downstream makes is exactly this: **the spend of
/// the sessions started in a project**, where "started" means this life of the
/// session began there. Not the spend incurred inside it — the gateway reports
/// one aggregate per session and offers nothing to split it by, and dividing it
/// by record counts would be inventing data.
enum UsageIndex {

    private static let listingCache = FileDerivedCache<[String]>()

    /// The slug directories that hold a transcript of each of the given
    /// sessions — distinct and sorted.
    ///
    /// Usually one, and the list is the point: a `session_id` is **not** unique
    /// across `~/.claude/projects/`. Five identifiers on this machine sit in two
    /// slug directories each, and those are not two sessions that collided but
    /// one session resumed in another directory. Taking whichever copy the walk
    /// reached first attributed the spend to whichever project won a race nobody
    /// was watching, and the winner could change between two polls.
    ///
    /// Sessions with no transcript here are simply absent from the result: the
    /// agent nodes run their own Claude Code elsewhere and report to the same
    /// gateway, which is ordinary rather than an error.
    ///
    /// The listings are cached against directory mtime, which moves exactly when
    /// a session file appears or disappears — that is, exactly when a listing
    /// changes. Timestamps are never cached that way (appending to an open
    /// transcript moves neither), but nothing here reads a timestamp: only names.
    static func slugsBySessionId(for sessionIds: Set<String>,
                                 projectsDirectory: URL = ClaudeSessions.projectsDirectory) -> [String: [String]] {
        guard !sessionIds.isEmpty else { return [:] }

        let root = projectsDirectory.path
        let slugs = listingCache.value(atPath: root) {
            (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        }

        var found: [String: [String]] = [:]
        // Every slug directory is walked, always. The walk used to stop as soon
        // as it had one directory per wanted session, which is exactly what made
        // a duplicated identifier resolve to whichever copy came first. There is
        // no count at which it may stop early — the next directory can always
        // hold another copy — so the answer is only complete once the listing is
        // exhausted. Subagent transcripts sit one level below, in
        // `<sessionId>/subagents/`, so a flat listing sees sessions and nothing
        // else.
        for slug in slugs.sorted() {
            let directory = root + "/" + slug
            let names = listingCache.value(atPath: directory) {
                let listed = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
                return listed.filter { $0.hasSuffix(".jsonl") }
            }
            for name in names {
                let sessionId = String(name.dropLast(".jsonl".count))
                guard sessionIds.contains(sessionId) else { continue }
                found[sessionId, default: []].append(slug)
            }
        }
        return found
    }

    /// Folds per-session figures onto the directories the sessions started in.
    ///
    /// Several sessions start in one directory routinely — different chats in
    /// the same project — so this is a sum, and a sum that keeps track of what
    /// the gateway left unnamed (`TokenCounts.isComplete`). Sessions with no
    /// transcript here go to `unmatched`, which is spend with no owner on this
    /// machine rather than spend to be dropped.
    ///
    /// A session found under more than one slug goes to `contested` whole, and
    /// is deliberately *not* summed into anything: the gateway reports one
    /// aggregate for the whole session and there is nothing to divide it between
    /// its lives, so picking a directory here would be the silent
    /// misattribution this split exists to stop. Whether the disagreement
    /// matters at all is decided one level up, where the project list is known —
    /// a project and a worktree of it are two slugs and one answer
    /// (`DataSource.settle`).
    static func fold(sessions: [GatewaySession], slugsBySessionId: [String: [String]])
        -> (tokensBySlug: [String: TokenCounts],
            contested: [ContestedSpend],
            unmatched: TokenCounts,
            unmatchedSessions: Int) {
        var tokensBySlug: [String: TokenCounts] = [:]
        var contested: [ContestedSpend] = []
        var unmatched = TokenCounts.zero
        var unmatchedSessions = 0

        for session in sessions {
            let slugs = slugsBySessionId[session.sessionId] ?? []
            guard let slug = slugs.first else {
                unmatched = unmatched + session.tokens
                unmatchedSessions += 1
                continue
            }
            guard slugs.count == 1 else {
                contested.append(ContestedSpend(slugs: slugs, tokens: session.tokens))
                continue
            }
            tokensBySlug[slug] = (tokensBySlug[slug] ?? .zero) + session.tokens
        }
        return (tokensBySlug, contested, unmatched, unmatchedSessions)
    }
}

/// The spend of one session whose transcript sits under more than one slug —
/// one session that was resumed in another directory.
///
/// Kept per session rather than summed by slug list: the count of such sessions
/// is one of the two numbers `--dump` reports about them, and the slugs are what
/// decides where the tokens end up.
struct ContestedSpend: Sendable, Equatable {
    /// The distinct slug directories holding a copy, sorted. Two or more by
    /// construction — one is not contested and none is unmatched.
    let slugs: [String]
    let tokens: TokenCounts
}
