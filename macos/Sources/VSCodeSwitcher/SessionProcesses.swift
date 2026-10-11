import Darwin
import Foundation

/// The processes a Claude Code session is running, how much CPU they are
/// burning right now, and how many of them the parent chain has lost.
///
/// A session's work is not one process. The `claude` binary spawns MCP servers,
/// shells, compilers and language servers, and the CPU the user cares about is
/// the sum over all of them. Two questions have to be answered before that sum
/// can be taken: which processes belong to which session, and what a *rate*
/// means when the only thing the kernel reports is a cumulative counter.
///
/// **Ownership.** Two independent signals, in this order (SPEC §2.8):
///
/// 1. The parent chain. Walk `ppid` upward; the first pid that is a live session
///    owns the process. Authoritative — a process really is a descendant.
/// 2. `CLAUDE_PID` in the environment, and only for what the chain could not
///    place. Claude Code puts it into every process it spawns, and unlike the
///    chain it survives the parent exiting: an orphan reparents to pid 1, which
///    tells nobody anything, while its environment still names the session that
///    started it.
///
/// The marker is trusted **only when the pid it names is a live session**. It is
/// inherited sideways and goes stale: the `claude` binary itself carries the
/// marker of whatever launched VSCode, and most of the markers on this machine
/// name something that is not a live session at all — 120 of the 136 carried,
/// against 24 live sessions, in one census. Those are not orphans, they are
/// inherited junk, and a marker naming a dead or unknown pid is ignored
/// outright.
///
/// When both signals speak and disagree, the chain wins. Zero such cases on live
/// data — the rule is written down so that it is a decision rather than an
/// accident of the order the code happens to ask in.
///
/// **Rate.** `(cpuNanos now − cpuNanos before) / (elapsed)`, as a percentage of
/// one core, which is the convention `top` prints. Above 100 is legitimate: a
/// process with four busy threads is burning four cores.
enum SessionProcesses {

    // MARK: - Values

    /// A process, told apart from a later one that reused its pid.
    ///
    /// The start time is what defeats the reuse. macOS hands pids back out, and
    /// anything remembered against the bare number — a cached environment, a
    /// previous CPU counter — would answer for a process that no longer exists.
    struct Key: Hashable, Sendable {
        var pid: Int32
        /// `pbi_start_tvsec`: whole seconds, which is all `proc_bsdinfo` offers.
        var startTime: UInt64
    }

    /// One row of the process table, as one sweep reads it.
    struct Sampled: Sendable {
        var pid: Int32
        var startTime: UInt64
        var counters: Counters

        var key: Key { Key(pid: pid, startTime: startTime) }
    }

    /// The cumulative CPU one process accounts for, as one sweep reads it.
    ///
    /// Both fields are mach absolute time units converted to nanoseconds by
    /// `cpuNanos(of:)` — the kernel does not report them in nanoseconds
    /// whatever the `_time` in their names says. See `timebase`.
    struct Counters: Sendable, Equatable {
        var ppid: Int32
        /// `ri_user_time + ri_system_time`: what this process burned itself.
        var own: UInt64
        /// `ri_child_user_time + ri_child_system_time`: what its reaped
        /// children burned, folded in at the moment each one is reaped — and
        /// not just the child, the child's **whole subtree**: a grandchild
        /// burning 1.0 s under a child burning 0.3 s lands 1.24 s here at the
        /// moment the child is reaped, so a reaped child hands over its own
        /// `ri_child_*` along with its `ri_user_time`.
        var child: UInt64

        /// Everything this line of the table accounts for. The quantity the
        /// rate is a difference of.
        var total: UInt64 { own &+ child }
    }

    /// What attribution needs to know about one process.
    ///
    /// No start time here: attribution is a question about the shape of the
    /// process tree and about one environment variable, and the start time
    /// answers neither. It belongs to `Key`, where reuse is the question.
    struct Facts: Sendable, Equatable {
        var pid: Int32
        var ppid: Int32
        /// `CLAUDE_PID` from the process's environment, `nil` when there is no
        /// marker to hand over.
        ///
        /// `Marker.absent` and `Marker.withheld` both arrive here as `nil`, and
        /// deliberately: attribution has nothing different to *do* with a
        /// process whose environment was kept from it. Distinguishing them
        /// where it changes no answer would be a branch that cannot execute.
        /// The distinction is real and is kept where it is read — at the parser,
        /// which is what says how much of the machine the marker can see at all
        /// (SPEC §2.8).
        var marker: Int32?
    }

    /// Who owns what, once the whole table has been walked.
    struct Attribution: Sendable, Equatable {
        /// The session pid every attributed process belongs to. A session's own
        /// process maps to itself, so its CPU counts towards its own total.
        var ownerByPID: [Int32: Int32]
        /// Per session, how many of its processes the *marker* had to claim
        /// because the chain had already lost them.
        var orphansBySessionPID: [Int32: Int]
    }

    /// What one pass hands the row assembly.
    struct Load: Sendable {
        /// Percent of one core, summed over every process attributed to the
        /// session. Missing when there is no rate to report at all — the first
        /// pass after launch, or a gap too long to describe as "now".
        var cpuPercentBySessionPID: [Int32: Double]
        var orphansBySessionPID: [Int32: Int]
    }

    // MARK: - Attribution

    /// Chain first, marker second, chain wins.
    ///
    /// Pure, and asked directly by its tests: through a sweep of the live
    /// machine a wrong answer surfaces as a percentage that looks a bit off,
    /// which is also what a dozen unrelated mistakes look like.
    static func attribute(_ processes: [Facts], sessionPIDs: Set<Int32>) -> Attribution {
        var parents: [Int32: Int32] = [:]
        parents.reserveCapacity(processes.count)
        for process in processes { parents[process.pid] = process.ppid }

        let ancestors = sessionAncestors(of: sessionPIDs, parents: parents)

        var owners: [Int32: Int32] = [:]
        var orphans: [Int32: Int] = [:]
        for process in processes {
            if let owner = chainOwner(of: process.pid, parents: parents, sessionPIDs: sessionPIDs) {
                // The marker is not even consulted. A descendant of session A
                // that carries a marker naming session B is a process A spawned
                // out of an environment B had already polluted — the chain is
                // the fact, the marker is the rumour.
                owners[process.pid] = owner
                continue
            }
            // Nothing but a live session makes a marker mean anything. This is
            // the whole of the rule that keeps the 120 inherited-junk markers
            // on this machine out of the orphan counts.
            guard let marker = process.marker, sessionPIDs.contains(marker) else { continue }
            // And still not enough on its own: everything the editor runs hangs
            // off the same tree the sessions hang off, and carries whatever
            // `CLAUDE_PID` was in the environment that launched the editor.
            // Those are not orphans — they never lost a parent (SPEC §2.8).
            //
            // Only a walk that got all the way to launchd may hand the marker
            // its chance. A walk that ran out of links proves nothing, and
            // treating it as "detached" is how a live parent gets reported as a
            // dead one: `/usr/bin/login` is root-owned and refuses both calls
            // while the login shell under it answers both, so every Terminal.app
            // tab has a hole in it exactly there (SPEC §2.8).
            guard walkUp(from: process.pid, parents: parents, to: ancestors) == .reachedTop else { continue }
            owners[process.pid] = marker
            orphans[marker, default: 0] += 1
        }
        return Attribution(ownerByPID: owners, orphansBySessionPID: orphans)
    }

    /// Everything strictly above a live session, up to but not including
    /// launchd: the editor's helper processes, the pty host, the shell the
    /// session was typed into, and the editor itself.
    ///
    /// This is what tells the editor's own tree apart from a detached orphan.
    /// An orphan has lost its parent and been handed to pid 1, so its chain is
    /// itself and then launchd — nothing above it to match. A tsserver, a
    /// renderer or a second `claude` started in a neighbouring terminal all
    /// still have their parents, and every one of those chains runs through
    /// something on this list.
    ///
    /// launchd is excluded because it is above *everything*: including it would
    /// refuse the marker to every process on the machine, which is a rule that
    /// says nothing.
    static func sessionAncestors(of sessionPIDs: Set<Int32>, parents: [Int32: Int32]) -> Set<Int32> {
        var result = Set<Int32>()
        for session in sessionPIDs {
            guard var current = parents[session] else { continue }
            // `inserted == false` means this branch has already been walked, so
            // it also serves as the cycle guard the parents table needs.
            while current > 1, result.insert(current).inserted {
                guard let parent = parents[current] else { break }
                current = parent
            }
        }
        return result
    }

    /// The nearest live session at or above a process, or `nil` when there is
    /// none to be found — whether because the walk reached launchd or because
    /// it ran out of links.
    ///
    /// The two are the same answer *here*: either way no session owns the
    /// process by descent. They are not the same answer for the marker, which
    /// is why the walk itself reports them apart.
    static func chainOwner(of pid: Int32,
                           parents: [Int32: Int32],
                           sessionPIDs: Set<Int32>) -> Int32? {
        guard case .found(let owner) = walkUp(from: pid, parents: parents, to: sessionPIDs) else {
            return nil
        }
        return owner
    }

    /// What a walk up the parent chain ran into.
    ///
    /// Three answers, not two, and the third is the point. "Reached launchd
    /// without a match" and "the table has no link for this parent" both mean
    /// "no match", and folding them together is what let a severed chain
    /// manufacture an orphan under a living parent (SPEC §2.8).
    enum ChainWalk: Sendable, Equatable {
        /// A pid from the wanted set, at or above the process.
        case found(Int32)
        /// launchd, with nothing wanted on the way. The process really has
        /// nothing above it.
        case reachedTop
        /// A link the sweep does not have, or a cycle in what it does have.
        /// The chain says nothing at all about this process.
        case broken
    }

    /// Walks from `pid` up the parent links, looking for `wanted`.
    ///
    /// The process itself is asked first, so a session's own pid resolves to
    /// itself. The visited set is not decoration: `ppid` comes from a table read
    /// one process at a time while the machine keeps forking, so a snapshot of
    /// it is not guaranteed to be a tree, and a cycle in it would spin here
    /// forever inside a function that runs once or twice a second. A cycle is
    /// reported as `broken`, which is what it is: a chain that leads nowhere.
    static func walkUp(from pid: Int32,
                       parents: [Int32: Int32],
                       to wanted: Set<Int32>) -> ChainWalk {
        var seen = Set<Int32>()
        var current = pid
        // `> 1` stops at launchd, which adopts every orphan and owns nothing.
        while current > 1, seen.insert(current).inserted {
            if wanted.contains(current) { return .found(current) }
            guard let parent = parents[current] else { return .broken }
            current = parent
        }
        return current > 1 ? .broken : .reachedTop
    }

    // MARK: - Rates

    /// The longest gap between two sweeps that still describes "right now".
    ///
    /// The snapshot is rebuilt every one or two seconds (`SnapshotStore`), so a
    /// gap this long means the sampling stopped: the timer was starved, or the
    /// process was suspended. What comes out of such a pair is a *mean over the
    /// gap*, and the row promises the opposite — the number is read as "what is
    /// this window doing to my machine at this moment", and an average over a
    /// minute of it is a different quantity wearing the same label. Better a
    /// blank for one tick than a figure that means something else.
    ///
    /// Ten of the slowest ticks the snapshot is rebuilt on, so that an ordinary
    /// slow pass — the assembly spends 40–180 ms on disk (§6) — never blanks the
    /// column. Taken from `SnapshotStore.idleInterval` rather than written down,
    /// because a threshold expressed in ticks has to move when the tick does.
    ///
    /// **This end blanks the column and the other end holds it, and the
    /// asymmetry is deliberate.** A gap too short has a fresh figure to keep —
    /// one from a second ago, which is what "now" means — and keeping the
    /// baseline with it lets the gap grow into one worth dividing. A gap too
    /// long has nothing of the kind: the only figure to hold would be older than
    /// this threshold, which is the definition of not-now, and the pair itself
    /// is a mean over the stall rather than a rate. So the pass re-bases and
    /// reports nothing, and the tick after it — 1–2 s later — reports again.
    /// That includes the pass `SnapshotStore.setPanelVisible(_:)` makes, so a
    /// panel opened after a stall can show a blank column for one tick. It is
    /// the right blank: the alternative is a number describing a minute the user
    /// is not asking about, presented as this instant.
    ///
    /// `nonisolated` for the reason `timebase` is.
    nonisolated static let staleSampleSeconds: TimeInterval = SnapshotStore.idleInterval * 10

    /// The shortest gap that can be divided into a rate at all.
    ///
    /// The ceiling above guards the pair that is too old to mean "now". This
    /// guards the pair that is too *close*, which is the commoner accident and
    /// the worse one, because it happens exactly when the panel is being looked
    /// at: `SnapshotStore.setPanelVisible(_:)` rebuilds the snapshot the instant
    /// the panel slides out, `apply` rebuilds again straight away when one was
    /// requested mid-build, and the file-system watcher debounces at 0.15 s
    /// while the state hook renames a file in `~/.claude/window-status` on every
    /// transition. None of those is the timer, and none of them waits for it.
    ///
    /// A rate over such a gap is not a worse average, it is noise: measured
    /// against a process held at a steady 30% duty cycle, 25 probes per window
    /// — 0.05 s reads sd 28.8 (min 0.0, max 59.6), 0.15 s sd 9.6, 0.50 s sd 1.5,
    /// 1.00 s sd 0.7, 2.00 s sd 0.7. So the very moment the panel exists for
    /// would show a steady 28% as anything from nothing to twice itself.
    ///
    /// Half the panel's own tick, and derived from it rather than written down
    /// for the reason the ceiling is. The floor has to sit *below* the fastest
    /// legitimate tick and *above* the fastest illegitimate refresh, and that is
    /// the whole of the choice: `activeInterval` is 1 s and the watcher debounce
    /// is 0.15 s, so 0.5 s rejects every extra refresh and never rejects the
    /// timer. Taking the floor at the tick itself instead would put it *on* the
    /// tick, where a few milliseconds of jitter make it reject every other one.
    ///
    /// Too short is not a blank, it is a **hold**: `ProcessSampler` keeps the
    /// last rate it computed and keeps its baseline too, so the gap goes on
    /// growing until it is long enough to divide. A figure from a second ago is
    /// honest; one computed from 50 ms is not.
    nonisolated static let minimumSampleSeconds: TimeInterval = SnapshotStore.activeInterval / 2

    /// CPU already reported for **one** process that has left the table, waiting
    /// for the growth that will carry it into its heir's `ri_child_*`.
    ///
    /// The debt is what makes the rate right in the two cases where a process
    /// leaves the table *before* its counter arrives anywhere (SPEC §2.8), and
    /// both of them happen on this machine:
    ///
    /// - a **zombie**. A process that has exited and not yet been waited for is
    ///   still in `proc_listallpids` and still answers `proc_pid_rusage`, but
    ///   `PROC_PIDTBSDINFO` refuses it, so the sweep drops the row. It looks
    ///   like a disappearance, and the reap it is waiting for may be a tick or
    ///   several away — a shell blocked in `wait4` reaps at once, `node` busy
    ///   parsing a large tool result does not;
    /// - a **reparented descendant**. When the parent goes first, the child is
    ///   handed to launchd and reaped there; its counter leaves the tree for
    ///   good, and nothing above it ever gains a nanosecond of it.
    ///
    /// **One record per debtor, not one pool per heir**, and the ledger is keyed
    /// by the debtor for that reason. A pool cannot carry an age: every addition
    /// has to re-date it, and the process that loses a descendant on nearly every
    /// pass is precisely `claude` — a node process spawning the next `Bash` — so
    /// its pool would be re-dated for ever and an entry nothing can settle would
    /// never age out of it. Per debtor each debt ages from the pass that wrote it
    /// down, and none of them can be settled beyond its own amount.
    struct Debt: Sendable, Equatable {
        /// Nanoseconds owed: the last-seen total of the process this debt is for,
        /// less whatever of it has already been settled.
        var nanos: UInt64
        /// Seconds since the pass that wrote it down. Accumulated from the gap
        /// each measured pass reports, so that a pass too short to divide —
        /// which computes no rate at all — does not age the ledger either.
        var age: TimeInterval
        /// The survivor whose `ri_child_*` growth this debt is settled against:
        /// the parent the debtor was last seen under, or — when that parent went
        /// in the same gap — whatever that parent's own counters travel to
        /// (`heir(of:lastSeen:byPID:survivors:)`).
        var heir: Key
    }

    /// What one measured pair of sweeps says.
    struct Rates: Sendable, Equatable {
        /// Percent of one core, per process.
        var percentByKey: [Key: Double]
        /// The ledger as this pass leaves it, keyed by the **debtor** — the
        /// process that left the table — with the survivor it is charged to
        /// inside each entry.
        var debts: [Key: Debt]
        /// Debts this pass gave up on: aged past `debtLifetimeSeconds`, or the
        /// **heir** they were charged to left the table itself and the walk
        /// found no survivor to re-address them to.
        ///
        /// A *debtor* leaving the table is what writes a debt down, not what
        /// loses one, and the case that has nowhere to be addressed never
        /// reaches this counter at all: a vanishing whose walk comes back empty
        /// is dropped before it becomes a debt
        /// (`heir(of:lastSeen:byPID:survivors:)`). Only what was written down
        /// can be given up on.
        ///
        /// Nothing on the screen says a debt went unsettled, so the count is
        /// carried out to where a test can ask (`ProcessSampler.PassStats`).
        var expired: Int
    }

    /// How long a debt waits for the growth that settles it.
    ///
    /// **The floor is derived; the equality is a measurement and a price.** The
    /// only event that can settle a debt is a pass — growth is a difference
    /// between two sweeps — and a legitimate pass may arrive as late as
    /// `staleSampleSeconds`, so the lifetime cannot be *shorter* than that gap:
    /// anything shorter throws debts away before the one event able to
    /// discharge them. Nothing proves equality: how long a process stays
    /// unreaped is up to when its parent chooses to call `wait`.
    ///
    /// What holds the upper end is a measurement: driving this function once a
    /// second for 200 passes while agents worked and the suite built gave 474
    /// debts, 755.135 core-seconds owed; 464 settled on the very pass that
    /// recorded them, 4 waited one pass, 2 two, 2 three, 1 four — and 1 waited
    /// 20, which is this constant exactly. A shorter lifetime would throw away
    /// debts that do settle.
    ///
    /// And an unsettled debt is indistinguishable from a pending one, so it
    /// spends itself against whatever genuine growth arrives next: holding it
    /// longer holds that suppression longer.
    ///
    /// Equality also makes one guarantee cheap to state: a debt always survives
    /// at least one measured pass, whatever the pass costs.
    ///
    /// **Expiry has a price of its own, and it is the defect this whole
    /// mechanism exists to prevent.** Giving up on a debt does not mean the
    /// counter behind it is never coming — it means the deadline came first. If
    /// the reap lands afterwards, nothing is left to take the already-reported
    /// part off, and the entire forgiven amount is charged to one tick: a spike
    /// of exactly what was written off, which for a `swift build` is the 60000%
    /// §2.8 opens with. So neither direction is free — too short spikes, too
    /// long suppresses — and `ProcessSampler.PassStats.expiredDebts` is the only
    /// place in the system that records the trade happening at all.
    ///
    /// `nonisolated` for the reason `timebase` is.
    nonisolated static let debtLifetimeSeconds: TimeInterval = staleSampleSeconds

    /// Per-process rates from two sweeps, or `nil` when the pair cannot be made
    /// into one.
    ///
    /// Keyed by `Key` rather than by pid throughout: a pid that came back is a
    /// different process with a counter of its own, and subtracting the old
    /// one's total from it would report a large negative — or, once clamped, a
    /// wrong zero.
    ///
    /// **A process the sweep never saw twice still burned CPU, and for an agent
    /// that is most of it.** Every `Bash` call is a fresh `rg`, `git`, `cc` or
    /// `node` living a fraction of a second, and asking only the processes
    /// present in both sweeps misses all of them: against a shell spawning and
    /// reaping a child every 0.15 s, that reports 0.3% while the reaped children
    /// burn 63.6–86.9% of a core — and 0.3% is under the 1% the row draws
    /// anything at all above (§3.1).
    ///
    /// Three kinds of process, then, and the sum is over all three:
    ///
    /// 1. **Present in both sweeps.** Its own delta, plus the growth of its
    ///    `ri_child_*` less whatever of that growth settles a debt.
    /// 2. **New in this sweep.** Its whole counter: it did not exist at the
    ///    previous one, so every nanosecond on it was burned inside the gap.
    /// 3. **Gone since the previous sweep.** At the moment it is reaped its
    ///    whole total lands in its parent's `ri_child_*` — the part already
    ///    reported by earlier passes included. That part has to come back off,
    ///    or a `swift build` that ran ten minutes and then exited would put
    ///    600 s of CPU inside one 1 s tick, a spike of some 60000%. What is owed
    ///    is the vanished process's last-seen **total**, own and child both,
    ///    because `ri_child_*` folds in the whole subtree.
    ///
    /// **The third kind is written down, not deducted.** Deducting it the moment
    /// the row disappears assumes the counter has already travelled, and it has
    /// not always: a zombie is out of the sweep for as long as its parent takes
    /// to call `wait`, and a descendant reparented to launchd never travels at
    /// all. Deducted then and there, the first case floors the tick to zero and
    /// then spikes by the whole lifetime when the reap really lands, and the
    /// second takes already-reported time off a session that gained nothing —
    /// both measured on this machine (SPEC §2.8). So the total is recorded as a
    /// debt against whoever stands to inherit it, and each pass settles as much
    /// of the debt as the growth that actually arrived will cover:
    ///
    ///     settled = min(debt, childDelta)   — per debt, oldest first
    ///     burned  = ownDelta + childDelta − Σ settled
    ///
    /// which is exact in the ordinary case (the reap lands in the same gap as
    /// the disappearance, `childDelta` covers the whole lifetime and the debt
    /// covers the already-reported part of it) and defers in the zombie case (no
    /// growth, nothing settled, the debt waits for the pass where the reap
    /// lands).
    ///
    /// **The launchd case is why the debt goes to the last-seen parent.** The
    /// reparented process itself never settles anything, but the process its
    /// debt would be charged to does see growth: `claude` is a node process that
    /// reaps the next `Bash` on nearly every tick, so a debt its own counter
    /// will never settle would be settled by somebody else's. So the debt is
    /// addressed to the debtor's **last-seen parent** rather than to the first
    /// surviving ancestor — a process last seen under pid 1 is written down
    /// nowhere at all, because the counter had already left the tree while the
    /// sweep was still watching.
    ///
    /// Reparenting is visible in `ppid`, and that is what makes the rule work:
    /// when a parent dies the next sweep sees its children under pid 1. What is
    /// left unresolved is a parent and its child going in the **same** gap, where
    /// no sweep saw the reparenting: from the table `sh -c 'cc …'` (both out
    /// inside one tick, the compiler's counter travelling up through the shell)
    /// and "the shell went first and launchd took the compiler" are the same
    /// picture. The debt is rolled up in that case, because the spike is the
    /// worse of the two errors and the first shape is the commoner one by far —
    /// §2.8 measures both.
    ///
    /// **Nothing here can come out below zero**, and that is a property rather
    /// than a clamp: `settled` is bounded by `childDelta`, so every process's
    /// figure is a difference of two non-decreasing counters plus a non-negative
    /// remainder. `testSettlementCannotOutrunTheGrowthItSettles` holds that
    /// invariant.
    static func rates(previous: [Key: Counters],
                      current: [Key: Counters],
                      elapsed: TimeInterval,
                      debts: [Key: Debt]) -> Rates? {
        guard elapsed >= minimumSampleSeconds, elapsed <= staleSampleSeconds else { return nil }

        // Survivors only, and by the whole key: the heir of a vanished process
        // has to be a process that was *already there* to be its ancestor. A pid
        // that has been handed to somebody new in this gap is not that process,
        // and charging it the debt would leave a stranger holding a suppression
        // it can never work off.
        var survivors = Set<Key>()
        survivors.reserveCapacity(current.count)
        for key in current.keys where previous[key] != nil { survivors.insert(key) }

        // The previous sweep indexed by pid, so that a `ppid` — which is a bare
        // number — can be resolved to the whole key of whoever held it then.
        var lastSeenByPID: [Int32: Key] = [:]
        lastSeenByPID.reserveCapacity(previous.count)
        for key in previous.keys { lastSeenByPID[key.pid] = key }

        var expired = 0
        var owed: [Key: Debt] = [:]
        owed.reserveCapacity(debts.count + 8)

        // Carry the ledger over the gap just measured.
        for (debtor, debt) in debts {
            let age = debt.age + elapsed
            guard age <= debtLifetimeSeconds else { expired += 1; continue }
            if survivors.contains(debt.heir) {
                owed[debtor] = Debt(nanos: debt.nanos, age: age, heir: debt.heir)
                continue
            }
            // The heir has left the table itself, and what it was owed travels
            // with its own counters rather than being forgiven here. Forgiving
            // it is the spike back: the heir's whole final total — the debt
            // included, if the reap it was waiting for landed before it died —
            // arrives at the *next* survivor, which then has nothing left to
            // take the already-reported part off (SPEC §2.8).
            guard let next = heir(of: debt.heir, lastSeen: previous,
                                  byPID: lastSeenByPID, survivors: survivors)
            else { expired += 1; continue }
            owed[debtor] = Debt(nanos: debt.nanos, age: age, heir: next)
        }

        // What this pass's disappearances leave behind, each addressed to the
        // parent it was last seen under. No collision with the loop above: a
        // process appears in `previous` exactly on the pass after it went, and
        // it joins the ledger on that same pass, never before it.
        for (debtor, before) in previous where current[debtor] == nil {
            // A process that burned nothing owes nothing, and an entry of zero
            // is not harmless bookkeeping: it would count itself among
            // `PassStats.openDebts` and, if its heir happened to see no growth
            // for the whole lifetime, among `expiredDebts` too — which are the
            // statistics `debtLifetimeSeconds` is argued from. Rare rather than
            // impossible, so it is refused here rather than tolerated downstream.
            guard before.total > 0 else { continue }
            guard let addressee = heir(of: debtor, lastSeen: previous,
                                       byPID: lastSeenByPID, survivors: survivors)
            else { continue }
            owed[debtor] = Debt(nanos: before.total, age: 0, heir: addressee)
        }

        // The ledger the other way round, so that a survivor's growth meets only
        // the debts actually addressed to it.
        var byHeir: [Key: [(debtor: Key, debt: Debt)]] = [:]
        for (debtor, debt) in owed { byHeir[debt.heir, default: []].append((debtor, debt)) }

        var percent: [Key: Double] = [:]
        percent.reserveCapacity(current.count)
        for (key, now) in current {
            guard let before = previous[key] else {
                percent[key] = Double(now.total) / 1e9 / elapsed * 100
                continue
            }
            // A counter that went backwards is not a process that unburned CPU;
            // it is a reading from something else. Dropped rather than clamped,
            // and its debts are left where they are: the pass has nothing to say
            // about this process, settlement included.
            //
            // Asked of **each** counter rather than of the total, which is what
            // makes the arithmetic below unable to go negative rather than
            // merely unlikely to: a total that has not fallen still allows one
            // half of it to have fallen, and a negative `ownDelta` would sink
            // the sum however the settlement is bounded.
            guard now.own >= before.own, now.child >= before.child else { continue }
            let own = now.own - before.own
            let child = now.child - before.child
            // Bounded by the growth, not by the debts: this is the whole of why
            // the figure cannot come out below zero. `child - settled` is a
            // `UInt64` subtraction and would trap if it could underflow.
            let settled = settle(growth: child, against: byHeir[key] ?? [], owed: &owed)
            // "Measured, and burned nothing" is `0` — a different answer from
            // "not measured", which is the absence, and the row draws the two
            // differently (§3.1).
            percent[key] = Double(own + (child - settled)) / 1e9 / elapsed * 100
        }
        return Rates(percentByKey: percent, debts: owed, expired: expired)
    }

    /// Spends one survivor's `ri_child_*` growth on the debts addressed to it,
    /// and answers how much of the growth went.
    ///
    /// **Oldest first.** The order only decides anything when the growth does not
    /// cover everything owed, and in that case nothing in the table says which
    /// reap arrived — so the tie-break is what it costs to be wrong. A debt given
    /// up on is charged in full the moment its counter finally lands
    /// (`debtLifetimeSeconds`), so the debt nearest its deadline is the one worth
    /// clearing first.
    ///
    /// Equal ages break on the debtor's key, and that is not decoration:
    /// dictionary order in Swift is not stable, so without it two runs over the
    /// same ledger would leave different debts standing.
    ///
    /// Never more than a debt's own amount, and never more than the growth: the
    /// first is what keeps one debtor's reap from settling another's, the second
    /// is what keeps the caller's unsigned subtraction from trapping.
    ///
    /// **The loop stops when the growth runs out, not when `take == 0`.** `take`
    /// is `min(debt, left)`, so it is zero for two unrelated reasons — the growth
    /// has gone, or *this* debt is zero — and stopping on the second would
    /// abandon every debt behind it. A zero debt sorts to the front of its heir's
    /// bucket (ties on age break on the lower pid), so the debt behind it is the
    /// real one. Asking `left` instead settles the zero debt for nothing —
    /// `take == entry.debt.nanos` clears it — and carries on. `rates` declines
    /// to write a zero debt down in the first place, so this is the second of
    /// two guards rather than the only one.
    private static func settle(growth: UInt64,
                               against debts: [(debtor: Key, debt: Debt)],
                               owed: inout [Key: Debt]) -> UInt64 {
        var left = growth
        for entry in debts.sorted(by: olderFirst) {
            if left == 0 { break }
            let take = min(entry.debt.nanos, left)
            left -= take
            if take == entry.debt.nanos {
                owed[entry.debtor] = nil
            } else {
                owed[entry.debtor] = Debt(nanos: entry.debt.nanos - take,
                                          age: entry.debt.age,
                                          heir: entry.debt.heir)
            }
        }
        return growth - left
    }

    /// Older debts before younger ones, with the debtor's key as the tie-break
    /// that makes the order total. See `settle(growth:against:owed:)`.
    private static func olderFirst(_ left: (debtor: Key, debt: Debt),
                                   _ right: (debtor: Key, debt: Debt)) -> Bool {
        if left.debt.age != right.debt.age { return left.debt.age > right.debt.age }
        if left.debtor.pid != right.debtor.pid { return left.debtor.pid < right.debtor.pid }
        return left.debtor.startTime < right.debtor.startTime
    }

    /// The surviving process a vanished one's counters would be folded into, or
    /// `nil` when they left the table altogether.
    ///
    /// Starts at the parent the process was **last seen under**, not at the first
    /// surviving ancestor, and the difference is the whole of the rule.
    /// Reparenting is visible: when a parent dies, the next sweep sees its
    /// children under pid 1. A process last seen there has had its counter taken
    /// out of the tree already — launchd will reap it and nothing above will ever
    /// gain a nanosecond — so it is written down nowhere. Charged to an ancestor
    /// instead, it would be worked off by that ancestor's *unrelated* growth,
    /// which on a `claude` reaping the next `Bash` every tick arrives at once.
    ///
    /// Climbs only past ancestors that vanished in the **same** gap, because
    /// their own totals went up with them and this one travels inside those
    /// totals. Stops at pid 1, and at a parent the previous sweep does not have
    /// at all: neither says anything a debt could be settled against.
    ///
    /// "Would be" and "stands to", because for the climb — and only for the
    /// climb — the table cannot tell two shapes apart: a chain that died from the
    /// bottom up hands everything to the survivor (`sh -c 'cc …'`), and one that
    /// died from the top down hands the lower half to launchd, and both look like
    /// the same hole from here. That is why what comes out is a debt and not a
    /// deduction — the growth that arrives decides how much of it was real
    /// (SPEC §2.8).
    ///
    /// How often that is, measured over 200 passes a second apart (474 debts):
    /// 348 were addressed straight to a last-seen parent that was still there,
    /// **126 climbed** past a parent that had gone in the same gap — two to
    /// eight links — and 60 more vanishings were addressed nowhere at all,
    /// having been last seen under launchd. Those 60 carry 4.449 core-seconds
    /// between them, which is the whole of what this rule declines to charge
    /// anybody: about 0.6% of everything that left the table, an error toward a
    /// low figure rather than a spike. They are disjoint from the core-seconds
    /// `debtLifetimeSeconds` quotes, which are what the 474 debts *owed*. Every
    /// one of the 126 climbs was settled by growth arriving at the ancestor —
    /// a frequency and not an acquittal, because nothing in the table says that
    /// growth was the debtor's own.
    static func heir(of key: Key,
                     lastSeen: [Key: Counters],
                     byPID: [Int32: Key],
                     survivors: Set<Key>) -> Key? {
        // Keys, not pids: a pid handed to somebody new inside the gap is a
        // different process, and following it would climb a stranger's chain.
        var seen: Set<Key> = [key]
        var current = key
        while let counters = lastSeen[current] {
            guard counters.ppid > 1,
                  let parent = byPID[counters.ppid],
                  seen.insert(parent).inserted
            else { return nil }
            if survivors.contains(parent) { return parent }
            current = parent
        }
        return nil
    }

    /// Folds per-process rates into one number per session.
    ///
    /// A session that owns processes but has burned nothing lands here as `0`,
    /// not as an absence: "idle" and "not measured yet" are different answers
    /// and the row draws them differently.
    ///
    /// **The owner table is keyed by `Key`, not by pid**, although attribution
    /// itself answers in pids — it is a question about the shape of the process
    /// tree, and the tree is pid-shaped. The join is where the pair matters,
    /// because the two sides need not be the same age: on a pass that arrives
    /// too soon the rates are held from an earlier pass while the attribution is
    /// this sweep's (`ProcessSampler.heldRates`). Joined on the bare number, a
    /// pid handed to a new process in between would credit the dead process's
    /// CPU to whatever session the new one belongs to. Joined on the key it
    /// drops out of the sum instead, which is exactly what holding rates per
    /// process rather than per session was for.
    static func cpuBySession(rates: [Key: Double], ownerByKey: [Key: Int32]) -> [Int32: Double] {
        var total: [Int32: Double] = [:]
        for (key, rate) in rates {
            guard let owner = ownerByKey[key] else { continue }
            total[owner, default: 0] += rate
        }
        return total
    }

    // MARK: - The system calls

    /// Every process this user can see, with its parent, its start time and its
    /// cumulative CPU.
    ///
    /// Processes the kernel will not talk about are dropped without a word: they
    /// belong to another user and can never be a session's.
    ///
    /// One sweep is a snapshot of a process table that turns over while it is
    /// being read, so its counts are a range, not a constant: over 200 sweeps a
    /// second apart, 863…893 pids listed and 669…699 answering
    /// `proc_pid_rusage`, `PROC_PIDTBSDINFO` and both — which is what this
    /// function keeps. Roughly 195 are refused.
    ///
    /// **The two calls do not refuse the same processes.** A **zombie** — a
    /// process that has exited and not yet been waited for — stays in
    /// `proc_listallpids` and goes on answering `proc_pid_rusage` with its final
    /// counters, while `PROC_PIDTBSDINFO` refuses it outright. It is rare (2 of
    /// 200 sweeps caught one, each for a single sweep, none the other way round)
    /// but ordinary.
    ///
    /// A hole is therefore ordinary, and both readers of this table account for
    /// it. **Attribution**: `walkUp` tells `broken` from `reachedTop`, so a chain
    /// that ran out of links buys the marker nothing and nobody is reported as
    /// an orphan on the strength of a parent the sweep merely could not see.
    /// **The rate**: a dropped row looks exactly like a process that has been
    /// reaped, and deducting its total at once would floor the tick to zero and
    /// then spike by the whole lifetime when the reap really landed. That is
    /// what the ledger in `rates` is for (SPEC §2.8).
    static func listProcesses() -> [Sampled] {
        let reported = proc_listallpids(nil, 0)
        guard reported > 0 else { return [] }
        // Twice the reported count, because the table is asked again below and
        // the machine goes on forking in between.
        var pids = [pid_t](repeating: 0, count: Int(reported) * 2)
        let capacity = Int32(pids.count * MemoryLayout<pid_t>.size)
        let got = proc_listallpids(&pids, capacity)
        guard got > 0 else { return [] }

        var result: [Sampled] = []
        result.reserveCapacity(Int(got))
        for pid in pids[0..<Int(got)] where pid > 0 {
            guard let cpu = cpuNanos(of: pid), let info = parentAndStart(of: pid) else { continue }
            result.append(Sampled(pid: pid,
                                  startTime: info.start,
                                  counters: Counters(ppid: info.ppid, own: cpu.own, child: cpu.child)))
        }
        return result
    }

    /// Nanoseconds per unit of `ri_user_time` / `ri_system_time`, as the
    /// rational `mach_timebase_info` reports it.
    ///
    /// Those fields are **not** nanoseconds, whatever the `_time` in their names
    /// suggests: they are mach absolute time units, and on this machine one unit
    /// is 125/3 = 41.667 ns. Dividing them by `1e9` would make every figure 41.7
    /// times too small.
    ///
    /// Read once, because the ratio cannot change while the system is up. Not
    /// written down as 125/3, because it differs between Apple silicon
    /// generations and is 1/1 on Intel.
    ///
    /// `nonisolated` although this enum has no global actor to be isolated to:
    /// it is read from `listProcesses`, which the snapshot assembly calls off
    /// the main thread, and a globally-isolated `static let` hops its reader
    /// onto the main actor without a word of warning (§6). The modifier keeps
    /// that from arriving as a side effect of somebody annotating the enum, and
    /// it is on **every** stored constant of this enum for that reason.
    nonisolated static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else {
            // Nanoseconds, which is what the ratio degenerates to anyway on the
            // machines where it is 1/1. Wrong by a constant beats no figure.
            return (1, 1)
        }
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// A process's own and its reaped children's cumulative CPU in nanoseconds,
    /// or `nil` when the kernel refuses.
    static func cpuNanos(of pid: Int32) -> (own: UInt64, child: UInt64)? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard status == 0 else { return nil }
        return (own: nanoseconds(fromMachUnits: info.ri_user_time &+ info.ri_system_time),
                child: nanoseconds(fromMachUnits: info.ri_child_user_time &+ info.ri_child_system_time))
    }

    /// Mach absolute time units to nanoseconds, exactly and without overflow.
    ///
    /// Whole units first and the remainder second, rather than `units * numer /
    /// denom`: the product is the answer scaled by `denom`, and this way the
    /// intermediate never grows past the answer itself.
    ///
    /// The ratio is a parameter rather than a read of `timebase` so that the
    /// remainder path can be asked about at all: on this machine the ratio is
    /// 125/3 and on Intel it is 1/1, and under 1/1 every input is a multiple of
    /// `denom`, so a test written against the live timebase proves nothing there
    /// (§6).
    static func nanoseconds(fromMachUnits units: UInt64, numer: UInt64, denom: UInt64) -> UInt64 {
        units / denom * numer + units % denom * numer / denom
    }

    /// The same conversion at this machine's own ratio.
    static func nanoseconds(fromMachUnits units: UInt64) -> UInt64 {
        let (numer, denom) = timebase
        return nanoseconds(fromMachUnits: units, numer: numer, denom: denom)
    }

    /// Parent pid and start time in whole seconds, from `PROC_PIDTBSDINFO`.
    static func parentAndStart(of pid: Int32) -> (ppid: Int32, start: UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        // A short answer is a partially filled struct, which is not an answer.
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (Int32(bitPattern: info.pbi_ppid), UInt64(info.pbi_start_tvsec))
    }

    /// `kern.argmax`: how large the buffer `KERN_PROCARGS2` writes into has to
    /// be. Constant for the life of the system, so it is read once — the
    /// alternative is a second `sysctl` per process, every pass.
    ///
    /// `nonisolated` for the reason `timebase` is.
    nonisolated static let argumentsMaximum: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 0 }
        return Int(value)
    }()

    /// What one process's argument block had to say about `CLAUDE_PID`.
    ///
    /// Three answers, not two, because "no marker" and "no environment to look
    /// in" are different facts about the machine and only one of them is about
    /// the process. `KERN_PROCARGS2` returns `argv` and then simply stops for a
    /// platform binary carrying `CS_RESTRICT` — `/bin/sleep`, `/bin/bash`,
    /// `/usr/bin/git`, `/bin/cp` all answer that way, whatever is actually in
    /// their environment, while `/opt/homebrew/bin/node` and `/usr/bin/python3`
    /// hand the whole block over. On this machine about 43% of readable
    /// processes cannot present a marker at all (the census is in SPEC §2.8).
    enum Marker: Sendable, Equatable {
        /// The environment was readable and named a session.
        case pid(Int32)
        /// The environment was readable and carried no `CLAUDE_PID`.
        case absent
        /// There was no environment to read. Says nothing about the process.
        case withheld
    }

    /// `CLAUDE_PID` out of a process's environment.
    ///
    /// `KERN_PROCARGS2` lays the block out as: `argc` (`Int32`), the exec path,
    /// NUL padding, `argv[0…argc-1]`, then the environment, every string
    /// NUL-terminated. Nothing marks where the environment begins except
    /// counting past `argc` strings, which is what the walk below does.
    ///
    /// The buffer is the caller's and is reused across the sweep. `kern.argmax`
    /// is a megabyte on this machine, and allocating and zeroing one per process
    /// is most of what a cold sweep costs (§6).
    ///
    /// Compared as bytes rather than decoded into a dictionary of `String`: only
    /// one variable out of a few hundred is wanted, and the rest of the block is
    /// arbitrary bytes that need not be valid UTF-8 at all.
    static func marker(of pid: Int32, buffer: inout [UInt8]) -> Marker {
        guard buffer.count > MemoryLayout<Int32>.size else { return .withheld }
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        // Denied for other users' processes, and gone for a process that exited
        // between the sweep and this call. Both are ordinary.
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return .withheld }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buffer[0..<MemoryLayout<Int32>.size]) }
        var index = MemoryLayout<Int32>.size
        // The exec path and the NUL padding behind it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        // Then argc strings.
        var skipped: Int32 = 0
        while index < size, skipped < argc {
            while index < size, buffer[index] != 0 { index += 1 }
            index += 1
            skipped += 1
        }

        // Nothing left behind `argv`. That is the whole of the signal: the
        // kernel handed over the arguments and kept the environment.
        guard index < size else { return .withheld }

        let name = markerVariable
        while index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            // Longer than the name, so that there is a value behind the `=`.
            guard index - start > name.count else { continue }
            var offset = 0
            while offset < name.count, buffer[start + offset] == name[offset] { offset += 1 }
            guard offset == name.count else { continue }
            let digits = buffer[(start + name.count)..<index]
            // A variable of that name whose value is not a number is not a
            // marker. `absent` rather than a second scan: Claude Code writes a
            // pid there, and anything else came from something that is not it.
            guard let value = Int32(String(decoding: digits, as: UTF8.self)) else { return .absent }
            return .pid(value)
        }
        return .absent
    }

    /// `nonisolated` for the reason `timebase` is.
    nonisolated private static let markerVariable = Array("CLAUDE_PID=".utf8)
}

/// The state one CPU rate needs: the sweep before this one, and what every
/// process's environment said the first time it was seen.
///
/// A holder rather than a field of `DataSource` because `DataSource.assemble` is
/// pure by design, and the same shape as `UsageCache` for the same reason: the
/// snapshot is built off the main thread, on whichever queue got there first.
///
/// `@unchecked Sendable`: both stored tables are only ever touched under the
/// lock.
final class ProcessSampler: @unchecked Sendable {
    private let lock = NSLock()

    /// The previous sweep's cumulative counters, and when it was taken.
    ///
    /// `DispatchTime` is `mach_absolute_time`, which does not advance while the
    /// machine sleeps — and neither does a process's CPU counter, so a sleep is
    /// invisible to both sides of the division rather than being a gap that has
    /// to be detected. A wall clock would have to be, and could also go
    /// backwards.
    private var previousCPU: [SessionProcesses.Key: SessionProcesses.Counters] = [:]
    private var previousAt: UInt64 = 0

    /// The last rate that was computed over a gap long enough to divide.
    ///
    /// Held, not recomputed, when the next pass arrives too soon
    /// (`SessionProcesses.minimumSampleSeconds`) — and the baseline above is
    /// held with it, so the gap goes on growing until it is worth dividing. A
    /// blank was the alternative and it is the wrong one: the pass that arrives
    /// too soon is the one the panel makes when it slides out, so the blank
    /// would land exactly where somebody is looking.
    ///
    /// Per process rather than per session, so that a held figure is folded
    /// through the *current* attribution: a process that has since died drops
    /// out of the sum instead of being credited to a session by a stale
    /// ownership table.
    private var heldRates: [SessionProcesses.Key: Double]?

    /// What has been reported for processes that have left the table and has
    /// not yet arrived anywhere (`SessionProcesses.Debt`).
    ///
    /// The same state as `previousCPU`, and it is discarded with it: a debt is a
    /// promise about the growth the *next* pair of sweeps will show, so a pair
    /// this sampler refuses to describe takes the ledger with it.
    private var debts: [SessionProcesses.Key: SessionProcesses.Debt] = [:]

    /// `CLAUDE_PID` per process, remembered against the pair that identifies it.
    ///
    /// A process cannot change its own environment after `execve`, so this is
    /// read once and never again — which is what makes the marker affordable at
    /// all: a cold sweep reads every environment on the machine, a warm one
    /// reads only the processes that appeared since the last pass (§6).
    ///
    /// The value is itself optional, and the two levels mean different things:
    /// no entry is "not read yet", an entry of `nil` is "read, and no marker to
    /// be had" — which is nearly every process, and re-reading those every pass
    /// would leave the cache doing nothing.
    private var markers: [SessionProcesses.Key: Int32?] = [:]

    /// Reused across the sweep and across passes; see `SessionProcesses.marker`.
    private var argumentBuffer: [UInt8] = []

    /// What the last pass did, for the tests that hold the cache to its promise.
    ///
    /// Neither number has a reader in the app: the cache is either working or it
    /// is quietly costing five times the pass, and nothing on the screen says
    /// which. These are what a test asks instead (§6).
    struct PassStats: Sendable, Equatable {
        /// Processes the sweep saw.
        var processes: Int
        /// Environments actually read from the kernel — the cold part.
        var environmentsRead: Int
        /// Entries the marker cache holds afterwards, read back off the field
        /// itself. Read off the local the field was built from instead, it is
        /// one per process by construction and the equality below is a
        /// tautology no mutation can break (§6).
        var cacheEntries: Int
        /// Entries the counter table holds afterwards, likewise off the field.
        /// It is the other half of "the tables are rebuilt".
        var counterEntries: Int
        /// Debts the ledger still holds after the pass: CPU reported for
        /// processes that have left the table and has not arrived anywhere yet
        /// (SPEC §2.8).
        var openDebts: Int
        /// Debts this pass gave up on, and there are **three** ways rather than
        /// two. Two of them are `SessionProcesses.Rates.expired`: aged out, or
        /// the heir they were charged to left the table with no survivor left
        /// to re-address them to (that comment also spells out why a *debtor*
        /// leaving is neither). The third is this pass having no measurement to
        /// make at all — the first pass, or a gap longer than
        /// `staleSampleSeconds` — where `sample` drops the **whole** ledger
        /// along with the baseline, whatever any single entry's age. A gap
        /// *shorter* than `minimumSampleSeconds` is not that case: it is a
        /// hold, the block is skipped entirely, and nothing expires.
        ///
        /// This is the counter that makes the class of bug visible. A debt that
        /// is never settled is CPU reported for a process whose counter went
        /// somewhere we cannot see, and the ledger's own failure mode is that
        /// such a debt spends itself against the next genuine growth instead —
        /// which on the screen is a busy session drawn as empty space, exactly
        /// what an idle one looks like. Nothing else anywhere records it.
        var expiredDebts: Int
    }

    private var stats = PassStats(processes: 0, environmentsRead: 0, cacheEntries: 0,
                                  counterEntries: 0, openDebts: 0, expiredDebts: 0)

    func lastPassStats() -> PassStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// One pass: sweep the process table, classify it against the live sessions,
    /// and report what each session is burning.
    ///
    /// Evicting the dead is the same operation as filling in the new: both
    /// tables are rebuilt from this sweep, so a process that has gone takes its
    /// entries with it.
    ///
    /// The whole pass is under the lock, the sweep included. With the clock read
    /// outside it, two overlapping calls could leave `previousAt` ahead of a
    /// later call's `now`, and `now - previousAt` on `UInt64` traps. The
    /// expensive half of a cold pass is the environment reads, which need the
    /// lock anyway.
    func sample(sessionPIDs: Set<Int32>) -> SessionProcesses.Load {
        lock.lock()
        defer { lock.unlock() }

        let processes = SessionProcesses.listProcesses()
        // Read after the sweep, not before it. The counters are read *during*
        // the sweep (0.94–6.6 ms, §6), so a timestamp taken on the far side of
        // it on one pass and the near side on the next describes a different
        // interval from the one the counters describe. Same side both times.
        let now = DispatchTime.now().uptimeNanoseconds

        if argumentBuffer.count != SessionProcesses.argumentsMaximum {
            argumentBuffer = [UInt8](repeating: 0, count: SessionProcesses.argumentsMaximum)
        }

        var freshMarkers: [SessionProcesses.Key: Int32?] = [:]
        freshMarkers.reserveCapacity(processes.count)
        var current: [SessionProcesses.Key: SessionProcesses.Counters] = [:]
        current.reserveCapacity(processes.count)
        var facts: [SessionProcesses.Facts] = []
        facts.reserveCapacity(processes.count)

        var read = 0
        for process in processes {
            let key = process.key
            let marker: Int32?
            if let cached = markers[key] {
                marker = cached
            } else {
                read += 1
                // `absent` and `withheld` are both stored as `nil`: neither will
                // ever turn into a marker, so both are answers the cache is
                // entitled to keep. See `SessionProcesses.Facts.marker`.
                if case .pid(let value) = SessionProcesses.marker(of: process.pid, buffer: &argumentBuffer) {
                    marker = value
                } else {
                    marker = nil
                }
            }
            freshMarkers[key] = marker
            current[key] = process.counters
            facts.append(SessionProcesses.Facts(pid: process.pid,
                                                ppid: process.counters.ppid,
                                                marker: marker))
        }
        markers = freshMarkers

        let attribution = SessionProcesses.attribute(facts, sessionPIDs: sessionPIDs)
        // Attribution answers in pids because the process tree is pid-shaped;
        // the sum below is over `Key`s that may be older than this sweep. The
        // join happens here, on this sweep's own keys — see `cpuBySession`.
        var ownerByKey: [SessionProcesses.Key: Int32] = [:]
        ownerByKey.reserveCapacity(attribution.ownerByPID.count)
        for process in processes {
            guard let owner = attribution.ownerByPID[process.pid] else { continue }
            ownerByKey[process.key] = owner
        }

        let elapsed = previousAt == 0 ? 0 : Double(now - previousAt) / 1e9
        // Too soon is a hold, and the baseline is held with it so that the gap
        // goes on growing. Too old, or the very first pass, replaces the
        // baseline and reports nothing — the held figure would be older than
        // `staleSampleSeconds` and is dropped with it.
        let tooSoon = previousAt != 0 && elapsed < SessionProcesses.minimumSampleSeconds
        var expired = 0
        if !tooSoon {
            if let measured = SessionProcesses.rates(previous: previousCPU,
                                                     current: current,
                                                     elapsed: elapsed,
                                                     debts: debts) {
                heldRates = measured.percentByKey
                debts = measured.debts
                expired = measured.expired
            } else {
                // Not one measurement: the first pass, or a gap too long to
                // call "now". The ledger goes with the baseline, because the
                // pass that could have settled its debts is the one being
                // thrown away.
                heldRates = nil
                expired = debts.count
                debts = [:]
            }
            previousCPU = current
            previousAt = now
        }

        stats = PassStats(processes: processes.count,
                          environmentsRead: read,
                          cacheEntries: markers.count,
                          counterEntries: previousCPU.count,
                          openDebts: debts.count,
                          expiredDebts: expired)

        return SessionProcesses.Load(
            cpuPercentBySessionPID: heldRates.map {
                SessionProcesses.cpuBySession(rates: $0, ownerByKey: ownerByKey)
            } ?? [:],
            orphansBySessionPID: attribution.orphansBySessionPID)
    }
}
