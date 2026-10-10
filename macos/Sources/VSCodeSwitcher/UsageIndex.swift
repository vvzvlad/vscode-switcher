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
    /// per session and nothing to split it by, so two lives of one session used to
    /// mean "nobody may have this" for every window alike. That is right for a
    /// window both lives were alive in and wrong for one only a single life
    /// reaches. The live pair on this machine (2026-08-27) is exactly that:
    /// `8fa4e946-…` sits under the slugs of `hammerola` and `cad_snapshot_hub` —
    /// two real projects, both in the scan roots — and the `hammerola` copy was
    /// 16.5 MB being written at 20:01 that day while the `cad_snapshot_hub` copy
    /// stopped at 6.1 MB on 2026-08-24 17:20. Over the sliding hour that second
    /// life is days out of the window and can have spent nothing in it; over the
    /// week both lives are inside it and the aggregate genuinely holds spend from
    /// both. Same rule, two windows, two different and correct answers — the hour
    /// resolves and the week stays ambiguous.
    ///
    /// What it is worth is a *sliding* hour, so it is a reading and not a
    /// constant, and the readings are far apart: 11.95M of 42.53M refused (28.1%
    /// of the hour) at one moment of 2026-08-27, 17.75M of 64.30M (27.6%) at
    /// another, and 0.98M of 5.12M (19.1%) on a quiet night hour of 2026-08-28.
    /// §2.7 keeps them side by side. The absolute moves by more than an order of
    /// magnitude with the machine's own load; the session behind it is
    /// `8fa4e946-…` every time, and it is the largest single spender on the
    /// machine.
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
    /// can stand still through a long stretch of real spending. This is a live
    /// table, and what moves is the population as well as the finding — one and the
    /// same sample across two passes is what a moving table cannot deliver, and is
    /// how this was written down. Four passes: 2026-08-27 and 2026-08-28 over 609
    /// session transcripts with 344 `subagents/` directories found 10 and then 6
    /// with a subagent file newer than their parent, the largest gap 917.5 s
    /// (15.29 min) and 124.2 s; recounts on 2026-08-28 saw 613 transcripts and 345
    /// directories both times, 5 such sessions, a gap of 355.8 s (5.93 min) at
    /// 05:44 and 330.2 s at 05:58 — fourteen minutes moved the population by
    /// nothing, a day moved it by four files. All
    /// are under the hour, so nothing is
    /// misattributed today — which is luck, not a property: a subagent that runs
    /// longer than the window would drop the working life out of the survivors and
    /// leave a rival copy that a resume had merely touched. So the stamp of a life
    /// is the newest of its transcript and of the `*.jsonl` files at any depth
    /// under its `subagents/`.
    ///
    /// **Every level, and only the transcripts.** The walk used to be one flat
    /// listing, and why is kept as history: counted 2026-08-28 over that pass's
    /// 344 `subagents/` directories, 4483 `agent-*.jsonl`, one `agent-*.meta.json`
    /// beside every one of them, and 7 nested `workflows/` directories holding
    /// 1003 files between them, with **0** sessions in which a file under one of
    /// those nested directories was newer than both the parent transcript and
    /// every flat `*.jsonl`. That no longer describes the machine. Workflow agents
    /// write their transcripts only under `subagents/workflows/wf_<id>/`
    /// (`agent-*.jsonl` and a `journal.jsonl`), not in `subagents/` itself, and
    /// the parent transcript stands still for as long as the workflow runs.
    /// Counted 2026-10-10 21:19 over 1045 session transcripts and 576
    /// `subagents/` directories: 17 hold a `workflows/`, 2 of them hold no flat
    /// `*.jsonl` at all, and the 52 `wf_<id>/` directories hold 1237 `*.jsonl`
    /// (1185 `agent-*.jsonl`, 52 `journal.jsonl`). One session had a nested file
    /// newer than the parent and every flat `*.jsonl` — a running workflow,
    /// whose `subagents/` holds `workflows/` and nothing else — by 92.6 s at
    /// 21:16 and 299.3 s at 21:19: the gap grows with the workflow, and a flat
    /// listing sees nothing of it. So the walk recurses, as
    /// `ClaudeSessions.subagentEntries(in:)` already does for the same reason.
    /// The doubling of stats the flat loop refused is still not paid: a `.json`
    /// name is skipped without a stat, and only a name that is neither a `.jsonl`
    /// nor a `.json` is asked whether it is a directory — one extra check and one
    /// listing per directory, 17 `workflows/` and 52 `wf_<id>/` on the whole machine
    /// that day.
    ///
    /// **What that costs.** The subagents are consulted only when the parent
    /// transcript is already stale, which is the whole difference: of the copies of
    /// contested sessions the gateway actually reported, 27 of 31, then 26 of 29,
    /// then 26 of 29 again on a third pass (2026-08-28), were fresh by their parent
    /// alone over the week, and 1 of 2 over the hour all three times — so today's
    /// week pass listed 3 directories holding 15 subagent files between them, and
    /// the hour's listed 1 holding 47 files. The ceiling is the whole contested set
    /// gone stale at once — all 47 copies (the same number as those files, by
    /// coincidence), 42 of which have a `subagents/` directory holding 928 `*.jsonl`
    /// between them and climbing — a floor with a direction, not a pair of bounds,
    /// because the count only grows as the machine works, and a closed range written
    /// here goes out of date the same day it is dated. `*.jsonl` is the quantity named on purpose: it is
    /// what the loop stats, and the directories themselves hold twice as much —
    /// 1882 entries at both readings of 2026-08-28, one `.meta.json` beside every
    /// transcript and nothing else, which is the doubling the paragraph above
    /// declines to pay for. A live table: 928…930 counted twice twenty minutes
    /// apart, 936 earlier on 2026-08-28, 941 at 05:44 and again at 05:58 that day,
    /// the 47 and the 42 reproducing exactly every time.
    ///
    /// **And that ceiling is a reading, not a constant: its condition is what else
    /// the machine is doing.** 20 warm passes each, `swiftc -O`, with `getloadavg`
    /// read at every pass, 10 cores. Quiet machine, two runs at load 6.1 and 6.9:
    /// 4.74…7.21 ms and 4.68…6.73 ms, medians 5.39 and 5.21, of which the listings
    /// are 3.52…5.55 ms and every stat together — 47 parents and 930 subagent
    /// files — 1.13…1.62 ms. The same 20 passes
    /// with the machine at work, load 44.4: 12.1…100.5 ms, median 23.5, listings
    /// 8.8…79.1 and stats 3.1…38.6. That spread is the machine's and not the
    /// algorithm's — which is exactly why the first range was written down here
    /// without its condition and then failed to reproduce for a reviewer measuring
    /// the next day. The actual path is 29 parent stats, 0.038…0.072 ms quiet and
    /// 0.100…0.254 ms busy, plus those few listings. Once a minute, either way.
    ///
    /// **Both ways of being wrong point the same way.** Resuming a session touches
    /// its transcript's mtime without appending a record, so a life that spent
    /// nothing can still look alive here — and that only ever keeps the entry
    /// contested, which is the behaviour it had before this existed. A file that
    /// cannot be stat'ed at all (a race with a write, a copy removed since the
    /// listing) is kept for the same reason, and so is a subagent file that
    /// vanishes between the listing and the stat. That rule used to live in this
    /// comment and nowhere else, and is now held by
    /// `testACopyThatCannotBeStatedKeepsItsClaimOnTheWindow` — **in both of the
    /// places it is written**, which took two goes: the test held the parent
    /// transcript's `else { return true }` and left the subagent file's, six lines
    /// below, exactly as free as the whole rule had been. Measured all four ways
    /// (2026-08-28, suite of 639): with the test deleted, flipping either failure
    /// to `false` leaves 638 of 638 green; with it present, flipping the parent's
    /// takes down 1 test case and 1 assertion, and flipping the subagent's takes
    /// down the same case and a different assertion, also 1. (Recorded here before
    /// as 2 assertions for the parent's half — the case's other assertions pass
    /// under that mutation.) The window's start is
    /// the one the pass *asked* for rather than the one the gateway echoed: the
    /// echo is honest — zero drift on four windows, §2.9 — and if it ever stopped
    /// being, an unclamped start is the direction that keeps entries ambiguous.
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
        // `NSError` for it. Cheap today — only stale copies reach here, and 5 of
        // the 47 contested copies have no `subagents/` (2026-08-28, the same live
        // table as the ceiling above) — but this is the pattern the
        // module already documents as required. Deleting it takes down 0 of 639
        // tests, and that is what it should do: a missing directory already left
        // `names` empty and fell through to `false`, so this is a cost guard and
        // not a rule — the rule below it is the one held by a test.
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
