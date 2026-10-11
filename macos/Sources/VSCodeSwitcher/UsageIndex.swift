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
/// The head of a transcript looks like a better answer than the directory name
/// and is not one. `cwd` is a field of every record rather than a property of
/// the session: a session walks between directories while it runs (in one
/// 7-day window, 28 of 30 local sessions touched more than one, median 4,
/// maximum 18). Worse, when a session is *resumed* in another directory Claude
/// Code keeps the identifier, opens a file under the new slug and seeds it with
/// a copy of the old history: both copies then begin with the same record, to
/// the millisecond, and neither the first record nor the last of the new copy
/// need name the directory it sits in. A head read can answer `home-network`
/// for a file that belongs to `research-mcp` — confidently, and wrongly.
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
    /// across `~/.claude/projects/`. One session resumed in another directory
    /// sits in two slug directories, and taking whichever copy the walk reaches
    /// first would attribute the spend to whichever project won a race nobody
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
        // Every slug directory is walked, always: there is no count at which the
        // walk may stop early — the next directory can always hold another copy
        // of a duplicated identifier — so the answer is only complete once the
        // listing is exhausted. Subagent transcripts sit one level below, in
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
    /// (`DataSource.settle`); before that, `narrowToWindow` drops the lives that
    /// were not written to inside the window, which is a claim this function
    /// cannot make either — it is handed one report and never told what window
    /// carried it.
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
                contested.append(ContestedSpend(sessionId: session.sessionId,
                                                slugs: slugs,
                                                tokens: session.tokens))
                continue
            }
            tokensBySlug[slug] = (tokensBySlug[slug] ?? .zero) + session.tokens
        }
        return (tokensBySlug, contested, unmatched, unmatchedSessions)
    }

    /// Drops from each contested session the lives that cannot have spent inside
    /// the window the report covers: the copies whose transcript was not written
    /// during it.
    ///
    /// **Why the window decides anything.** The gateway hands back one aggregate
    /// per session and nothing to split it by, so two lives of one session mean
    /// "nobody may have this" only for a window both lives were alive in. For a
    /// window only one life reaches, the other can have spent nothing in it:
    /// with one copy written today and the other stopped three days ago, the
    /// hour resolves and the week stays ambiguous. Same rule, two windows, two
    /// different and correct answers. What it is worth is a reading, not a
    /// constant: roughly 19–28% of the hour's spend has been refused at different
    /// moments (§2.7 keeps the readings side by side).
    ///
    /// **Only the timestamp, never the bytes.** A transcript runs to 40 MB (§2.4)
    /// and this layer never opens one; `stat(2)` and directory listings are all
    /// that is asked, on the minute-long poll rather than on the snapshot. Nor is
    /// the stamp cached: directory *listings* may be keyed by directory mtime
    /// because that moves exactly when a file appears or disappears, while
    /// appending to a file moves no directory at all (§2.2.1).
    ///
    /// **A life is more than its own transcript.** Subagents write to
    /// `<slug>/<sessionId>/subagents/agent-*.jsonl` (§2.6.3) while the gateway
    /// still reports one aggregate for the whole `session_id`, so the parent file
    /// can stand still through a long stretch of real spending — subagent files
    /// newer than their parent by up to 15 minutes are ordinary, and one that runs
    /// longer than the window would drop the working life out of the survivors.
    /// So the stamp of a life is the newest of its transcript and of the `*.jsonl`
    /// files at any depth under its `subagents/`.
    ///
    /// **Every level, and only the transcripts.** Workflow agents write their
    /// transcripts only under `subagents/workflows/wf_<id>/` (`agent-*.jsonl` and
    /// a `journal.jsonl`), not in `subagents/` itself, and the parent transcript
    /// stands still for as long as the workflow runs, so a flat listing sees
    /// nothing of a running workflow. So the walk recurses, as
    /// `ClaudeSessions.subagentEntries(in:)` does for the same reason. Every
    /// `agent-*.jsonl` has an `agent-*.meta.json` beside it; a `.json` name is
    /// skipped without a stat, and only a name that is neither a `.jsonl` nor a
    /// `.json` is asked whether it is a directory — one extra check and one
    /// listing per nested directory.
    ///
    /// **What that costs.** The subagents are consulted only when the parent
    /// transcript is already stale, and most copies of contested sessions are
    /// fresh by their parent alone, so a typical pass lists a handful of
    /// directories. The ceiling is the whole contested set gone stale at once —
    /// about 47 copies and some 930 subagent `*.jsonl`, a figure that only grows
    /// as the machine works. Measured warm with `swiftc -O` on 10 cores, that
    /// ceiling costs about 5 ms on a quiet machine (load ~6) and 12–100 ms with the
    /// machine at work (load ~44): the spread is the machine's, not the
    /// algorithm's. The actual path is a few dozen parent stats, well under a
    /// millisecond, plus those few listings. Once a minute, either way.
    ///
    /// **Both ways of being wrong point the same way.** Resuming a session touches
    /// its transcript's mtime without appending a record, so a life that spent
    /// nothing can still look alive here — and that only ever keeps the entry
    /// contested. A file that cannot be stat'ed at all (a race with a write, a
    /// copy removed since the listing) is kept for the same reason, and so is a
    /// subagent file that vanishes between the listing and the stat;
    /// `testACopyThatCannotBeStatedKeepsItsClaimOnTheWindow` holds both places.
    /// The window's start is the one the pass *asked* for rather than the one the
    /// gateway echoed: the echo is honest (§2.9), and if it ever stopped being,
    /// an unclamped start is the direction that keeps entries ambiguous.
    static func narrowToWindow(_ contested: [ContestedSpend],
                               since: Date,
                               projectsDirectory: URL = ClaudeSessions.projectsDirectory) -> [ContestedSpend] {
        let root = projectsDirectory.path
        return contested.map { entry in
            let live = entry.slugs.filter {
                wasWrittenInWindow(slug: $0, sessionId: entry.sessionId, root: root, since: since)
            }
            return ContestedSpend(sessionId: entry.sessionId, slugs: live, tokens: entry.tokens)
        }
    }

    /// Whether this life of the session was written to during the window — by the
    /// session itself or by any subagent of it.
    ///
    /// The parent transcript is asked first and answers alone whenever it is
    /// fresh, which is the common case and costs one `stat`. Only a life that
    /// looks stale is worth a walk of its `subagents/`, and the walk stops at the
    /// first subagent file inside the window, at whatever depth, rather than
    /// looking for the newest one: the question
    /// is whether *anything* was written, and the newest file is not needed to
    /// answer it.
    private static func wasWrittenInWindow(slug: String,
                                           sessionId: String,
                                           root: String,
                                           since: Date) -> Bool {
        let base = root + "/" + slug + "/" + sessionId
        guard let transcript = fileStamp(atPath: base + ".jsonl") else { return true }
        if transcript.modificationDate >= since { return true }

        // Same guard as `DataSource.worktrees`, for the same reason: a session
        // with no subagents has no such directory, and without this every stale
        // life would run a `contentsOfDirectory` that could only fail and build an
        // `NSError` for it. A cost guard, not a rule: a missing directory already
        // leaves `names` empty and falls through to `false`.
        let subagents = base + "/subagents"
        guard fileStamp(atPath: subagents) != nil else { return false }

        // Recursive because workflow agents write further down, in
        // `subagents/workflows/wf_<id>/` (`agent-*.jsonl` and a `journal.jsonl`),
        // while the parent transcript stands still for as long as the workflow
        // runs. A `.json` name is an `agent-*.meta.json` and is skipped without a
        // stat; any other name is asked whether it is a directory, and walked if
        // it is.
        func writtenUnder(_ directory: String) -> Bool {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in names {
                let path = directory + "/" + name
                if name.hasSuffix(".jsonl") {
                    guard let stamp = fileStamp(atPath: path) else { return true }
                    if stamp.modificationDate >= since { return true }
                } else if !name.hasSuffix(".json") {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                       isDirectory.boolValue,
                       writtenUnder(path) {
                        return true
                    }
                }
            }
            return false
        }
        return writtenUnder(subagents)
    }
}

/// The spend of one session whose transcript sits under more than one slug —
/// one session that was resumed in another directory.
///
/// Kept per session rather than summed by slug list: the count of such sessions
/// is one of the two numbers `--dump` reports about them, and the slugs are what
/// decides where the tokens end up.
struct ContestedSpend: Sendable, Equatable {
    /// The gateway's identifier for the session. Carried because the copies on
    /// disk are not the only record of this session there is: a *running* one
    /// also has `~/.claude/sessions/<pid>.json`, written by Claude Code and
    /// naming the directory this life of it started in. That file is outside the
    /// transcript tree, so nothing below `DataSource` can find it — the id is
    /// what lets the layer that knows about live sessions ask it (`settle`).
    let sessionId: String
    /// The slug directories whose copy could have spent inside the window this
    /// report covers, sorted.
    ///
    /// `fold` puts every copy here — two or more, since one is not contested and
    /// none is unmatched — and `narrowToWindow` then drops the ones that were not
    /// written to during the window at all, in their transcript or in any of their
    /// subagents'. So this can come out at one, or at
    /// none, and it is still not folded onto a row here: whether one surviving
    /// claim is an answer needs the project list and the live sessions, and both
    /// live a layer up (`DataSource.settle`).
    let slugs: [String]
    let tokens: TokenCounts
}
