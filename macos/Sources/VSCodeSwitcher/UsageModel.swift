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
/// Source: Anthropic's public price list, checked 2026-08-16. The ratios are
/// model-independent, which is what makes a single set of weights honest rather
/// than a guess about which model spent the tokens: output costs exactly 5x
/// input on every current model (Opus $5/$25 per Mtok, Sonnet $3/$15, Haiku
/// $1/$5), a cache write with the 5-minute TTL costs 1.25x input and a cache
/// read costs 0.1x input.
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
    /// The window the gateway *applied*, which is not the one that was asked
    /// for: it clamps `since` to the retention boundary (30 days at the time of
    /// writing). This is the number to show.
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
/// Units are per cent, 0…100. (`/gw/status` reports the same quantity as a
/// fraction; this app never calls it, so the two cannot be mixed up.)
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
/// the two agree: measured 2026-08-24 on one body, the fleet's four rates are
/// the sum of the accounts' to the last digit the body prints (input
/// 120.483 + 0 + 98.047 = 218.530 against a fleet 218.53, and the same for the
/// other three). Only the fleet's is decoded, because only the fleet's has a
/// reader — a field nobody reads is a field that can only rot (§2.7).
///
/// The four counters are already divided by the window, so nothing here
/// multiplies by it. `windowSeconds` is decoded all the same and it is the one
/// field that can refuse the reading: a rate averaged over no time at all is not
/// a rate. It is never assumed either — the body says 300 today (2026-08-24) and
/// this file holds no constant to disagree with it.
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
        // check stood on the per-second sum while the value returned was that
        // sum times 3600, and the multiplication carries a body over the edge
        // the check had just cleared: `"input_tokens": 1e306` is valid JSON and
        // a finite rate, and 3600 times it is `+inf` — which the lead figure
        // prints as `infB/h` and the ramp pins red. One statement over the
        // product refuses everything the two statements over the sum refused,
        // because 3600 moves neither the sign nor the finiteness the other way.
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
    /// Applied window, clamped by the gateway exactly as in `SessionsReport`.
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
/// with its own age beside it is timed separately too — a snapshot that carried
/// one stamp for both said "updated just now" over figures an hour old.
///
/// Only that half. `/gw/sessions` has no stamp of its own here because nothing
/// draws one: its figures are the spend on the panel's rows, and a row carries
/// an indicator and a number with no age beside either. A stamp nobody reads is
/// a field to keep in step with every future change of the merge rule, in
/// exchange for nothing.
///
/// Which is why no stamp of the *attempt* is ever drawn. One was, and the footer
/// line that read it — "checked N ago", beside the age of the figures — is the
/// line §4 removed: with both halves polled once a minute the two sentences moved
/// together and said the same thing twice.
///
/// There is one attempt stamp left, `allowanceCheckedAt`, and it is the exception
/// that proves the rule: nothing draws it, its single reader is the schedule that
/// decides whether this pass fetches the histories, and it exists precisely so
/// that `allowanceFetchedAt` may go on meaning "when the figure arrived" while
/// the retry moves without it. That is the same shape as the popover's own
/// `UsageHistoryModel.checkedAt` — a live reader, no line on screen — and the
/// same distinction: a stamp that moves on a failed attempt must never be the one
/// an age is written from, which is exactly how the footer came to call hour-old
/// figures fresh.
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
    /// it lives beside the mean rather than beside `sustainable`: nothing here
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
    /// kept unattributed until the project list can be asked whether the two
    /// slugs mean two projects (`DataSource.settle`).
    var contested: [ContestedSpend]
    /// Spend of the sessions whose transcript is not on this machine — agent
    /// nodes, mostly. Not an error: it is real spend with no local owner.
    var unmatched: TokenCounts
    var unmatchedSessions: Int
    /// What the fleet may spend an hour and still last the week
    /// (`FleetCapacity.sustainable`) — the allowance the lead figure is stated
    /// against, and the denominator of the ratio both surfaces are coloured by.
    ///
    /// `nil` while nothing has been worked out yet, and `nil` again when a pass
    /// asked and found no figure: the allowance refuses for several different
    /// reasons and none of them is a number (see the popover's headline, which
    /// has to draw all of them the same).
    ///
    /// It used to sit beside a second figure, the week's estimated *load*, on the
    /// same two stamps and the same blame. That figure is gone — the gateway
    /// measures the demand directly (`fleetTokenRate`), so estimating it was
    /// estimating something already known — and this one kept the stamps, being
    /// the same half of the pass and the same two requests.
    var sustainable: FleetCapacity.SustainableRate?
    /// When `sustainable` last *arrived*, which is not when it was last asked
    /// for. Its own stamp because it is on its own schedule: the histories are
    /// fetched once every `UsageStore.allowanceIntervalSeconds`, not once a
    /// minute with the rest, so this figure is ordinarily the oldest thing the
    /// popover holds.
    ///
    /// What reads it is the age ceiling both surfaces apply
    /// (`UsagePopoverView.historiesAreFresh`): past two of those intervals the figure
    /// is not drawn at all. It is deliberately not what the footer dates the
    /// screen by — a stamp may only date something on screen, and by the time
    /// this one would be worth a line the figure it belongs to is gone.
    var allowanceFetchedAt: Date?
    /// When the histories were last *asked for*, answered or not. The schedule
    /// is decided on this one and nothing else reads it.
    ///
    /// Two stamps rather than one, because the two questions have opposite
    /// answers on a failure. "When may we ask again" has to move — a half that
    /// did not stamp its failed attempt fell back to the once-a-minute poll, and
    /// one persistently failing account takes the histories from 2.9 MB/h to
    /// some 19 MB/h, which is the cost the ten-minute cadence exists to avoid
    /// (`UsageStore.poll` carries the measurement). "How old is the figure" must
    /// not move, or a frozen number passes for a fresh one — which is the defect
    /// that took the app's last attempt stamp away, and here it would keep a
    /// figure past the ceiling that is supposed to drop it.
    var allowanceCheckedAt: Date?
    /// Why `/gw/usage/<label>/history` — or the `/gw/sessions` call beside it —
    /// did not answer on the last pass that tried. Same rule as the other two
    /// halves: the previous `sustainable` stays where it is and only the blame
    /// changes.
    var allowanceFailure: String?
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
                                     unmatched: .zero,
                                     unmatchedSessions: 0,
                                     sustainable: nil,
                                     allowanceFetchedAt: nil,
                                     allowanceCheckedAt: nil,
                                     allowanceFailure: nil,
                                     quotaFailure: nil,
                                     sessionsFailure: nil)

    /// The fleet's weekly quota as a whole per cent — the one figure two
    /// surfaces show, rounded in one place so they cannot disagree about it.
    ///
    /// Rounding here rather than at each drawing also makes the menu bar picture
    /// a pure function of one `Int?`, which is what lets its owner dedupe on the
    /// value and redraw only when it really changed.
    ///
    /// Freshness is deliberately not part of it: whether an old reading may
    /// still be shown is a question each surface answers for itself, and they
    /// answer it differently — see `MenuBarIcon.percent` and the popover's
    /// headline.
    var fleetSevenDayPercent: Int? {
        fleetSevenDayMean.map { Int($0.rounded()) }
    }

    /// Every reason as one line, for the places that print a reason rather than
    /// act on one. Deliberately not called `failure`: the readers that *decide*
    /// something — the menu bar picture above all — must name the half they mean,
    /// and the old single field let a failure of `/gw/sessions` blank out a
    /// perfectly fresh quota figure.
    ///
    /// All three halves, because its one reader is `--dump`, and a half that
    /// fails without saying so there is a half nobody can debug: the allowance
    /// half's own requests are the only ones the app makes that no surface blames
    /// out loud.
    var failureText: String? {
        let all = [quotaFailure, sessionsFailure, allowanceFailure].compactMap { $0 }
        return all.isEmpty ? nil : all.joined(separator: "; ")
    }

    /// Everything the gateway reported for the window, matched or not — the
    /// contested sessions included, because they are spend that happened and the
    /// only open question is whose row it belongs on.
    var total: TokenCounts {
        contested.reduce(tokensBySlug.values.reduce(unmatched, +)) { $0 + $1.tokens }
    }
}
