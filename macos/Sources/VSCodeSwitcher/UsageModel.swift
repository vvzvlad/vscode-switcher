import Foundation

/// Token spend and quota utilisation, as the claude_gw gateway reports them and
/// as the rest of the app consumes them.
///
/// Nothing here talks to the network or the disk: these are the values, the
/// decoding of the gateway's bodies, and the arithmetic that folds four
/// differently-priced token kinds into one comparable number.

// MARK: - Tokens

/// Weights that fold the four token kinds into one *input-equivalent* number.
///
/// Source: Anthropic's public price list. The ratios are model-independent,
/// which is what makes a single set of weights honest rather than a guess about
/// which model spent the tokens: output costs exactly 5x input on every current
/// model (Opus $5/$25 per Mtok, Sonnet $3/$15, Haiku $1/$5), a cache write with
/// the 5-minute TTL costs 1.25x input and a cache read costs 0.1x input.
///
/// One approximation is knowingly made: a cache write with the 1-hour TTL costs
/// 2x input, not 1.25x. The gateway does not record the TTL, so every write is
/// counted at 1.25. On the live 7-day data cache writes are about 12% of the
/// input-equivalent total even if every one of them were an hour-TTL write, so
/// the worst case moves the total by a few per cent and does not reorder the
/// projects.
struct TokenWeights: Sendable {
    var input: Double
    var output: Double
    var cacheCreation: Double
    var cacheRead: Double

    /// The prices above, normalised to input tokens.
    static let inputEquivalent = TokenWeights(input: 1, output: 5, cacheCreation: 1.25, cacheRead: 0.1)
}

/// The four token counters of one session or one project.
///
/// The four are never added up raw: they are billed at different rates, and the
/// gateway's own documentation calls their plain sum "a number that appears on
/// no invoice". `weighted(_:)` is the only way to get one number out.
///
/// A `nil` field means the upstream never named that number — not that it is
/// zero. `weighted(_:)` counts it as zero all the same, which makes the result a
/// *lower bound*; `isComplete` is exactly the flag that says whether it is one.
///
/// Immutable, and `isComplete` is stored rather than derived from the four
/// optionals, because addition has to carry it: `nil + 5` is 5 as a lower bound,
/// and that 5 must not pass for a complete answer merely by no longer being nil.
struct TokenCounts: Sendable, Equatable, Codable {
    let input: Int?
    let output: Int?
    let cacheCreation: Int?
    let cacheRead: Int?
    /// True when every number that went into this value was named upstream.
    let isComplete: Bool

    init(input: Int?, output: Int?, cacheCreation: Int?, cacheRead: Int?) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        isComplete = input != nil && output != nil && cacheCreation != nil && cacheRead != nil
    }

    private init(input: Int?, output: Int?, cacheCreation: Int?, cacheRead: Int?, isComplete: Bool) {
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.isComplete = isComplete
    }

    /// The sum of no sessions at all: adding it changes neither the numbers nor
    /// their completeness, which is what makes it usable as the seed of a
    /// `reduce`. Complete on purpose — nothing is known exactly — and that is
    /// not the same value as a session whose four fields the gateway left
    /// unnamed.
    static let zero = TokenCounts(input: nil, output: nil, cacheCreation: nil, cacheRead: nil, isComplete: true)

    /// True when not one of the four counters was ever named.
    ///
    /// `weighted()` answers 0 for such a value, and that 0 is the one number
    /// this file exists to keep off the screen: it is the sum of nothing known,
    /// not a spend of zero. Everything that turns these counters into something
    /// a person reads — `SwitcherRow.usageInputEquivalent`, the `--dump`
    /// columns — asks this first and prints a dash instead.
    ///
    /// `.zero` answers true as well, and rightly so: the seed of the sums knows
    /// nothing either.
    var knowsNothing: Bool {
        input == nil && output == nil && cacheCreation == nil && cacheRead == nil
    }

    /// Input-equivalent total. Unknown fields count as zero, so this is a lower
    /// bound whenever `isComplete` is false — and a meaningless zero when
    /// `knowsNothing` is true, which is why the readers go through
    /// `SwitcherRow.usageInputEquivalent` rather than through this.
    func weighted(_ weights: TokenWeights = .inputEquivalent) -> Double {
        Double(input ?? 0) * weights.input
            + Double(output ?? 0) * weights.output
            + Double(cacheCreation ?? 0) * weights.cacheCreation
            + Double(cacheRead ?? 0) * weights.cacheRead
    }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: sum(lhs.input, rhs.input),
                    output: sum(lhs.output, rhs.output),
                    cacheCreation: sum(lhs.cacheCreation, rhs.cacheCreation),
                    cacheRead: sum(lhs.cacheRead, rhs.cacheRead),
                    isComplete: lhs.isComplete && rhs.isComplete)
    }

    /// Two counters that may each be absent. Absent plus absent stays absent;
    /// anything else contributes what it knows.
    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }
}

// MARK: - GET /gw/sessions

/// One client session as the gateway accounted for it.
///
/// `bound_to`, `incomplete`, `responses`, the `measured_*` counters and the
/// `by_account` breakdown are deliberately not decoded: nothing in this app
/// reads them, and a field nobody reads is a field that can only rot.
struct GatewaySession: Sendable, Decodable, Equatable {
    let sessionId: String
    let tokens: TokenCounts

    // Explicit keys everywhere in this file: `.convertFromSnakeCase` maps
    // `five_hour` and `util_5h` by two different rules and would drop one of
    // them without a word.
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        // `decodeIfPresent` answers nil for both a missing key and a JSON null,
        // which are the same thing here: the upstream did not name the number.
        tokens = TokenCounts(
            input: try container.decodeIfPresent(Int.self, forKey: .inputTokens),
            output: try container.decodeIfPresent(Int.self, forKey: .outputTokens),
            cacheCreation: try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens),
            cacheRead: try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens))
    }
}

/// The body of `GET /gw/sessions`.
struct SessionsReport: Sendable, Decodable {
    /// The window the gateway *applied*, which need not be the one that was
    /// asked for. This is the number to show, because the answer is the
    /// authority on what it covers. No clamping has been observed: the endpoint
    /// returns the `since` it was sent at 30 and at 90 days, and the history
    /// endpoint does the same at 30, 60 and 90 (§2.7).
    let since: Date
    /// The gateway keeps the 200 largest consumers and drops the cheapest tail.
    let truncated: Bool
    /// Largest consumer first.
    let sessions: [GatewaySession]

    enum CodingKeys: String, CodingKey {
        case since
        case truncated
        case sessions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        since = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .since))
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        sessions = try container.decode([GatewaySession].self, forKey: .sessions)
    }
}

// MARK: - GET /gw/usage

/// One quota window of one account: how much of it is spent, and when it resets.
///
/// Units are per cent, 0…100, and this window is spelled `five_hour` /
/// `seven_day` with a `utilization` inside. `/gw/status` reports the same
/// quantity as a **fraction**; this app calls that endpoint only for the
/// operator switch, and no type on that path decodes a utilisation at all (the
/// warning is written out over `GatewayStatus`). The collision worth fearing is
/// between `/gw/status` and the account history, which spell that quantity under
/// one and the same key name in two different units (SPEC §2.7); this endpoint
/// at least calls it something else.
///
/// `known: false` means the gateway has no reading, which is not the same as an
/// untouched quota — so it becomes `nil` here rather than 0, and the flag itself
/// is not kept: "no reading" and "a reading of null" are one state, and a
/// confidently wrong percentage is worse than a missing one.
struct UsageWindow: Sendable, Decodable, Equatable {
    let utilization: Double?
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
        case known
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let known = try container.decodeIfPresent(Bool.self, forKey: .known) ?? false
        let reading = try container.decodeIfPresent(Double.self, forKey: .utilization)
        utilization = known ? reading : nil
        let stamp = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        resetsAt = stamp.flatMap { try? Date($0, strategy: .iso8601) }
    }
}

/// One quota window across the whole fleet, averaged by the gateway.
///
/// Only the mean is kept, and only when at least one account went into it: the
/// average of nothing is not zero. The averaging itself is never redone here —
/// the server knows which accounts are eligible, this app does not.
struct FleetWindow: Sendable, Decodable, Equatable {
    let mean: Double?

    enum CodingKeys: String, CodingKey {
        case mean
        case accounts
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let accounts = try container.decodeIfPresent(Int.self, forKey: .accounts) ?? 0
        mean = accounts > 0 ? try container.decodeIfPresent(Double.self, forKey: .mean) : nil
    }
}

/// How fast tokens are being spent right now, as `GET /gw/usage` reports it.
///
/// The gateway publishes this block per account and once for the whole set, and
/// the two agree: the fleet's four rates are the sum of the accounts' to the last
/// digit the body prints. Only the fleet's is decoded, because only the fleet's
/// has a reader — a field nobody reads is a field that can only rot (§2.7).
///
/// The four counters are already divided by the window, so nothing here
/// multiplies by it. `windowSeconds` is decoded all the same and it is the one
/// field that can refuse the reading: a rate averaged over no time at all is not
/// a rate. It is never assumed either — the body says 300 and this file holds no
/// constant to disagree with it.
struct TokenRate: Sendable, Decodable, Equatable {
    /// The window the gateway averaged over, in seconds.
    let windowSeconds: Double?
    let input: Double?
    let output: Double?
    let cacheCreation: Double?
    let cacheRead: Double?

    enum CodingKeys: String, CodingKey {
        case windowSeconds = "window_seconds"
        case perSecond = "per_second"
    }

    enum RateKeys: String, CodingKey {
        case input = "input_tokens"
        case output = "output_tokens"
        case cacheCreation = "cache_creation_input_tokens"
        case cacheRead = "cache_read_input_tokens"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowSeconds = try container.decodeIfPresent(Double.self, forKey: .windowSeconds)
        // A `per_second` that is absent or null leaves all four unnamed, which
        // `perHour` then refuses. Decoding it as a nested container that may not
        // be there keeps an older gateway's body — one with no `tokens` at all,
        // or one with `tokens: null` when statistics are off — from failing the
        // whole of `/gw/usage` and taking the quota figures down with it.
        let rates = try? container.nestedContainer(keyedBy: RateKeys.self, forKey: .perSecond)
        input = try rates?.decodeIfPresent(Double.self, forKey: .input)
        output = try rates?.decodeIfPresent(Double.self, forKey: .output)
        cacheCreation = try rates?.decodeIfPresent(Double.self, forKey: .cacheCreation)
        cacheRead = try rates?.decodeIfPresent(Double.self, forKey: .cacheRead)
    }

    /// Input-equivalent tokens an hour, or `nil` when the body did not carry a
    /// rate this app may state.
    ///
    /// **All four counters or none**, which is a stricter rule than the one
    /// `TokenCounts` follows over the same four numbers — and deliberately. There
    /// an unnamed counter is worth zero and the surfaces print `≥` in front of
    /// the total; here the figure is the largest thing on the popover and has no
    /// such marker, so a rate missing `output_tokens` would understate by five
    /// times its share and say nothing about it. Unknown is not zero (§2.7), and
    /// with nowhere to write the caveat the answer is no figure.
    ///
    /// A window of zero or less is the same refusal for the same reason: the
    /// gateway divided by it, so whatever came back is not a rate.
    func perHour(_ weights: TokenWeights = .inputEquivalent) -> Double? {
        guard let windowSeconds, windowSeconds > 0,
              let input, let output, let cacheCreation, let cacheRead else { return nil }
        let perHour = (input * weights.input
            + output * weights.output
            + cacheCreation * weights.cacheCreation
            + cacheRead * weights.cacheRead) * 3600
        // A negative rate is not a slower one, and an infinity is not a faster
        // one: both are a body this app cannot state.
        //
        // **Asked of the figure that leaves, not of the sum behind it.** The
        // multiplication can carry a body over the edge: `"input_tokens": 1e306`
        // is valid JSON and a finite rate, and 3600 times it is `+inf` — which
        // the lead figure would print as `infB/h` and the ramp pin red. 3600
        // moves neither the sign nor the finiteness the other way, so checking
        // the product refuses everything a check of the sum would.
        guard perHour.isFinite, perHour >= 0 else { return nil }
        return perHour
    }
}

/// The `fleet` block of `GET /gw/usage`. The seven-day window and the live token
/// rate have readers; nothing else does.
struct FleetUsage: Sendable, Decodable, Equatable {
    let sevenDay: FleetWindow?
    let tokens: TokenRate?

    enum CodingKeys: String, CodingKey {
        case sevenDay = "seven_day"
        case tokens
    }
}

/// One account's two quota windows.
struct AccountUsage: Sendable, Decodable, Equatable {
    /// The key this object sat under in `accounts`, not a field of the object
    /// itself — `UsageReport` fills it in while decoding the dictionary.
    var label: String
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = ""
        fiveHour = try container.decodeIfPresent(UsageWindow.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(UsageWindow.self, forKey: .sevenDay)
    }
}

/// The body of `GET /gw/usage`.
struct UsageReport: Sendable, Decodable {
    let fleet: FleetUsage?
    /// Sorted by label, so two dumps of the same data read the same way.
    let accounts: [AccountUsage]

    enum CodingKeys: String, CodingKey {
        case fleet
        case accounts
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fleet = try container.decodeIfPresent(FleetUsage.self, forKey: .fleet)
        let byLabel = try container.decodeIfPresent([String: AccountUsage].self, forKey: .accounts) ?? [:]
        accounts = byLabel.keys.sorted().compactMap { label in
            guard var account = byLabel[label] else { return nil }
            account.label = label
            return account
        }
    }
}

// MARK: - GET /gw/usage/{label}/history

/// One sample of an account's utilisation.
///
/// `util_5h` and `util_7d` are per cent and may be null — that sample said
/// nothing about that window, which is not a reading of zero.
struct HistoryPoint: Sendable, Decodable, Equatable {
    let timestamp: Date
    let fiveHour: Double?
    let sevenDay: Double?

    enum CodingKeys: String, CodingKey {
        case timestamp = "ts"
        case fiveHour = "util_5h"
        case sevenDay = "util_7d"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .timestamp))
        fiveHour = try container.decodeIfPresent(Double.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(Double.self, forKey: .sevenDay)
    }

    /// A sample with a reading of our own in it. Its one use is
    /// `UsageHistoryModel.withoutSourceLag`, which replaces a sample's `util_7d`
    /// with the reading before it when the two measuring sources disagree; the
    /// wire format is otherwise the only maker of these values.
    init(timestamp: Date, fiveHour: Double?, sevenDay: Double?) {
        self.timestamp = timestamp
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

/// The body of `GET /gw/usage/{label}/history`.
struct HistorySeries: Sendable, Decodable {
    let label: String
    /// Applied window, as in `SessionsReport`.
    let since: Date
    /// The series was cut to `max_points`.
    let truncated: Bool
    let points: [HistoryPoint]

    enum CodingKeys: String, CodingKey {
        case label
        case since
        case truncated
        case points
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        since = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .since))
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        points = try container.decode([HistoryPoint].self, forKey: .points)
    }
}

// MARK: - Snapshot

/// One poll of the gateway, joined against the local transcripts: what the rest
/// of the app reads.
///
/// The two halves are blamed separately, because they arrive separately:
/// `/gw/usage` can answer while `/gw/sessions` times out. The half that is drawn
/// with its own age beside it is timed separately too, so one half's fresh stamp
/// never dates the other's hour-old figures.
///
/// Only that half. `/gw/sessions` has no stamp of its own here because nothing
/// draws one: its figures are the spend on the panel's rows, and a row carries
/// an indicator and a number with no age beside either.
///
/// No stamp of the *attempt* is ever drawn (§4). The one attempt stamp,
/// `historiesCheckedAt`, has a single reader — the schedule that decides whether
/// this pass fetches the histories — and exists so that `historiesFetchedAt` may
/// go on meaning "when the figure arrived" while the retry moves without it. That
/// is the same shape as the popover's own `UsageHistoryModel.checkedAt`: a stamp
/// that moves on a failed attempt must never be the one an age is written from.
struct UsageSnapshot: Sendable {
    /// When `/gw/usage` last answered, or `nil` if it never has. The account
    /// figures, the fleet mean and the accounts list are all as of this moment.
    var quotaFetchedAt: Date?
    /// The window the gateway applied to the session figures.
    var since: Date
    /// The gateway dropped the cheapest sessions past its cap.
    var truncated: Bool
    /// `fleet.seven_day.mean`, as computed by the gateway. `nil` when no account
    /// contributed to it.
    var fleetSevenDayMean: Double?
    /// Input-equivalent tokens an hour, right now, as the gateway measured them
    /// over its own short window (`TokenRate`). The headline's lead figure.
    ///
    /// It arrives with the quota half and is as of `quotaFetchedAt`, which is why
    /// it lives beside the mean rather than beside `fleetBurn`: nothing here
    /// estimates it, and the ten-minute cadence of the histories has no hold on
    /// it. `nil` when the gateway named no rate — an older gateway with no
    /// `tokens` block, statistics turned off, or a window of zero.
    ///
    /// Zero is a reading and not an absence: a fleet with nothing running spends
    /// nothing, and that is a true thing to draw.
    var fleetTokenRate: Double?
    var accounts: [AccountUsage]
    /// Spend per slug directory of `~/.claude/projects`, already joined from
    /// session ids.
    ///
    /// The key is the directory Claude Code filed the session under, which is
    /// the directory the session was *started* in — not where its tokens were
    /// spent, because a session walks between directories while it runs
    /// (`UsageIndex`). Read as "the spend of the sessions started here". A slug
    /// is never decoded back into a path; it is matched forwards, against the
    /// slug of each known project (`DataSource`).
    var tokensBySlug: [String: TokenCounts]
    /// Sessions filed under more than one slug — resumed in another directory —
    /// kept unattributed here.
    ///
    /// Already narrowed to this report's own window: `UsageStore.poll` runs
    /// `UsageIndex.narrowToWindow` on the way in, dropping the copies that were not
    /// written to inside it. So an entry's `slugs` is what *could have spent* here,
    /// which may have come out at one or at none, not the list of copies on disk.
    /// Settling what is left needs a layer that has the live sessions and the
    /// project list — the veto first, then whether the survivors mean one project,
    /// two, or none at all (`DataSource.settle`).
    var contested: [ContestedSpend]
    /// The same spend per slug directory, counted over the last hour instead of
    /// the last week (`UsageStore.hourWindowSeconds`) — a **rate**, and the reason
    /// it is one takes a sentence.
    ///
    /// The gateway's per-session aggregates are windowed: a session's block covers
    /// what it spent inside the window asked for and nothing earlier — a live
    /// session reads 5.3M over 15 minutes, 25.5M over an hour and 177.3M over
    /// eight hours, and every session grows monotonically as the window widens
    /// (§2.9). So the tokens reported for a window one hour long *are* tokens per
    /// hour, and nothing here or downstream divides by anything.
    ///
    /// Same shape and same key as `tokensBySlug`, folded by the same `fold`
    /// against the same slug map, so it makes exactly the same claim: the spend of
    /// the sessions *started* in this directory, in the last 3600 s. A slug absent
    /// here spent nothing in the hour, which is a reading and not an absence —
    /// though `TokenCounts.knowsNothing` still separates "spent nothing" from
    /// "nothing was reported", as it does for the week.
    var hourlyTokensBySlug: [String: TokenCounts]
    /// The hour's contested sessions, on the same terms as `contested` and settled
    /// by the same `DataSource.settle`.
    ///
    /// Kept rather than dropped because dropping it is not neutral: a session
    /// resumed in another directory would then carry a week's figure on its row
    /// and no hourly one, so a project being worked in *right now* could read as
    /// idle for the single reason that its chat was once resumed elsewhere.
    var hourlyContested: [ContestedSpend]
    /// Spend of the sessions whose transcript is not on this machine — agent
    /// nodes, mostly. Not an error: it is real spend with no local owner.
    var unmatched: TokenCounts
    var unmatchedSessions: Int
    /// The same bucket for the hour, and it is here for the reason
    /// `hourlyContested` is: the hour has to be able to say what it lost.
    ///
    /// Spend by a session with no local transcript would otherwise disappear from
    /// the hour with no line anywhere to notice it by. A bucket that fills and
    /// empties with the sliding hour is exactly the one that must not be conjured
    /// into existence only once it is non-empty: that is the state in which
    /// nobody can see it.
    var hourlyUnmatched: TokenCounts = .zero
    var hourlyUnmatchedSessions: Int = 0
    /// How fast the fleet is burning its quota against how fast it refills
    /// (`FleetCapacity.burnAgainstRefill`) — the lead figure both surfaces print,
    /// and the one they are coloured by.
    ///
    /// `nil` while nothing has been worked out yet, and `nil` again when a pass
    /// asked and found no figure: not one account had a long enough history that
    /// left its ceiling and whose falls the schedule could explain (see the
    /// popover's headline, which has to draw all of those the same).
    var fleetBurn: FleetCapacity.FleetBurn?
    /// When `fleetBurn` last *arrived*, which is not when it was last asked for.
    /// Its own stamp because it is on its own schedule: the histories are fetched
    /// once every `UsageStore.historyIntervalSeconds`, not once a minute with the
    /// rest, so this figure is ordinarily the oldest thing the popover holds.
    ///
    /// What reads it is the age ceiling both surfaces apply
    /// (`UsagePopoverView.historiesAreFresh`): past two of those intervals the figure
    /// is not drawn at all. It is deliberately not what the footer dates the
    /// screen by — a stamp may only date something on screen, and by the time
    /// this one would be worth a line the figure it belongs to is gone.
    var historiesFetchedAt: Date?
    /// When the histories were last *asked for*, answered or not. The schedule
    /// is decided on this one and nothing else reads it.
    ///
    /// Two stamps rather than one, because the two questions have opposite
    /// answers on a failure. "When may we ask again" has to move — a half that
    /// did not stamp its failed attempt would fall back to the once-a-minute
    /// poll, and one persistently failing account would take the histories from
    /// 2.9 MB/h to some 19 MB/h, which is the cost the ten-minute cadence exists
    /// to avoid (`UsageStore.poll` carries the measurement). "How old is the
    /// figure" must not move, or a frozen number passes for a fresh one and is
    /// kept past the ceiling that is supposed to drop it.
    var historiesCheckedAt: Date?
    /// Why `/gw/usage/<label>/history` did not answer on the last pass that
    /// tried. Same rule as the other two halves: the previous `fleetBurn` stays
    /// where it is and only the blame changes.
    var historiesFailure: String?
    /// Why `/gw/status` did not answer on the last pass that asked — which is the
    /// histories' pass, on the histories' cadence.
    ///
    /// **It is the one failure string that does not remove anything from the
    /// screen**, and that is the whole reason it is a field of its own rather than
    /// another sentence in `historiesFailure`. The surfaces drop the burn figure
    /// when that one is set (`UsagePopoverView.historiesAreFresh`), and this half
    /// answers a narrower question — which accounts the operator has switched out
    /// of the rotation — whose absence degrades the figure by at most a couple of
    /// points for at most a couple of hours (`UsageStore.poll` works out the
    /// bound). Blanking the headline over that would be the larger harm.
    ///
    /// It is still collected by `failureText`, so `--dump` names it: a half that
    /// fails silently is a half nobody can debug, and this one is invisible on
    /// every other surface by design.
    var rotationFailure: String?
    /// Why `/gw/usage` did not answer on the last pass. The account figures next
    /// to it are the previous ones, kept on purpose: slightly stale beats blank.
    var quotaFailure: String?
    /// Why `/gw/sessions` did not answer on the last pass. Same rule.
    var sessionsFailure: String?

    /// Nothing polled yet.
    static let empty = UsageSnapshot(quotaFetchedAt: nil,
                                     since: .distantPast,
                                     truncated: false,
                                     fleetSevenDayMean: nil,
                                     fleetTokenRate: nil,
                                     accounts: [],
                                     tokensBySlug: [:],
                                     contested: [],
                                     hourlyTokensBySlug: [:],
                                     hourlyContested: [],
                                     unmatched: .zero,
                                     unmatchedSessions: 0,
                                     fleetBurn: nil,
                                     historiesFetchedAt: nil,
                                     historiesCheckedAt: nil,
                                     historiesFailure: nil,
                                     quotaFailure: nil,
                                     sessionsFailure: nil)

    /// The fleet's weekly quota as a whole per cent, rounded in one place so that
    /// two readers cannot disagree about it.
    ///
    /// Freshness is deliberately not part of it: whether an old reading may
    /// still be shown is the surface's question, and the popover's headline
    /// answers it by keeping the figure and dating it in the footer.
    var fleetSevenDayPercent: Int? {
        fleetSevenDayMean.map { Int($0.rounded()) }
    }

    /// Every reason as one line, for the places that print a reason rather than
    /// act on one. Deliberately not called `failure`: the readers that *decide*
    /// something — the menu bar picture above all — must name the half they mean,
    /// so that a failure of `/gw/sessions` cannot blank out a fresh quota figure.
    ///
    /// All four requests, because its one reader is `--dump`, and a half that
    /// fails without saying so there is a half nobody can debug: the histories'
    /// two requests are the ones the app makes that no surface blames out loud —
    /// the series itself, which at least removes the figure when it fails, and
    /// `/gw/status`, which removes nothing at all (`rotationFailure`).
    var failureText: String? {
        let all = [quotaFailure, sessionsFailure, historiesFailure, rotationFailure]
            .compactMap { $0 }
        return all.isEmpty ? nil : all.joined(separator: "; ")
    }

    /// Everything the gateway reported for the window, matched or not — the
    /// contested sessions included, because they are spend that happened and the
    /// only open question is whose row it belongs on.
    var total: TokenCounts {
        contested.reduce(tokensBySlug.values.reduce(unmatched, +)) { $0 + $1.tokens }
    }
}

// MARK: - GET /gw/status

/// Whether an operator has switched one account out of the gateway's rotation.
///
/// Four fields and no more, which is the whole of what this app asks `/gw/status`
/// for. `disabled` is the verdict as of now; `disabled_until` is a moment when
/// the gateway will put the account back by itself, and `null` covers both "in
/// the rotation" and "out of it with no end named", so it may never be read as a
/// state of its own — `disabled` is.
///
/// **Not `eligible`, which is the field that looks like this one.** The field is
/// written by `is_eligible` (`src/accounts.py:258`), which is
/// `is_eligible_apart_from_5h(...) AND util_5h < max_5h` — that is, the five-hour
/// window *and* everything the inner half folds in: the operator's switch (it
/// reaches the flag through `is_disabled` in there), the authorisation state, the
/// quota cool-down, the token-refresh backoff and the weekly window. So an
/// account that merely filled a window reads `eligible: false` exactly as a
/// switched-off one does: `main` at `util_5h: 1.0` in the `status` fixture
/// against the `max_util_5h = 0.99` of that same body's own `config` block gives
/// `eligible: false` beside `disabled: false`. Both are fractions and both are
/// that endpoint's — the account history spells the same quantity as a percentage
/// (`util_5h: 26.0` in the `history` fixture), and comparing across the two is how
/// a hundredfold slip gets written down as a measurement. A checkbox bound to the
/// flag would clear itself when a quota window filled and would then send an
/// `enable` that changes nothing visible.
///
/// The flag *is* read, one level up and for another question: `GatewayStatus`
/// counts it into `routableAccounts`, because "is there anywhere left to send a
/// request" is exactly what `eligible` answers and exactly what the warning under
/// the accounts is about. It is deliberately not a field of this type — a
/// checkbox drawn from an `AccountSwitch` has no way to reach a number that is
/// not in one.
struct AccountSwitch: Sendable, Decodable, Equatable {
    let label: String
    let disabled: Bool
    /// When the gateway will re-enable it on its own, or `nil` — see above: `nil`
    /// is not "enabled".
    let disabledUntil: Date?
    /// What the operator gave as the reason, `""` when none was given. Empty
    /// rather than `nil` because the gateway sends the empty string itself, and
    /// two spellings of "nothing was said" would only be told apart by accident.
    let disabledReason: String

    // Explicit keys, as everywhere in this file: `.convertFromSnakeCase` is what
    // silently drops one of two similarly-shaped names.
    enum CodingKeys: String, CodingKey {
        case label
        case disabled
        case disabledUntil = "disabled_until"
        case disabledReason = "disabled_reason"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        // Required, exactly as `label` is: `disabled` is the one field on this
        // path that draws a *control*, and the lenient reading of a missing one —
        // "nobody switched it off" — would tick and arm every checkbox in the
        // fleet on the strength of a key that was not there (§2.4's
        // confidently-wrong reading with a click attached). If the gateway renames
        // the field, refusing the body takes the whole rotation to "nobody said",
        // which is a state this app knows how to draw and a state nobody can act
        // on by mistake.
        disabled = try container.decode(Bool.self, forKey: .disabled)
        disabledUntil = try container.decodeIfPresent(Double.self, forKey: .disabledUntil)
            .map { Date(timeIntervalSince1970: $0) }
        disabledReason = try container.decodeIfPresent(String.self, forKey: .disabledReason) ?? ""
    }
}

/// The body of `GET /gw/status`, cut down to the one question this app asks it.
///
/// **`accounts` here is an ARRAY**, each element carrying its own `label` — where
/// `/gw/usage` sends a dictionary keyed by the label. Two endpoints, two shapes,
/// one field name.
///
/// **And the body carries utilisation too, in fractions.** `util_5h`, `util_7d`
/// and their `reset_*` stamps are all there, written 0…1 — while the account
/// history, `GET /gw/usage/<label>/history`, writes the same quantity under
/// **those same two key names** as 0…100 and says so in a `units` field
/// (SPEC §2.7): `util_5h: 0.43` here is `util_5h: 43.0` in the history. One
/// name, two units, and nothing about either body to make the mix-up visible.
/// (`/gw/usage` is not the trap: it has no `util_5h` key at all, spelling the
/// reading `five_hour.utilization`, per cent.) This type reads none of them,
/// deliberately: everything downstream of here is in per cent, so a fraction
/// decoded "while we are reading the body anyway" would understate by a hundred
/// times with nothing on screen to look wrong. Quota readings come from
/// `/gw/usage` and its history, and from nowhere else.
struct GatewayStatus: Sendable, Decodable {
    let accounts: [AccountSwitch]
    /// How many of them the gateway may still route a request to.
    ///
    /// Counted here over `eligible` and handed out only as this number, never per
    /// account. The question it answers is the fleet's — "is there anywhere left
    /// to send a request" — which is the question the warning under the accounts
    /// asks, so this number both raises that warning and takes it down. Per
    /// account the same flag would be the right answer to the wrong question, so
    /// it is kept off `AccountSwitch` altogether and a checkbox cannot reach it.
    ///
    /// The same quantity as `SwitchResult.eligibleAccounts`: the gateway counts
    /// both with `is_eligible` (`src/gateway.py:1675` and `:2014`), so a pass and
    /// a switch answer are two moments of one measurement rather than two facts.
    let routableAccounts: Int

    enum CodingKeys: String, CodingKey {
        case accounts
    }

    /// One element of the array, read for both questions at once: the switch the
    /// checkbox draws, and the routing flag that may not go anywhere near it.
    ///
    /// `eligible` sits here rather than on `AccountSwitch` — this type is private
    /// and nothing outside gets one, so a checkbox still has no way to reach the
    /// flag — and the two questions are still two types. What it does not do is
    /// read `accounts` a second time: the strictness below is the rule about a
    /// missing array, and a rule written twice holds only where somebody ran a
    /// mutation over both copies (AGENTS.md). One `decode`, one place to break.
    private struct Entry: Decodable {
        let account: AccountSwitch
        let eligible: Bool

        // The body is flat, so the switch is decoded off this same decoder — the
        // shape `SwitchResult` uses for the same four fields, and for the same
        // reason: one rule for them, written once.
        enum CodingKeys: String, CodingKey {
            case eligible
        }

        init(from decoder: any Decoder) throws {
            account = try AccountSwitch(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Strict, exactly as `disabled` is: `applyRoutable` raises the fleet
            // line on a zero count, so reading a missing key as `false` would
            // paint the loudest thing on this surface out of a hole in the body.
            // Refusing it buys the honest state this app already has: a pass that
            // will not decode sets `rotationFailure` and leaves every switch inert,
            // which says "this app cannot say" where `?? false` would say "there
            // is nowhere left to route".
            eligible = try container.decode(Bool.self, forKey: .eligible)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Strict: a missing `accounts` is not a gateway with no accounts. `?? []`
        // would write the absence of an answer as an answer — every checkbox
        // drawn from an empty dictionary rather than from `nil`, with not one word
        // anywhere saying why, and `routableAccounts` at zero, a count that raises
        // the warning about a fleet with nowhere to route. An empty array is still
        // an answer and still decodes; it is the hole that is refused.
        let entries = try container.decode([Entry].self, forKey: .accounts)
        accounts = entries.map(\.account)
        routableAccounts = entries.filter(\.eligible).count
    }

    /// The switches by the label they belong to, which is how every reader wants
    /// them: the popover draws one row per account of the *quota* poll and asks
    /// this by name.
    var byLabel: [String: AccountSwitch] {
        Dictionary(accounts.map { ($0.label, $0) }, uniquingKeysWith: { _, last in last })
    }
}

// MARK: - POST /gw/accounts/{label}/disable and /enable

/// What either switch endpoint answers with: the account's new state, and what
/// it cost the fleet.
///
/// The body is **flat** — the four fields of `AccountSwitch` sit beside
/// `eligible_accounts` and `warning` at the top level, rather than under an
/// account object — so `account` is decoded from this very decoder rather than
/// from a nested container. One rule for the four fields, written once: a second
/// copy of it here could come to disagree with `/gw/status` about what a missing
/// `disabled` means, and the two are the same fact arriving by two routes.
///
/// **This is the authority on the new state**, which is why the popover takes the
/// switch from here rather than from what it asked for: the gateway may answer
/// something else, and a checkbox that moved on the click would then be showing
/// the request instead of the fleet.
struct SwitchResult: Sendable, Decodable, Equatable {
    let account: AccountSwitch
    /// How many accounts the fleet has left that it may still route to — this
    /// body's answer to the question `GatewayStatus.routableAccounts` answers on a
    /// pass, counted by the gateway with the same `is_eligible` in both places.
    /// One quantity at two moments, which is why the popover takes its verdict
    /// from whichever of the two spoke last and never from the sentence beside
    /// this number.
    let eligibleAccounts: Int
    /// The gateway's wording for that verdict, and only the wording.
    ///
    /// **It is this number said again in words, not a second fact.**
    /// `Gateway._switch_payload` (`src/gateway.py:1986`) writes the count and then
    /// `None if eligible else "claude-gw: no usable account is left…"`, so
    /// `warning != null` holds exactly when `eligible_accounts == 0` and there is
    /// no body in which the two disagree. Reading them as two facts is how a rule
    /// like "the sentence raises the warning, the count takes it down" comes to be
    /// written: it is a fine rule, and it was justified by a third kind of body —
    /// an `enable` that gives the fleet nothing back answering `warning: null`
    /// with the count still at zero — that this endpoint does not send.
    ///
    /// The gateway deliberately does not refuse the call that empties the fleet:
    /// switching off the last usable account is a legitimate thing for an operator
    /// to do, and the only requirement is that they cannot fail to notice it.
    ///
    /// **Never printed.** The sentence names the metric by the word §4 keeps off
    /// every string a person reads, and there is nothing to weigh against that:
    /// the `else` branch above is one fixed two-line constant rather than a
    /// message, so it carries not one thing this count does not. The popover words
    /// the same verdict itself, in `UsageHistoryModel.noRouteWarning`.
    ///
    /// **Decoded and kept all the same**, because this field is the body's own
    /// statement of the invariant the whole switch surface rests on — one fact
    /// written twice by `_switch_payload`, which is what lets the popover put the
    /// verdict on the count alone. Nothing in production reads it; two tests do,
    /// and they hold two different things.
    /// `testEverySwitchAnswerFixtureOnThisListIsABodyTheGatewayCouldHaveSent` holds
    /// the **pairing** over every switch answer in the suite: those bodies are
    /// hand-built (no live `disable` was ever captured), and the check is what
    /// catches a fixture the gateway could not have sent.
    /// `testASwitchAnswersWithTheNewStateAndWhatItCostTheFleet` holds the
    /// **wording**, character for character, and is what reddens if
    /// `_switch_payload`'s constant is ever rewritten — a change this app has to
    /// know about, since `UsageHistoryModel.noRouteWarning` is that sentence minus
    /// three words.
    let warning: String?

    enum CodingKeys: String, CodingKey {
        case eligibleAccounts = "eligible_accounts"
        case warning
    }

    init(from decoder: any Decoder) throws {
        account = try AccountSwitch(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Strict for `GatewayStatus.Entry.eligible`'s reason, and this is the worse
        // of the two places to be lenient in: the count is the verdict, and this
        // decoder is on the click path, so `?? 0` would raise the orange line in
        // the very second the operator is looking at the checkbox they just
        // pressed. A body that will not decode blames the click by the label it was
        // on and leaves the tick where it stood — a state this app draws already.
        eligibleAccounts = try container.decode(Int.self, forKey: .eligibleAccounts)
        // And `warning` stays lenient, permanently: `null` is a value the gateway
        // sends on purpose — it is what a count above zero comes with — so there is
        // no hole to refuse here.
        warning = try container.decodeIfPresent(String.self, forKey: .warning)
    }
}
