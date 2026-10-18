import XCTest
@testable import VSCodeSwitcher

/// Bodies copied verbatim from live gateway answers, unknown keys included:
/// a fixture is the thing that actually arrives.
enum UsageFixtures {
    static let sessions = """
    {
      "since": 1786761516, "now": 1786847916, "units": "tokens",
      "max_sessions": 200, "truncated": false,
      "sessions": [
        {
          "session_id": "121d7f47-540d-4e13-a603-25eaad87bd79",
          "bound_to": "acc2", "responses": 25, "incomplete": 0,
          "first_ts": 1786847534, "last_ts": 1786847911,
          "input_tokens": 50, "output_tokens": 24264,
          "cache_read_input_tokens": 5401028, "cache_creation_input_tokens": 41120,
          "measured_input_tokens": 25, "measured_output_tokens": 25,
          "measured_cache_read_input_tokens": 25, "measured_cache_creation_input_tokens": 25,
          "by_account": { "acc2": { "...": 0 } }
        }
      ]
    }
    """

    static let usage = """
    {"fleet": {"accounts": 3, "eligible": 2,
      "five_hour": {"mean": 21.0, "min": 14.0, "max": 28.0, "best_label": "acc3", "accounts": 2, "no_data": 0, "blocked_elsewhere": 1},
      "seven_day": {"mean": 58.667, "min": 5.0, "max": 99.0, "best_label": "acc2", "accounts": 3, "no_data": 0}},
     "accounts": {"acc2": {"five_hour": {"utilization": 28.0, "resets_at": "2026-08-16T03:00:00Z", "known": true},
                           "seven_day": {"utilization": 5.0, "resets_at": "2026-08-22T21:00:00Z", "known": true}, "...": {}}}}
    """

    /// The three accounts `status` names, so that one pass can put every state of
    /// the two flags on the same fleet: switched on and routable (`acc2`),
    /// switched off (`acc3`), and **switched on but not routable** (`main`).
    ///
    /// The third is the whole reason there are three: it is the row that tells a
    /// reader of `disabled` from a reader of `eligible`, and a two-account fixture
    /// cannot hold it and a switched-off account at once.
    static let usageThreeAccounts = """
    {"fleet": {"accounts": 3, "eligible": 1,
      "seven_day": {"mean": 30.0, "min": 5.0, "max": 60.0, "best_label": "acc2", "accounts": 3, "no_data": 0}},
     "accounts": {"acc2": {"seven_day": {"utilization": 10.0, "known": true}},
                  "acc3": {"seven_day": {"utilization": 60.0, "known": true}},
                  "main": {"seven_day": {"utilization": 4.0, "known": true}}}}
    """

    /// The same report with a second account in it, for the one question a
    /// one-account fleet cannot ask: what it costs when an account is refused and
    /// leaves with its 100 pp of capacity.
    static let usageTwoAccounts = """
    {"fleet": {"accounts": 2, "eligible": 2,
      "seven_day": {"mean": 58.667, "min": 5.0, "max": 99.0, "best_label": "acc2", "accounts": 2, "no_data": 0}},
     "accounts": {"acc2": {"seven_day": {"utilization": 5.0, "known": true}},
                  "acc3": {"seven_day": {"utilization": 40.0, "known": true}}}}
    """

    /// The same endpoint with the `tokens` block the headline's lead figure is read
    /// from, verbatim: one account and the fleet, so the fleet's four rates can be
    /// checked as the sum of the accounts'.
    static let usageWithTokens = """
    {"fleet": {"accounts": 3, "eligible": 2,
      "tokens": {"window_seconds": 300,
                 "per_second": {"input_tokens": 218.53, "output_tokens": 174.427,
                                "cache_read_input_tokens": 55836.677,
                                "cache_creation_input_tokens": 1091.747},
                 "responses": 69, "incomplete": 0, "sessions": 6},
      "seven_day": {"mean": 50.0, "min": 10.0, "max": 99.0, "best_label": "main", "accounts": 3, "no_data": 0}},
     "accounts": {"acc2": {"five_hour": {"utilization": 25.0, "resets_at": "2026-08-24T00:50:00Z", "known": true},
                           "seven_day": {"utilization": 41.0, "resets_at": "2026-08-29T21:00:00Z", "known": true},
                           "tokens": {"window_seconds": 300,
                                      "per_second": {"input_tokens": 120.483, "output_tokens": 62.253,
                                                     "cache_read_input_tokens": 18936.567,
                                                     "cache_creation_input_tokens": 468.033},
                                      "responses": 21, "incomplete": 0, "sessions": 2},
                           "eligible": true, "unified_status": "allowed"}}}
    """

    static let history = """
    {"label": "main", "since": 1786700000, "now": 1786786400, "units": "percent",
     "max_points": 2000, "truncated": false,
     "points": [{"ts": 1786700123, "util_5h": 26.0, "util_7d": 99.0, "status": "allowed", "source": "poll"}]}
    """

    /// The same shapes with the holes that mean "the upstream did not say".
    static let sessionsWithNulls = """
    {"since": 1786761516, "truncated": true,
     "sessions": [{"session_id": "s-partial", "input_tokens": 50, "output_tokens": null,
                   "cache_read_input_tokens": 5401028}]}
    """

    static let usageWithoutReadings = """
    {"fleet": {"accounts": 3, "seven_day": {"mean": 58.667, "accounts": 0}},
     "accounts": {"acc9": {"five_hour": {"utilization": 0.0, "known": false},
                           "seven_day": {"utilization": null, "known": true}}}}
    """

    static let historyWithNulls = """
    {"label": "main", "since": 1786700000, "truncated": false,
     "points": [{"ts": 1786700123, "util_5h": null, "util_7d": 99.0}]}
    """

    /// `GET /gw/status` (`now: 1788653295`), cut down: of the eight top-level blocks
    /// only `accounts`, `now` and `uptime_seconds` are kept, and each row carries only
    /// fields recorded at that moment (hence rows of different widths). Internal host
    /// names (the account row's `proxy` and `proxy_auth`) never go into this repository:
    /// strip them when re-taking a live body.
    ///
    /// The utilisations are fractions (`acc2` 0.72, `main` 1.0), while
    /// `/gw/usage/<label>/history` writes the same key `util_5h` as per cent (72.0,
    /// 100.0): one name, two units (§2.7). Nothing decodes them, and a test below says so.
    ///
    /// `main` is the reason this fixture exists: switched on (`disabled: false`) yet not
    /// routable (`eligible: false`), because the gateway folds a quota cool-down
    /// (`util_5h: 1.0` against `max_util_5h = 0.99`) into `eligible` only. It is the one
    /// row where the two flags disagree, which is what tells a reader of one from a
    /// reader of the other. A live gateway may not reproduce this row; anyone re-taking
    /// the body has to keep a row of this shape.
    ///
    /// The fourth state, switched off with no deadline, is in `switchAnswer` below.
    static let status = """
    {"uptime_seconds": 176312.4, "now": 1788653295,
     "accounts": [
       {"label": "acc2", "auth_state": "ok", "eligible": true,
        "util_5h": 0.72, "util_7d": 0.03, "reset_5h": 1788655800, "reset_7d": 1789246800,
        "unified_status": "allowed",
        "disabled": false, "disabled_until": null, "disabled_reason": ""},
       {"label": "acc3", "eligible": false,
        "disabled": true, "disabled_until": 1788706735,
        "disabled_reason": "operator: 22h, switched over from the temporary quota cooldown"},
       {"label": "main", "eligible": false, "util_5h": 1.0,
        "disabled": false, "disabled_until": null, "disabled_reason": ""}
     ]}
    """

    /// The same endpoint from a gateway that names an account and says nothing
    /// about its switch. There is no reading of that hole which draws a checkbox
    /// honestly, so the body is refused whole — see the test.
    static let statusWithoutTheSwitch = """
    {"accounts": [{"label": "acc2", "eligible": true, "disabled_until": null}]}
    """

    /// The mirror of it: every switch reported, nothing said about routing. Refused
    /// whole, because `?? false` would turn the hole into an orange "every request is
    /// a 429" line over accounts nobody switched off.
    static let statusWithoutTheRoutingFlag = """
    {"accounts": [
       {"label": "acc2", "disabled": false, "disabled_until": null, "disabled_reason": ""},
       {"label": "main", "disabled": false, "disabled_until": null, "disabled_reason": ""}
     ]}
    """

    /// A fleet with nowhere left to route in which nobody switched anything off.
    ///
    /// Built, not captured: `eligible` is `is_eligible`, which folds the five-hour
    /// window in beside the switch, so a fleet whose windows have all filled reads
    /// exactly like this. `main` in `status` above is one such row.
    static let statusWithNowhereToRoute = """
    {"now": 1788653295,
     "accounts": [
       {"label": "acc2", "eligible": false, "util_5h": 1.0,
        "disabled": false, "disabled_until": null, "disabled_reason": ""},
       {"label": "main", "eligible": false, "util_5h": 1.0,
        "disabled": false, "disabled_until": null, "disabled_reason": ""}
     ]}
    """

    /// The fleet `switchAnswer` and `switchAnswerWithWarning` were derived against:
    /// `acc3` parked, `acc2` and `main` both routable. Taking `acc2` out leaves 1 and
    /// taking `main` out after it leaves 0, the pair the ordering tests rely on (in
    /// `status` `main` is in cool-down, so that scene is unreachable there).
    ///
    /// Cut like `status`: the fields this app reads plus utilisations where a routing
    /// flag needs explaining. A live body writes `util_5h` and `util_7d` on every row.
    static let statusWithTwoRoutableAccounts = """
    {"now": 1788653295,
     "accounts": [
       {"label": "acc2", "eligible": true, "util_5h": 0.72,
        "disabled": false, "disabled_until": null, "disabled_reason": ""},
       {"label": "acc3", "eligible": false, "disabled": true,
        "disabled_until": 1788706735, "disabled_reason": "operator: 22h"},
       {"label": "main", "eligible": true, "util_5h": 0.11,
        "disabled": false, "disabled_until": null, "disabled_reason": ""}
     ]}
    """

    /// The same fleet once both routable accounts have been switched off: what a pass
    /// asked after `switchAnswer` and `switchAnswerWithWarning` have landed gets back.
    ///
    /// The two switched rows are what this app's own click produces: no request body,
    /// so `disabled_until: null` and an empty `disabled_reason`. All three rows are
    /// `eligible: false`, so the count is 0, matching `switchAnswerWithWarning`. No
    /// utilisation: every `eligible: false` is explained by its own switch.
    static let statusWithBothRoutableAccountsSwitchedOff = """
    {"now": 1788653295,
     "accounts": [
       {"label": "acc2", "eligible": false, "disabled": true,
        "disabled_until": null, "disabled_reason": ""},
       {"label": "acc3", "eligible": false, "disabled": true,
        "disabled_until": 1788706735, "disabled_reason": "operator: 22h"},
       {"label": "main", "eligible": false, "disabled": true,
        "disabled_until": null, "disabled_reason": ""}
     ]}
    """

    /// `/gw/status` after `acc3`'s 22-hour parking has run out by itself.
    ///
    /// `acc3` keeps `disabled_until` (now in the past) and `disabled_reason`: the
    /// gateway publishes both raw, and only an explicit enable clears the reason; only
    /// `disabled` is a verdict. `main` keeps its cool-down from `status`. `now` is cut
    /// (this type does not read it); the sitting is any moment past `1788706735`.
    static let statusWithTheParkingExpired = """
    {"accounts": [
      {"label": "acc2", "eligible": true, "disabled": false,
       "disabled_until": null, "disabled_reason": ""},
      {"label": "acc3", "eligible": true, "disabled": false,
       "disabled_until": 1788706735,
       "disabled_reason": "operator: 22h, switched over from the temporary quota cooldown"},
      {"label": "main", "eligible": false, "util_5h": 1.0, "disabled": false,
       "disabled_until": null, "disabled_reason": ""}
    ]}
    """

    /// `/gw/status` reporting switches this app did not throw: `acc2` taken out
    /// elsewhere, `acc3` put back.
    ///
    /// The answer a second pass gives where the first got `status`. Both rows moved, in
    /// opposite directions, so "this label is held and that one is not" can fail on
    /// either side. No utilisation: both flags are explained by their own switch.
    static let statusWithASwitchThrownElsewhere = """
    {"accounts": [
      {"label": "acc2", "eligible": false, "disabled": true,
       "disabled_until": null, "disabled_reason": "somebody else"},
      {"label": "acc3", "eligible": true, "disabled": false,
       "disabled_until": null, "disabled_reason": ""}
    ]}
    """

    /// `/gw/status` with one account whose token the gateway can no longer renew: `acc3`
    /// is `needs_manual_token` with the error it last got. Built, not captured; the three
    /// auth fields are the ones a live row carries.
    static let statusWithAnAccountThatNeedsALogin = """
    {"accounts": [
      {"label": "acc2", "auth_state": "ok", "auth_error": "", "refresh_failures": 0,
       "eligible": true, "disabled": false, "disabled_until": null, "disabled_reason": ""},
      {"label": "acc3", "auth_state": "needs_manual_token",
       "auth_error": "refresh token rejected (HTTP 400)", "refresh_failures": 3,
       "eligible": false, "disabled": false, "disabled_until": null, "disabled_reason": ""}
    ]}
    """

    /// `POST /gw/accounts/acc2/disable`, built to the contract rather than captured
    /// (the field list matches a live `enable`, which answers in the same shape).
    ///
    /// The count must satisfy the contract: `acc3` is already off, so taking `acc2` out
    /// leaves `main`, at a later moment than `status` when `main`'s window has emptied.
    /// The body is flat, and `_switch_payload` writes `warning` as
    /// `None if eligible else "claude-gw: …"`, so a count above zero comes with
    /// `warning: null`.
    static let switchAnswer = """
    {"label":"acc2","disabled":true,"disabled_until":null,"disabled_reason":"",\
    "eligible":false,"eligible_accounts":1,"warning":null}
    """

    /// The same endpoint taking the last usable account out: `eligible_accounts: 0`
    /// with the sentence. The sentence is the gateway's own, character for character,
    /// from `Gateway._switch_payload`; do not tidy it.
    static let switchAnswerWithWarning = """
    {"label":"main","disabled":true,"disabled_until":null,"disabled_reason":"",\
    "eligible":false,"eligible_accounts":0,\
    "warning":"claude-gw: no usable account is left in the fleet - every client request \
    will be answered with 429 until one of them comes back"}
    """

    /// A switch answer with the count missing, which is refused. `warning: null` is
    /// kept because the gateway sends it legitimately, so `?? 0` would raise a false
    /// orange line right after the operator's click.
    static let switchAnswerWithoutTheCount = """
    {"label":"acc2","disabled":true,"disabled_until":null,"disabled_reason":"",\
    "eligible":false,"warning":null}
    """

    /// A switch answer that contradicts the request: a `disable` answered with
    /// `disabled: false`. Used by `testTheStateAfterASwitchIsTheOneTheGatewaySentBack`
    /// and kept here so
    /// `testEverySwitchAnswerFixtureOnThisListIsABodyTheGatewayCouldHaveSent` reaches it.
    /// The contradiction is only in `disabled`: the count of 1 matches the stub's
    /// `status` fleet with `acc2` still routable.
    static let switchAnswerContradictingTheClick = """
    {"label":"acc2","disabled":false,"disabled_until":null,"disabled_reason":"pinned",\
    "eligible":true,"eligible_accounts":1,"warning":null}
    """

    /// An `enable` that gives the fleet an account back: count 1, and therefore no
    /// sentence.
    ///
    /// `switchAnswerWithWarning` sent the other way round, and the second half of
    /// `testAFleetWithNothingLeftInItSaysSoAndStopsSayingIt`: the line the first
    /// half raised has to come down on this count.
    static let switchAnswerPuttingTheAccountBack = """
    {"label":"main","disabled":false,"disabled_until":null,"disabled_reason":"",\
    "eligible":true,"eligible_accounts":1,"warning":null}
    """

    /// `POST /gw/accounts/acc3/enable` against the fleet of `status`: in `status` only
    /// `acc2` is routable, so putting `acc3` back makes two, with `warning: null`.
    /// Its own label, because the popover keys the rotation by the clicked label.
    static let switchAnswerPuttingAcc3Back = """
    {"label":"acc3","disabled":false,"disabled_until":null,"disabled_reason":"",\
    "eligible":true,"eligible_accounts":2,"warning":null}
    """

    /// `GET /gw/routes`, and what `PUT` and `DELETE /gw/routes/{key}` answer with: the
    /// configured alternatives and the families routed to one. Built to the contract,
    /// not captured.
    static let routes = """
    {"alternatives": [{"name": "glm (nano-gpt)", "upstream": "https://nano-gpt.com/api",
                       "model": "z-ai/glm-5.3-flash-uncensored"}],
     "routes": {"sonnet": "glm (nano-gpt)"}}
    """

    /// `/gw/status` carrying `routes` at `config.routing`, beside a key of the `config`
    /// block this app does not read. Built, not captured.
    static let statusWithRouting = """
    {"config": {"max_util_5h": 0.99, "routing": \(routes)},
     "accounts": [{"label": "acc2", "eligible": true,
                   "disabled": false, "disabled_until": null, "disabled_reason": ""}]}
    """

    static func decode<Body: Decodable>(_ text: String, as type: Body.Type) throws -> Body {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

/// Decoding the gateway's real bodies.
final class UsageDecodingTests: XCTestCase {

    func testSessionsBodyDecodesTheFourCountersAndTheAppliedWindow() throws {
        let report = try UsageFixtures.decode(UsageFixtures.sessions, as: SessionsReport.self)
        XCTAssertEqual(report.since, Date(timeIntervalSince1970: 1_786_761_516))
        XCTAssertFalse(report.truncated)
        XCTAssertEqual(report.sessions.count, 1)

        let session = try XCTUnwrap(report.sessions.first)
        XCTAssertEqual(session.sessionId, "121d7f47-540d-4e13-a603-25eaad87bd79")
        XCTAssertEqual(session.tokens.input, 50)
        XCTAssertEqual(session.tokens.output, 24264)
        XCTAssertEqual(session.tokens.cacheCreation, 41120)
        XCTAssertEqual(session.tokens.cacheRead, 5_401_028)
        XCTAssertTrue(session.tokens.isComplete)
    }

    /// The `since` that comes back is the one the gateway applied, and it is the one
    /// shown, never the one asked for: the answer is the authority on what it covers.
    func testTheAppliedWindowIsTheOneReported() throws {
        let report = try UsageFixtures.decode(UsageFixtures.sessionsWithNulls, as: SessionsReport.self)
        XCTAssertEqual(report.since, Date(timeIntervalSince1970: 1_786_761_516))
        XCTAssertTrue(report.truncated, "the cheapest sessions were dropped and the flag has to reach the model")
    }

    func testAMissingOrNullCounterIsNotZero() throws {
        let report = try UsageFixtures.decode(UsageFixtures.sessionsWithNulls, as: SessionsReport.self)
        let tokens = try XCTUnwrap(report.sessions.first).tokens
        XCTAssertEqual(tokens.input, 50)
        XCTAssertNil(tokens.output, "null means the upstream did not name it")
        XCTAssertNil(tokens.cacheCreation, "a missing key means the same")
        XCTAssertEqual(tokens.cacheRead, 5_401_028)
        XCTAssertFalse(tokens.isComplete)
    }

    func testUsageBodyDecodesTheFleetMeanAndTheAccounts() throws {
        let report = try UsageFixtures.decode(UsageFixtures.usage, as: UsageReport.self)
        XCTAssertEqual(report.fleet?.sevenDay?.mean, 58.667)
        XCTAssertEqual(report.accounts.map(\.label), ["acc2"])

        let account = try XCTUnwrap(report.accounts.first)
        XCTAssertEqual(account.fiveHour?.utilization, 28.0, "per cent, 0…100 — never a fraction")
        XCTAssertEqual(account.sevenDay?.utilization, 5.0)
        XCTAssertEqual(account.fiveHour?.resetsAt, try Date("2026-08-16T03:00:00Z", strategy: .iso8601))
        XCTAssertEqual(account.sevenDay?.resetsAt, try Date("2026-08-22T21:00:00Z", strategy: .iso8601))
    }

    /// `known: false` is "no reading", not "the quota is untouched". A
    /// confidently wrong percentage is worse than a missing one.
    func testAnUnknownWindowIsNilAndNotZero() throws {
        let report = try UsageFixtures.decode(UsageFixtures.usageWithoutReadings, as: UsageReport.self)
        let account = try XCTUnwrap(report.accounts.first)
        XCTAssertNil(account.fiveHour?.utilization, "known: false, even with a 0.0 next to it")
        XCTAssertNil(account.sevenDay?.utilization, "known: true with a null reading is still no reading")
    }

    /// The mean of no accounts is not zero either — and the averaging is the
    /// server's, never ours.
    func testAFleetMeanOverNoAccountsIsNil() throws {
        let report = try UsageFixtures.decode(UsageFixtures.usageWithoutReadings, as: UsageReport.self)
        XCTAssertNil(report.fleet?.sevenDay?.mean)
    }

    // MARK: - The live token rate

    /// The block the headline's lead figure is read from, weighted the one way four
    /// differently priced counters may be:
    /// `218.53 + 5 x 174.427 + 1.25 x 1091.747 + 0.1 x 55836.677 = 8039.0164`
    /// input-equivalent tokens a second, which is 28,940,459 an hour.
    func testTheFleetsTokenRateIsWeightedAndCarriedToTheHour() throws {
        let report = try UsageFixtures.decode(UsageFixtures.usageWithTokens, as: UsageReport.self)
        let tokens = try XCTUnwrap(report.fleet?.tokens)
        XCTAssertEqual(tokens.windowSeconds, 300, "the body's own window, never a constant of ours")
        XCTAssertEqual(try XCTUnwrap(tokens.perHour()), 28_940_459.22, accuracy: 0.01, """
            output is billed at five times input and a cache read at a tenth, so the raw sum of \
            the four is a number that appears on no invoice (§2.7)
            """)
    }

    /// An older gateway has no `tokens` block at all, and that must cost the
    /// quota figures beside it nothing: the popover falls back to the weekly
    /// mean, which is exactly what it drew before this figure existed.
    func testAGatewayWithNoTokenBlockStillReportsItsQuota() throws {
        let report = try UsageFixtures.decode(UsageFixtures.usage, as: UsageReport.self)
        XCTAssertNil(report.fleet?.tokens, "the 2026-08-16 body, which had no such block")
        XCTAssertEqual(report.fleet?.sevenDay?.mean, 58.667, "and the half that was there still arrives")
    }

    /// Every way the block can be there and still not carry a rate. Each answers `nil`,
    /// which moves the headline back to the quota rather than showing a wrong number.
    /// The negative and the overflowing counter decode fine and are refused by the
    /// arithmetic, one before the multiplication and one after it.
    func testEveryUnusableTokenBlockIsNoRateRatherThanZero() throws {
        func rate(_ body: String) throws -> TokenRate? {
            try UsageFixtures.decode("{\"fleet\": {\(body)}}", as: UsageReport.self).fleet?.tokens
        }
        let full = """
        "per_second": {"input_tokens": 1.0, "output_tokens": 2.0, \
        "cache_read_input_tokens": 3.0, "cache_creation_input_tokens": 4.0}
        """

        XCTAssertNil(try rate("\"tokens\": null"), "statistics off: a null block is not a rate of zero")
        XCTAssertNil(try rate("\"tokens\": {\"window_seconds\": 0, \(full)}")?.perHour(), """
            the gateway divided by this window, so a window of zero means whatever came back is \
            not a rate at all
            """)
        XCTAssertNil(try rate("\"tokens\": {\(full)}")?.perHour(),
                     "a block that names no window cannot say what its rates are an average of")
        XCTAssertNil(try rate("\"tokens\": {\"window_seconds\": 300}")?.perHour(),
                     "a window with no rates under it")
        XCTAssertNil(try rate("""
            "tokens": {"window_seconds": 300, "per_second": {"input_tokens": 1.0, \
            "cache_read_input_tokens": 3.0, "cache_creation_input_tokens": 4.0}}
            """)?.perHour(), """
            all four counters or none: output is five times input, so a rate missing it understates \
            by most of itself — and this figure has no `≥` to say so with (§2.7)
            """)
        XCTAssertNil(try rate("""
            "tokens": {"window_seconds": 300, "per_second": {"input_tokens": -1.0, \
            "output_tokens": 0.0, "cache_read_input_tokens": 0.0, \
            "cache_creation_input_tokens": 0.0}}
            """)?.perHour(), """
            a counter below zero decodes as happily as any other number, and a negative rate is \
            not a slower one — it is a body this app cannot state. The other three are zero on \
            purpose: what is refused is the weighted rate rather than the counter, and beside \
            the fixture above's own 2.0 / 3.0 / 4.0 a -1.0 input still totals +14.3 a second
            """)
        XCTAssertNil(try rate("""
            "tokens": {"window_seconds": 300, "per_second": {"input_tokens": 1e306, \
            "output_tokens": 0.0, "cache_read_input_tokens": 0.0, \
            "cache_creation_input_tokens": 0.0}}
            """)?.perHour(), """
            1e306 a second is a finite rate and 3600 times it is not: the check has to stand on \
            the figure that leaves, or the headline reads `infB/h` and the ramp is pinned red
            """)
    }

    /// Zero is the one reading here that is not an absence. A fleet with nothing
    /// running spends nothing, and printing `0/h` beside the lead is the true
    /// picture of that; answering `nil` instead would drop the supporting reading
    /// off the popover exactly when the news is good.
    func testAFleetSpendingNothingReadsZeroRatherThanNothing() throws {
        let idle = """
        {"fleet": {"tokens": {"window_seconds": 300, "per_second": {"input_tokens": 0.0, \
        "output_tokens": 0.0, "cache_read_input_tokens": 0.0, "cache_creation_input_tokens": 0.0}}}}
        """
        let tokens = try XCTUnwrap(try UsageFixtures.decode(idle, as: UsageReport.self).fleet?.tokens)
        XCTAssertEqual(tokens.perHour(), 0, "a reading of nothing spent, not the absence of a reading")
    }

    func testHistoryBodyDecodes() throws {
        let series = try UsageFixtures.decode(UsageFixtures.history, as: HistorySeries.self)
        XCTAssertEqual(series.label, "main")
        XCTAssertEqual(series.since, Date(timeIntervalSince1970: 1_786_700_000))
        XCTAssertFalse(series.truncated)

        let point = try XCTUnwrap(series.points.first)
        XCTAssertEqual(point.timestamp, Date(timeIntervalSince1970: 1_786_700_123))
        XCTAssertEqual(point.fiveHour, 26.0)
        XCTAssertEqual(point.sevenDay, 99.0)
    }

    func testANullSampleIsNotAReadingOfZero() throws {
        let series = try UsageFixtures.decode(UsageFixtures.historyWithNulls, as: HistorySeries.self)
        let point = try XCTUnwrap(series.points.first)
        XCTAssertNil(point.fiveHour)
        XCTAssertEqual(point.sevenDay, 99.0)
    }

    /// Every type spells its keys out. `.convertFromSnakeCase` maps `five_hour`
    /// to `fiveHour` but `util_5h` to `util5h`, so one of the two would go
    /// missing without a word — this holds that the explicit keys still match
    /// the wire format on both.
    func testTheKeysAreTheWireKeys() throws {
        let usage = try UsageFixtures.decode(UsageFixtures.usage, as: UsageReport.self)
        XCTAssertNotNil(usage.accounts.first?.fiveHour, "five_hour")
        let history = try UsageFixtures.decode(UsageFixtures.history, as: HistorySeries.self)
        XCTAssertNotNil(history.points.first?.fiveHour, "util_5h")
    }

    // MARK: - The rotation

    /// `accounts` in `/gw/status` is a list whose entries name their label, while the
    /// same key in `/gw/usage` is a dictionary keyed by label.
    ///
    /// Only `disabled` says an account is out of the rotation: `disabled_until` is
    /// `null` both in the rotation and out of it with no deadline.
    func testTheRotationIsAListOfAccountsEachNamingItself() throws {
        let status = try UsageFixtures.decode(UsageFixtures.status, as: GatewayStatus.self)
        XCTAssertEqual(status.accounts.map(\.label), ["acc2", "acc3", "main"])
        XCTAssertEqual(Set(status.byLabel.keys), ["acc2", "acc3", "main"])

        let inRotation = try XCTUnwrap(status.byLabel["acc2"])
        XCTAssertFalse(inRotation.disabled)
        XCTAssertNil(inRotation.disabledUntil)
        XCTAssertEqual(inRotation.disabledReason, "")

        let untilAMoment = try XCTUnwrap(status.byLabel["acc3"])
        XCTAssertTrue(untilAMoment.disabled)
        XCTAssertEqual(untilAMoment.disabledUntil, Date(timeIntervalSince1970: 1_788_706_735))
        XCTAssertEqual(untilAMoment.disabledReason,
                       "operator: 22h, switched over from the temporary quota cooldown")
    }

    /// An account nobody switched off that the gateway will not route to is in the
    /// rotation and its box is ticked.
    ///
    /// `disabled` is what the operator set and what the checkbox changes. `eligible`
    /// (`is_eligible`) also folds in the five-hour window, cool-down and token backoff,
    /// so a box drawn from it would clear itself when a window fills. The fixture's
    /// `main` is the only row where the two flags differ.
    func testAnAccountTheGatewayWillNotRouteToIsStillTheOperatorsToSwitch() throws {
        let status = try UsageFixtures.decode(UsageFixtures.status, as: GatewayStatus.self)
        let unroutable = try XCTUnwrap(status.byLabel["main"])
        XCTAssertFalse(unroutable.disabled, """
            nobody switched this account off — the gateway simply has nowhere to route it, \
            which is `eligible: false` beside `disabled: false`
            """)
        XCTAssertTrue(UsagePopoverView.switchAppearance(unroutable, busy: false).ticked,
                      "the box follows the operator's switch, not the gateway's routing")
        XCTAssertNil(unroutable.disabledUntil)
        XCTAssertEqual(unroutable.disabledReason, "")

        // And the flag that was not allowed near the box is counted for the fleet:
        // acc2 alone, with acc3 switched off and main unroutable.
        XCTAssertEqual(status.routableAccounts, 1)
    }

    /// A body that names an account and says nothing about its switch is refused whole,
    /// with the rest of the rotation. Reading a missing `disabled` as "on" would tick
    /// and arm every checkbox on a key that was not in the body.
    func testABodyThatSaysNothingAboutASwitchIsRefusedWhole() {
        XCTAssertThrowsError(try UsageFixtures.decode(UsageFixtures.statusWithoutTheSwitch,
                                                      as: GatewayStatus.self),
                             "a hole where the checkbox's own field goes was read as a state")
    }

    /// A body that says nothing about routing is refused too. `applyRoutable` raises the
    /// line on a zero count, so `?? false` would let silence about `eligible` claim
    /// every client request is a 429. Refused, the pass writes `rotationFailure` and
    /// the boxes go inert. The model's half is
    /// `testARotationWithNoRoutingFlagRaisesNoWarningAtAll`.
    func testABodyThatSaysNothingAboutRoutingIsRefusedWhole() {
        XCTAssertThrowsError(try UsageFixtures.decode(UsageFixtures.statusWithoutTheRoutingFlag,
                                                      as: GatewayStatus.self), """
                             a hole where the fleet's routing flag goes was read as "no route", \
                             which is the one reading that raises a warning out of nothing
                             """)
    }

    /// A switch answer with no `eligible_accounts` is refused: this decoder runs on the
    /// click, and `?? 0` would raise the orange line right then (`warning: null` is
    /// what the gateway sends when there is somewhere to route).
    /// Both halves are asked: the fixture with the count decodes.
    func testASwitchAnswerWithNoCountInItIsRefused() throws {
        XCTAssertThrowsError(try UsageFixtures.decode(UsageFixtures.switchAnswerWithoutTheCount,
                                                      as: SwitchResult.self), """
                             a missing count was read as a fleet with nowhere left to route, on \
                             the one path where that reading is a false alarm under the pointer
                             """)

        let whole = try UsageFixtures.decode(UsageFixtures.switchAnswer, as: SwitchResult.self)
        XCTAssertEqual(whole.eligibleAccounts, 1, "the same body with its count decodes")
    }

    /// A body with no `accounts` at all is refused, while an empty `accounts` decodes.
    /// `?? []` would make `switches` `[:]` rather than `nil` (inert boxes with no
    /// reason shown) and `routableAccounts` zero, which raises the no-route warning.
    /// Both halves are asked.
    func testABodyWithNoAccountsAtAllIsRefusedAndAnEmptyFleetIsNot() throws {
        XCTAssertThrowsError(try UsageFixtures.decode("""
            {"uptime_seconds": 176312.4, "now": 1788653295}
            """, as: GatewayStatus.self),
                             "a body that never mentioned the fleet was read as a fleet of none")

        let empty = try UsageFixtures.decode("""
            {"now": 1788653295, "accounts": []}
            """, as: GatewayStatus.self)
        XCTAssertTrue(empty.accounts.isEmpty, "an empty rotation is an answer and has to decode")
        XCTAssertEqual(empty.routableAccounts, 0)
    }

    /// The four fields and not one more, asked of the type because the risk is
    /// somebody widening it.
    ///
    /// `/gw/status` writes `util_5h`/`util_7d` as fractions; `GET
    /// /gw/usage/<label>/history` writes the same keys as per cent (SPEC §2.7).
    /// Everything downstream is per cent, so a utilisation read here would understate
    /// a hundredfold with nothing looking wrong.
    func testNoUtilisationIsReadOffTheRotationBodyAtAll() throws {
        let status = try UsageFixtures.decode(UsageFixtures.status, as: GatewayStatus.self)
        let account = try XCTUnwrap(status.accounts.first)
        XCTAssertEqual(Set(Mirror(reflecting: account).children.compactMap(\.label)),
                       ["label", "disabled", "disabledUntil", "disabledReason"], """
                       a field was added to AccountSwitch: if it is a reading, it arrived as a \
                       fraction and every per-cent reader downstream will be a hundred times low
                       """)
    }

    /// Each row's token health is read by label, and a row that does not report one has
    /// none: the field draws a note, so a missing key is no note rather than a refused body.
    func testAnAccountsTokenHealthIsReadByLabelAndAMissingOneIsNone() throws {
        let failing = try UsageFixtures.decode(UsageFixtures.statusWithAnAccountThatNeedsALogin,
                                               as: GatewayStatus.self)
        XCTAssertEqual(failing.authByLabel["acc3"],
                       AccountAuth(state: "needs_manual_token",
                                   error: "refresh token rejected (HTTP 400)"))
        XCTAssertEqual(failing.authByLabel["acc2"], AccountAuth(state: "ok", error: ""))

        // `status` names the state on `acc2` only, with no `auth_error` beside it.
        let quiet = try UsageFixtures.decode(UsageFixtures.status, as: GatewayStatus.self)
        XCTAssertEqual(quiet.authByLabel, ["acc2": AccountAuth(state: "ok", error: "")],
                       "a row with no auth_state was given a state it never reported")
    }

    /// The note says what is wrong and, for the account that needs a person, that a click
    /// logs it in; only that note is clickable, and a healthy or unknown state says nothing.
    func testTheAuthNoteNamesTheStateAndWhatToDoAboutIt() throws {
        let dead = try XCTUnwrap(UsagePopoverView.authNote(
            AccountAuth(state: "needs_manual_token", error: "refresh token rejected (HTTP 400)")))
        XCTAssertEqual(dead.text, "needs login")
        XCTAssertEqual(dead.color, .red)
        XCTAssertTrue(dead.opensLogin)
        XCTAssertEqual(dead.help, """
            refresh token rejected (HTTP 400)
            Click to log in again in the browser
            """)
        XCTAssertEqual(UsagePopoverView.authNote(AccountAuth(state: "needs_manual_token", error: ""))?.help,
                       "Click to log in again in the browser")

        let retrying = try XCTUnwrap(UsagePopoverView.authNote(
            AccountAuth(state: "refresh_backoff", error: "token endpoint timed out")))
        XCTAssertEqual(retrying.text, "token renewal failing")
        XCTAssertEqual(retrying.color, .orange)
        XCTAssertFalse(retrying.opensLogin, "a note that heals by itself opened a login page")
        XCTAssertEqual(retrying.help, "token endpoint timed out")
        XCTAssertEqual(UsagePopoverView.authNote(AccountAuth(state: "refresh_backoff", error: ""))?.help,
                       "The gateway keeps retrying")

        XCTAssertNil(UsagePopoverView.authNote(AccountAuth(state: "ok", error: "")))
        XCTAssertNil(UsagePopoverView.authNote(AccountAuth(state: "something_new", error: "x")),
                     "a state this app does not know drew a note it cannot word")
    }

    /// The login page sits under the gateway's address, and the label is a query value
    /// whose `+` is sent as `%2B`: the gateway reads a bare `+` as a space, and
    /// `URLComponents` would read it back as `+` either way, so only the string can tell.
    func testTheLoginLinkCarriesTheLabelToTheGatewaysLoginPage() throws {
        let base = try XCTUnwrap(URL(string: "http://10.20.30.1:8787"))
        let url = try XCTUnwrap(UsagePopoverView.loginURL(base: base, label: "me+claude2@example.com"))
        XCTAssertEqual(url.absoluteString,
                       "http://10.20.30.1:8787/gw/login?account=me%2Bclaude2@example.com")
    }

    /// What either switch endpoint answers with. The body is flat, so the state is read
    /// by the same decoder as the four fields of `/gw/status`.
    /// `warning` is a string or `null`, written as `None if eligible else "…"`: a
    /// sentence and a zero count always arrive together. Both halves are read here.
    func testASwitchAnswersWithTheNewStateAndWhatItCostTheFleet() throws {
        let quiet = try UsageFixtures.decode(UsageFixtures.switchAnswer, as: SwitchResult.self)
        XCTAssertEqual(quiet.account.label, "acc2")
        XCTAssertTrue(quiet.account.disabled, "the state after the switch, off the flat body")
        XCTAssertNil(quiet.account.disabledUntil)
        XCTAssertEqual(quiet.account.disabledReason, "")
        XCTAssertEqual(quiet.eligibleAccounts, 1)
        XCTAssertNil(quiet.warning, "a count above zero comes with no sentence, by the contract")

        let loud = try UsageFixtures.decode(UsageFixtures.switchAnswerWithWarning,
                                            as: SwitchResult.self)
        XCTAssertEqual(loud.account.label, "main")
        XCTAssertTrue(loud.account.disabled)
        XCTAssertEqual(loud.eligibleAccounts, 0)
        XCTAssertEqual(loud.warning, """
            claude-gw: no usable account is left in the fleet - every client request will be \
            answered with 429 until one of them comes back
            """)
    }

    /// Every switch answer this suite holds is a body `_switch_payload` could have
    /// written: the sentence is there exactly when the count is zero.
    ///
    /// Production never reads `SwitchResult.warning`; the count carries the verdict,
    /// which is sound only while the two agree. This test holds the pairing over every
    /// switch answer; `testASwitchAnswersWithTheNewStateAndWhatItCostTheFleet` pins the
    /// wording. It tests our fixtures, not the gateway: none came off the wire.
    ///
    /// The list below is the whole of "every": it is kept by hand, so a new switch
    /// answer is covered only once it is added here. Enumerating `UsageFixtures` by
    /// reflection would still need a hand-kept list of exclusions, and a forgotten
    /// entry is safer than a forgotten exclusion. `switchAnswerWithoutTheCount` is not
    /// here because it does not decode (`testASwitchAnswerWithNoCountInItIsRefused`).
    func testEverySwitchAnswerFixtureOnThisListIsABodyTheGatewayCouldHaveSent() throws {
        let bodies = [
            "switchAnswer": UsageFixtures.switchAnswer,
            "switchAnswerWithWarning": UsageFixtures.switchAnswerWithWarning,
            "switchAnswerContradictingTheClick": UsageFixtures.switchAnswerContradictingTheClick,
            "switchAnswerPuttingTheAccountBack": UsageFixtures.switchAnswerPuttingTheAccountBack,
            "switchAnswerPuttingAcc3Back": UsageFixtures.switchAnswerPuttingAcc3Back
        ]
        for (name, body) in bodies.sorted(by: { $0.key < $1.key }) {
            let answer = try UsageFixtures.decode(body, as: SwitchResult.self)
            XCTAssertEqual(answer.warning != nil, answer.eligibleAccounts == 0, """
                \(name) is not a body the gateway could have sent: eligible_accounts is \
                \(answer.eligibleAccounts) beside warning \
                \(answer.warning.map { "\"\($0)\"" } ?? "null"), where _switch_payload writes the \
                sentence exactly when the count is zero
                """)
        }
    }

    // MARK: - Model routing

    /// The routing rides on `/gw/status` under `config`, as the same object `GET
    /// /gw/routes` answers with, and the accounts beside it decode as before.
    func testTheModelRoutingIsReadOffTheStatusConfig() throws {
        let status = try UsageFixtures.decode(UsageFixtures.statusWithRouting, as: GatewayStatus.self)
        let routing = try XCTUnwrap(status.routing, "the routing under config was not read")
        XCTAssertEqual(routing.alternatives, ["glm (nano-gpt)"])
        XCTAssertEqual(routing.routes, ["sonnet": "glm (nano-gpt)"])
        XCTAssertEqual(routing, try UsageFixtures.decode(UsageFixtures.routes, as: RoutingState.self))
        XCTAssertEqual(status.accounts.map(\.label), ["acc2"])
    }

    /// No routing, and routing that will not decode, is no routing — and never costs the
    /// accounts, which back the checkboxes, where the routing only hides a section.
    func testAStatusWithNoRoutingOrABrokenOneStillDecodesItsAccounts() throws {
        let accounts = """
            "accounts": [{"label": "acc2", "eligible": true, "disabled": false, \
            "disabled_until": null, "disabled_reason": ""}]
            """
        let bodies = [
            "no config": "{\(accounts)}",
            "an older gateway's config": """
                {"config": {"zai": {"enabled": false, "match": "sonnet"}}, \(accounts)}
                """,
            "an alternative with no name": """
                {"config": {"routing": {"alternatives": [{"model": "m"}], "routes": {}}}, \(accounts)}
                """,
            "a route whose target is not a name": """
                {"config": {"routing": {"alternatives": [], "routes": {"sonnet": 3}}}, \(accounts)}
                """,
            "a config that is not an object": "{\"config\": [], \(accounts)}",
        ]
        for (name, body) in bodies.sorted(by: { $0.key < $1.key }) {
            let status = try UsageFixtures.decode(body, as: GatewayStatus.self)
            XCTAssertNil(status.routing, "\(name) was read as a routing")
            XCTAssertEqual(status.accounts.map(\.label), ["acc2"], "\(name) cost the accounts")
        }
    }
}

/// The arithmetic of four differently-priced counters.
final class TokenArithmeticTests: XCTestCase {

    /// Hand-computed from the fixture: 50·1 + 24264·5 + 41120·1.25 + 5401028·0.1
    /// = 50 + 121320 + 51400 + 540102.8.
    func testWeightingOnTheLiveFixture() throws {
        let report = try UsageFixtures.decode(UsageFixtures.sessions, as: SessionsReport.self)
        let tokens = try XCTUnwrap(report.sessions.first).tokens
        XCTAssertEqual(tokens.weighted(), 712_872.8, accuracy: 0.001)
    }

    func testTheWeightsAreThePublishedRatios() {
        let weights = TokenWeights.inputEquivalent
        XCTAssertEqual(weights.input, 1)
        XCTAssertEqual(weights.output, 5, "output is 5x input on Opus, Sonnet and Haiku alike")
        XCTAssertEqual(weights.cacheCreation, 1.25, "the 5-minute TTL write")
        XCTAssertEqual(weights.cacheRead, 0.1)
    }

    /// A counter nobody named is counted as zero, which makes the total a lower
    /// bound — and `isComplete` is the flag that says so.
    func testAnUnnamedCounterCountsAsZeroAndIsAdmitted() {
        let partial = TokenCounts(input: 100, output: nil, cacheCreation: nil, cacheRead: nil)
        XCTAssertEqual(partial.weighted(), 100)
        XCTAssertFalse(partial.isComplete)
    }

    /// The invariant the whole representation exists for: `nil + 5` is 5 as a
    /// lower bound, and that 5 must not pass for a complete answer merely by no
    /// longer being nil.
    func testASumWithAnUnknownSummandDoesNotPretendToBeComplete() {
        let known = TokenCounts(input: 5, output: 5, cacheCreation: 5, cacheRead: 5)
        let unknown = TokenCounts(input: nil, output: 1, cacheCreation: 1, cacheRead: 1)

        let total = known + unknown
        XCTAssertEqual(total.input, 5, "nil + 5 is 5")
        XCTAssertEqual(total.output, 6)
        XCTAssertTrue(known.isComplete)
        XCTAssertFalse(unknown.isComplete)
        XCTAssertFalse(total.isComplete, "one unnamed counter poisons the whole sum")
        XCTAssertFalse((unknown + known).isComplete, "and the order does not matter")
    }

    func testAddingTwoUnknownsKeepsThemUnknown() {
        let left = TokenCounts(input: nil, output: 1, cacheCreation: 1, cacheRead: 1)
        let right = TokenCounts(input: nil, output: 1, cacheCreation: 1, cacheRead: 1)
        XCTAssertNil((left + right).input, "nothing was named, so there is nothing to report")
    }

    /// `.zero` is the seed of every sum, so it has to change neither the numbers
    /// nor their completeness.
    func testZeroIsTheIdentity() {
        let value = TokenCounts(input: 1, output: 2, cacheCreation: 3, cacheRead: 4)
        XCTAssertEqual(TokenCounts.zero + value, value)
        XCTAssertEqual(value + TokenCounts.zero, value)

        let partial = TokenCounts(input: nil, output: 2, cacheCreation: 3, cacheRead: 4)
        XCTAssertEqual(TokenCounts.zero + partial, partial)
        XCTAssertFalse((TokenCounts.zero + partial).isComplete)
        XCTAssertEqual(TokenCounts.zero.weighted(), 0)
    }
}

/// The client: one endpoint per method, and every failure typed rather than
/// fatal.
final class UsageClientTests: XCTestCase {

    /// Remembers the request a stub transport was handed.
    ///
    /// The verb and the body are kept as well as the URL, and only since the
    /// switches arrived: while every call was a GET the method was the one thing
    /// about a request nobody could get wrong.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: URLRequest?
        var url: URL? {
            lock.lock()
            defer { lock.unlock() }
            return stored?.url
        }

        var method: String? {
            lock.lock()
            defer { lock.unlock() }
            return stored?.httpMethod
        }

        var body: Data? {
            lock.lock()
            defer { lock.unlock() }
            return stored?.httpBody
        }

        var contentType: String? {
            lock.lock()
            defer { lock.unlock() }
            return stored?.value(forHTTPHeaderField: "Content-Type")
        }

        func record(_ request: URLRequest) {
            lock.lock()
            stored = request
            lock.unlock()
        }
    }

    private func makeClient(body: String,
                            status: Int = 200,
                            log: RequestLog? = nil,
                            failure: (any Error)? = nil) -> UsageClient {
        UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            log?.record(request)
            if let failure { throw failure }
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            guard let response = HTTPURLResponse(url: url,
                                                 statusCode: status,
                                                 httpVersion: nil,
                                                 headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(body.utf8), response)
        }
    }

    func testSessionsAsksForTheAppliedWindowAndParsesTheBody() async throws {
        let log = RequestLog()
        let client = makeClient(body: UsageFixtures.sessions, log: log)
        let report = try await client.sessions(since: Date(timeIntervalSince1970: 1_786_000_000))

        XCTAssertEqual(log.url?.path, "/gw/sessions")
        XCTAssertEqual(log.url?.query, "since=1786000000")
        XCTAssertEqual(report.sessions.count, 1)
    }

    func testUsageHasNoQuery() async throws {
        let log = RequestLog()
        let client = makeClient(body: UsageFixtures.usage, log: log)
        _ = try await client.usage()

        XCTAssertEqual(log.url?.path, "/gw/usage")
        XCTAssertNil(log.url?.query)
    }

    func testHistoryPutsTheLabelInThePath() async throws {
        let log = RequestLog()
        let client = makeClient(body: UsageFixtures.history, log: log)
        let series = try await client.history(label: "main", since: Date(timeIntervalSince1970: 1_786_000_000))

        XCTAssertEqual(log.url?.path, "/gw/usage/main/history")
        XCTAssertEqual(series.points.count, 1)
    }

    /// The three switch endpoints, each on its own verb. One `fetch` sends all eight
    /// requests this client makes, so the verb is asked for here: a switch sent as a
    /// GET changes nothing. A switch carries no body, meaning "until somebody puts it
    /// back": the gateway takes an expiry only from a `seconds` or `until` key.
    func testTheRotationIsReadWithAGetAndMovedWithAPost() async throws {
        let log = RequestLog()
        let reading = makeClient(body: UsageFixtures.status, log: log)
        let status = try await reading.status()
        XCTAssertEqual(log.url?.path, "/gw/status")
        XCTAssertNil(log.url?.query, "the rotation is the whole fleet's, so there is nothing to ask for")
        XCTAssertEqual(log.method, "GET")
        XCTAssertEqual(status.accounts.count, 3)

        let writing = makeClient(body: UsageFixtures.switchAnswer, log: log)
        let off = try await writing.disableAccount(label: "acc2")
        XCTAssertEqual(log.url?.path, "/gw/accounts/acc2/disable")
        XCTAssertEqual(log.method, "POST")
        XCTAssertNil(log.body, "a body is where a duration would go, and this app never sets one")
        XCTAssertTrue(off.account.disabled)

        _ = try await writing.enableAccount(label: "acc2")
        XCTAssertEqual(log.url?.path, "/gw/accounts/acc2/enable")
        XCTAssertEqual(log.method, "POST")
        XCTAssertNil(log.body)
    }

    /// A route is set with a PUT whose JSON body names the target and cleared with a
    /// DELETE that carries none; both answer with the whole routing.
    func testARouteIsSetWithAPutAndClearedWithADelete() async throws {
        let log = RequestLog()
        let client = makeClient(body: UsageFixtures.routes, log: log)

        let set = try await client.setRoute(key: "sonnet", target: "glm (nano-gpt)")
        XCTAssertEqual(log.url?.path, "/gw/routes/sonnet")
        XCTAssertEqual(log.method, "PUT")
        XCTAssertEqual(log.contentType, "application/json")
        let sent = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(log.body))
        XCTAssertEqual(sent, ["target": "glm (nano-gpt)"])
        XCTAssertEqual(set.routes, ["sonnet": "glm (nano-gpt)"])

        let cleared = try await client.clearRoute(key: "sonnet")
        XCTAssertEqual(log.url?.path, "/gw/routes/sonnet")
        XCTAssertEqual(log.method, "DELETE")
        XCTAssertNil(log.body, "going back to Anthropic names no target")
        XCTAssertNil(log.contentType)
        XCTAssertEqual(cleared.alternatives, ["glm (nano-gpt)"])
    }

    /// The label goes into the path whole, so it is escaped. An unescaped `#` would make
    /// the rest a URL fragment, i.e. a POST to `/gw/accounts/acc`, which could hit
    /// another account.
    func testALabelThatNeedsEscapingIsEscaped() async throws {
        let log = RequestLog()
        let client = makeClient(body: UsageFixtures.switchAnswer, log: log)
        _ = try await client.disableAccount(label: "acc 2#a")

        XCTAssertEqual(log.url?.absoluteString,
                       Config.default.resolvedUsageBaseURL.absoluteString
                       + "/gw/accounts/acc%202%23a/disable")
        XCTAssertEqual(log.url?.path, "/gw/accounts/acc 2#a/disable",
                       "escaped on the wire and the label again when read back")
        XCTAssertNil(log.url?.fragment, "the # is part of the label, not the start of a fragment")
    }

    /// Five seconds, and never a cached body: the numbers move every minute and
    /// a cache hit would be shown as a fresh reading.
    func testRequestsTimeOutAndIgnoreTheCache() async throws {
        let client = UsageClient(baseURL: Config.default.resolvedUsageBaseURL) { request in
            XCTAssertEqual(request.timeoutInterval, 5)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(request.httpMethod, "GET")
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(UsageFixtures.usage.utf8), response)
        }
        _ = try await client.usage()
    }

    func testANonSuccessStatusIsAnError() async {
        let client = makeClient(body: "not found", status: 404)
        await assertFails(UsageError.status(404)) { _ = try await client.usage() }
    }

    func testABodyThatIsNotJSONIsAnError() async {
        let client = makeClient(body: "<html>relay is up, gateway is not</html>")
        await assertFails(UsageError.malformed("not JSON")) { _ = try await client.usage() }
    }

    func testAMissingRequiredFieldIsNamed() async {
        let client = makeClient(body: "{\"sessions\": []}")
        await assertFails(UsageError.malformed("no since")) {
            _ = try await client.sessions(since: Date())
        }
    }

    func testAConnectionThatDropsIsAnError() async {
        let client = makeClient(body: "", failure: URLError(.networkConnectionLost))
        do {
            _ = try await client.usage()
            XCTFail("a dropped connection has to surface as an error")
        } catch let error as UsageError {
            guard case .unreachable = error else {
                return XCTFail("expected .unreachable, got \(error)")
            }
        } catch {
            XCTFail("expected a UsageError, got \(error)")
        }
    }

    private func assertFails(_ expected: UsageError,
                             file: StaticString = #filePath,
                             line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as UsageError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected a UsageError, got \(error)", file: file, line: line)
        }
    }
}

/// Finding out which directories hold a session's transcript, from what Claude
/// Code left on disk. Nothing here opens a transcript, and the fixtures are
/// deliberately not valid JSON — a reader would have to fail on them.
final class UsageIndexTests: XCTestCase {

    private func makeProjectsDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A transcript filed under the slug of `directory`, exactly where Claude
    /// Code files one. The bytes are gibberish on purpose.
    private func file(_ sessionId: String, under directory: String, in root: URL) throws {
        let slug = root.appendingPathComponent(ClaudeSessions.slug(forPath: directory))
        try FileManager.default.createDirectory(at: slug, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: slug.appendingPathComponent("\(sessionId).jsonl"))
    }

    /// One session resumed in another directory has two files under two slugs,
    /// and both have to come back. Taking the first one found is the defect this
    /// suite exists for: the winner was whichever directory the walk reached
    /// first, and that could change between two polls.
    func testEverySlugHoldingTheSessionIsFound() throws {
        let root = try makeProjectsDirectory()
        let sessionId = UUID().uuidString
        try file(sessionId, under: "/Users/x/one", in: root)
        try file(sessionId, under: "/Users/x/two", in: root)

        XCTAssertEqual(UsageIndex.slugsBySessionId(for: [sessionId], projectsDirectory: root)[sessionId],
                       ["-Users-x-one", "-Users-x-two"],
                       "both copies, sorted, so two polls describe the session the same way")
    }

    /// Subagent transcripts live one level down, in `<sessionId>/subagents/`, and
    /// are not sessions the gateway ever reports.
    func testSubagentTranscriptsAreNotListed() throws {
        let root = try makeProjectsDirectory()
        let sessionId = UUID().uuidString
        try file(sessionId, under: "/Users/x/project", in: root)
        let nested = root.appendingPathComponent("-Users-x-project")
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: nested.appendingPathComponent("agent-deadbeef.jsonl"))

        let found = UsageIndex.slugsBySessionId(for: [sessionId, "agent-deadbeef"],
                                                projectsDirectory: root)
        XCTAssertEqual(found[sessionId], ["-Users-x-project"])
        XCTAssertNil(found["agent-deadbeef"], "a subagent is not a session")
    }

    /// A session running on another machine reports to the same gateway and has
    /// no transcript here. Ordinary, not an error.
    func testASessionWithNoTranscriptIsSimplyAbsent() throws {
        let root = try makeProjectsDirectory()
        XCTAssertTrue(UsageIndex.slugsBySessionId(for: ["nowhere-\(UUID().uuidString)"],
                                                  projectsDirectory: root).isEmpty)
    }

    func testAskingForNothingReadsNothing() throws {
        let root = try makeProjectsDirectory()
        XCTAssertTrue(UsageIndex.slugsBySessionId(for: [], projectsDirectory: root).isEmpty)
    }

    /// Several chats of the same project are several sessions in one directory,
    /// which is the ordinary case rather than a collision.
    func testSeveralSessionsOfOneDirectoryAreAllFound() throws {
        let root = try makeProjectsDirectory()
        let identifiers = [UUID().uuidString, UUID().uuidString]
        for sessionId in identifiers { try file(sessionId, under: "/Users/x/project", in: root) }

        let found = UsageIndex.slugsBySessionId(for: Set(identifiers), projectsDirectory: root)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.values), [["-Users-x-project"]])
    }
}

/// The whole join, over real directories: what Claude Code writes on disk, what
/// the gateway reports, and which row the number ends up on.
///
/// Built out of temporary directories rather than dictionaries because the rule
/// under test *is* the correspondence between a project on disk and a slug
/// directory on disk. A test that hands `assemble` a slug it computed itself
/// would agree with any slug function at all, including a wrong one.
final class UsageAttributionTests: XCTestCase {

    private var base = URL(fileURLWithPath: "/")
    private var projectsRoot = URL(fileURLWithPath: "/")
    /// Stands in for `~/.claude/projects`.
    private var transcripts = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-attribution-\(UUID().uuidString)")
        projectsRoot = base.appendingPathComponent("Projects")
        transcripts = base.appendingPathComponent("claude-projects")
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        addTeardownBlock { [base] in try? FileManager.default.removeItem(at: base) }
    }

    /// A project directory, with the named worktrees under it.
    private func makeProject(_ name: String, worktrees: [String] = []) throws -> ProjectInfo {
        let path = projectsRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        for worktree in worktrees {
            try FileManager.default.createDirectory(at: worktreePath(of: path.path, worktree),
                                                    withIntermediateDirectories: true)
        }
        return TestFixtures.project(path: path.path, rootName: name)
    }

    private func worktreePath(of project: String, _ name: String) -> URL {
        URL(fileURLWithPath: project)
            .appendingPathComponent(".claude/worktrees")
            .appendingPathComponent(name)
    }

    /// One transcript, filed under the slug of the directory the session started
    /// in. The bytes are gibberish: attribution must not depend on them.
    ///
    /// `writtenAt` dates the file, which is the one thing about it anything reads:
    /// a life last written to before a window opened cannot have spent inside it
    /// (`UsageIndex.narrowToWindow`). Left out, the file is dated now, which is
    /// inside every window a test can ask about.
    @discardableResult
    private func file(_ sessionId: String,
                      startedIn directory: String,
                      writtenAt: Date? = nil) throws -> String {
        let slugName = ClaudeSessions.slug(forPath: directory)
        let slug = transcripts.appendingPathComponent(slugName)
        try FileManager.default.createDirectory(at: slug, withIntermediateDirectories: true)
        let transcript = slug.appendingPathComponent("\(sessionId).jsonl")
        try Data("not json at all".utf8).write(to: transcript)
        if let writtenAt {
            try FileManager.default.setAttributes([.modificationDate: writtenAt],
                                                  ofItemAtPath: transcript.path)
        }
        return slugName
    }

    /// One subagent transcript of that session, where Claude Code puts it:
    /// `<slug>/<sessionId>/subagents/`. `nested` puts it where workflow agents write:
    /// `subagents/workflows/wf_<id>/`. The gateway reports one aggregate per
    /// `session_id` while subagents write to other files, so the session file's mtime
    /// alone does not say whether the life was written to.
    @discardableResult
    private func subagentFile(_ name: String,
                              of sessionId: String,
                              startedIn directory: String,
                              writtenAt: Date,
                              nested: String? = nil) throws -> String {
        let slugName = ClaudeSessions.slug(forPath: directory)
        var directory = transcripts.appendingPathComponent(slugName)
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")
        if let nested { directory = directory.appendingPathComponent(nested) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("\(name).jsonl")
        try Data("not json at all".utf8).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: writtenAt],
                                              ofItemAtPath: path.path)
        return slugName
    }

    /// A subagent entry the directory listing names and `stat(2)` then refuses. A
    /// dangling symlink makes that deterministic: `contentsOfDirectory` returns the
    /// name, and `fileStamp`'s `stat` follows the link and fails, as for a file removed
    /// between listing and stamp. `nested` places it as `subagentFile` does.
    @discardableResult
    private func unstatableSubagentFile(_ name: String,
                                        of sessionId: String,
                                        startedIn directory: String,
                                        nested: String? = nil) throws -> String {
        let slugName = ClaudeSessions.slug(forPath: directory)
        var subagents = transcripts.appendingPathComponent(slugName)
            .appendingPathComponent(sessionId)
            .appendingPathComponent("subagents")
        if let nested { subagents = subagents.appendingPathComponent(nested) }
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: subagents.appendingPathComponent("\(name).jsonl"),
            withDestinationURL: subagents.appendingPathComponent("removed-\(name).jsonl"))
        return slugName
    }

    private func session(_ identifier: String, input: Int) throws -> GatewaySession {
        try UsageFixtures.decode("""
        {"session_id": "\(identifier)", "input_tokens": \(input), "output_tokens": 0,
         "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
        """, as: GatewaySession.self)
    }

    /// The path the app takes: list the slug directories, fold the gateway's
    /// figures onto them, assemble the rows.
    private func attribute(_ sessions: [GatewaySession], projects: [ProjectInfo])
        -> (snapshot: SwitcherSnapshot, unmatched: TokenCounts, unmatchedSessions: Int) {
        let slugs = UsageIndex.slugsBySessionId(for: Set(sessions.map(\.sessionId)),
                                                projectsDirectory: transcripts)
        let folded = UsageIndex.fold(sessions: sessions, slugsBySessionId: slugs)
        // The window step the app takes between the fold and the assembly. Every
        // transcript these tests write is dated now, so nothing here is narrowed
        // away; it is in the path because leaving it out would make this helper a
        // different pipeline from the one it stands for.
        let contested = UsageIndex.narrowToWindow(
            folded.contested,
            since: Date().addingTimeInterval(-UsageStore.windowSeconds),
            projectsDirectory: transcripts)
        let snapshot = DataSource.assemble(projects: projects,
                                           windows: [],
                                           sessions: [],
                                           tokensBySlug: folded.tokensBySlug,
                                           contested: contested,
                                           worktrees: DataSource.worktrees(of: projects),
                                           accessibilityTrusted: true)
        return (snapshot, folded.unmatched, folded.unmatchedSessions)
    }

    private func spend(_ project: ProjectInfo, in snapshot: SwitcherSnapshot) -> Int? {
        snapshot.projects.first { $0.project?.path == project.path }?.usage?.input
    }

    /// The ordinary case: the session started in the project, so its file sits
    /// under the project's own slug.
    ///
    /// Checked by deleting the line that enters a project's own slug in
    /// `projectPathsBySlug`: this and most of the file below it fail.
    func testSpendUnderAProjectsOwnSlugLandsOnItsRow() throws {
        let project = try makeProject("switcher")
        try file("s1", startedIn: project.path)

        let result = attribute([try session("s1", input: 10)], projects: [project])
        XCTAssertEqual(spend(project, in: result.snapshot), 10)
        XCTAssertEqual(result.unmatchedSessions, 0)
    }

    /// A session started in a worktree belongs to the worktree's project: nothing opens
    /// a window on `.claude/worktrees/<name>`. The slug alone cannot answer this
    /// (`-x-portainer-` also prefixes `portainer-agent`'s slug); it is answered from the
    /// listed worktree directories, `DataSource.worktrees(of:)`.
    func testSpendUnderAWorktreeSlugLandsOnTheProjectsRow() throws {
        let project = try makeProject("switcher", worktrees: ["usage-ui"])
        try file("s1", startedIn: worktreePath(of: project.path, "usage-ui").path)

        let result = attribute([try session("s1", input: 7)], projects: [project])
        XCTAssertEqual(spend(project, in: result.snapshot), 7)
    }

    /// A slug that is no project and no worktree of one — an agent node's
    /// directory, `/private/tmp`, anything outside the scan roots — is not
    /// forced onto a row. It stays in the gateway's totals and belongs to
    /// nobody, which is what the app already says about spend it cannot place.
    func testASlugThatMatchesNoProjectLandsOnNoRow() throws {
        let project = try makeProject("switcher")
        try file("s1", startedIn: "/private/tmp/somewhere-else")

        let result = attribute([try session("s1", input: 10)], projects: [project])
        XCTAssertNil(spend(project, in: result.snapshot),
                     "the only project must not inherit a directory that is not it")
        XCTAssertEqual(result.snapshot.ambiguousUsageSessions, 0,
                       "one candidate is not a contest, however little it matches")
    }

    /// A session with no transcript here at all — the agent nodes run their own
    /// Claude Code and report to the same gateway. Real spend with no local
    /// owner, counted as such rather than dropped.
    func testASessionWithNoTranscriptAtAllIsUnmatched() throws {
        let project = try makeProject("switcher")

        let result = attribute([try session("elsewhere", input: 7)], projects: [project])
        XCTAssertEqual(result.unmatchedSessions, 1)
        XCTAssertEqual(result.unmatched.input, 7, "counted, and counted as nobody's")
        XCTAssertNil(spend(project, in: result.snapshot))
    }

    /// Two copies of one session, both inside one project — the session was
    /// resumed in a worktree of the project it started in. One session, one
    /// aggregate from the gateway, one number on the row.
    ///
    /// Checked by summing the contested tokens once per candidate slug in
    /// `settle`: this test fails with 20 and nothing else notices.
    func testTwoCopiesInsideOneProjectAreCountedOnceAndNotTwice() throws {
        let project = try makeProject("switcher", worktrees: ["usage-ui"])
        try file("s1", startedIn: project.path)
        try file("s1", startedIn: worktreePath(of: project.path, "usage-ui").path)

        let result = attribute([try session("s1", input: 10)], projects: [project])
        XCTAssertEqual(spend(project, in: result.snapshot), 10, "one session, one aggregate, once")
        XCTAssertEqual(result.snapshot.ambiguousUsageSessions, 0,
                       "two directories of one project are not a disagreement")
    }

    /// Two copies in two different projects. The gateway reports one aggregate per
    /// session with nothing to divide it by, so neither project gets it and the spend
    /// is reported as ambiguous rather than resolved by directory order.
    func testTwoCopiesInTwoProjectsGoToTheAmbiguousBucket() throws {
        let first = try makeProject("switcher")
        let second = try makeProject("home-network")
        try file("s1", startedIn: first.path)
        try file("s1", startedIn: second.path)

        let result = attribute([try session("s1", input: 12)], projects: [first, second])
        XCTAssertNil(spend(first, in: result.snapshot))
        XCTAssertNil(spend(second, in: result.snapshot))
        XCTAssertEqual(result.snapshot.ambiguousUsageSessions, 1)
        XCTAssertEqual(result.snapshot.ambiguousUsage.input, 12, "counted, and named as nobody's")
    }

    /// The slug replaces every character outside `[A-Za-z0-9-]`, not just the
    /// separator, and cannot be turned back into a path. So the match runs
    /// forwards, through `ClaudeSessions.slug(forPath:)`.
    ///
    /// Checked by matching on a naive `/` → `-` replacement instead: the
    /// underscore and the dot survive, the slug does not match, and this test
    /// fails while every other project name in the file goes on matching.
    func testAProjectWithUnderscoresAndDotsInItsNameStillMatches() throws {
        let project = try makeProject("my_project.v2")
        try file("s1", startedIn: project.path)

        XCTAssertTrue(ClaudeSessions.slug(forPath: project.path).hasSuffix("-my-project-v2"),
                      "the name is not recoverable from the slug, which is the point")
        let result = attribute([try session("s1", input: 5)], projects: [project])
        XCTAssertEqual(spend(project, in: result.snapshot), 5)
    }

    /// The line `--dump` prints about the bucket. Silence would be the same
    /// silent loss the split exists to stop, one level up.
    ///
    /// One line per window, and the window is in the label: the two buckets hold
    /// two different sets of sessions, so a line that did not say which window it
    /// counted would be two facts wearing one name.
    func testTheDumpNamesTheAmbiguousBucketAndCountsIt() throws {
        let first = try makeProject("switcher")
        let second = try makeProject("home-network")
        try file("s1", startedIn: first.path)
        try file("s1", startedIn: second.path)

        let result = attribute([try session("s1", input: 12)], projects: [first, second])
        XCTAssertEqual(ConsoleDump.ambiguousLine(window: "7d",
                                                 sessions: result.snapshot.ambiguousUsageSessions,
                                                 tokens: result.snapshot.ambiguousUsage),
                       "ambiguous 7d:        1 sessions, 12 ie (in 12, out 0, cw 0, cr 0)")
        XCTAssertEqual(ConsoleDump.ambiguousLine(window: "1h", sessions: 0, tokens: .zero),
                       "ambiguous 1h:        0 sessions, -",
                       "and it is printed when the bucket is empty: a line that appears only "
                       + "when it is non-empty teaches nobody the bucket exists")
    }

    /// Every figure in the usage section starts in one column, sized for the widest
    /// label; `column` pads but never truncates, so a longer label would shift its
    /// figure silently.
    ///
    /// Asked of the whole assembled section (`ConsoleDump.usageLines`), with both
    /// optional lines (`unavailable:`, `window:`) forced out so all twelve labels are
    /// measured.
    func testTheUsageSectionsFiguresAllStartInOneColumn() throws {
        var usage = UsageSnapshot.empty
        usage.sessionsFailure = "/gw/sessions: timed out"
        usage.since = Date().addingTimeInterval(-UsageStore.windowSeconds)
        let lines = ConsoleDump.usageLines(usage, snapshot: .empty)

        XCTAssertEqual(lines.count, 12,
                       "the fixture has to reach every line of the section, the two conditional "
                       + "ones included, or the labels it does not draw go unmeasured")
        for line in lines {
            // The label is everything up to its colon; the figure starts at the
            // first non-blank after the padding. Asking where the padding ends is
            // the whole property — `column` never truncates, so a label wider than
            // the width simply moves its own figure right.
            let colon = try XCTUnwrap(line.firstIndex(of: ":"), "no label in \(line)")
            let figure = try XCTUnwrap(line[line.index(after: colon)...].firstIndex { $0 != " " },
                                       "no figure in \(line)")
            XCTAssertEqual(line.distance(from: line.startIndex, to: figure),
                           2 + ConsoleDump.usageLabelWidth,
                           "\(line) does not line up with the rest of the section")
        }
    }

    /// The lead line of the section, asserted whole.
    ///
    /// The two rates in the fixture differ, so swapping them is visible, and the per
    /// cent differs from the refill rate, so printing one for the other is visible.
    /// The first half is a live line; the second is the fleet of
    /// `testTheFigureIsBuiltFromRawPointsRatherThanSmoothedOnes`: one account pinned at
    /// its ceiling for four samples of five beside one burning 50 pp over 48 h, i.e.
    /// 1.042 pp/h against 1.190 refilled, with the `≥` a suppressed burn requires.
    func testTheLeadLineNamesTheRatioItsDepthAndBothSidesOfTheDivision() throws {
        func burnLine(_ burn: FleetCapacity.FleetBurn) throws -> String {
            var usage = UsageSnapshot.empty
            usage.fleetBurn = burn
            let lines = ConsoleDump.usageLines(usage, snapshot: .empty)
            return try XCTUnwrap(lines.first { $0.contains("burn vs refill:") },
                                 "the section has no lead line at all")
        }

        XCTAssertEqual(
            // The refill rate is the expression production computes, not the
            // three digits it prints: built from the printed `1.786` the fixture
            // was an object the app cannot produce, and its per cent — derived
            // from that rounding — was 170.605 where the value gives 170.632.
            try burnLine(FleetCapacity.FleetBurn(percent: 170.632, burnRate: 3.047,
                                                 refillRate: 3 * 100.0 / 168, accounts: 3,
                                                 measuredHours: 43.09, isLowerBound: false)),
            "  burn vs refill:      171%, 3 accounts over 43.1 h,"
                + " 3.047 pp/h burned vs 1.786 pp/h refilled", """
            the live line of 2026-09-05 15:33:41Z, and every number in it is one of the figure's \
            own: swapping the two rates draws a fleet burning 1.7 times faster than it refills as \
            one burning 0.6 times as fast, and printing the refill rate as the per cent answers 2%
            """)

        XCTAssertEqual(
            try burnLine(FleetCapacity.FleetBurn(percent: 87.5, burnRate: 100.0 / 96,
                                                 refillRate: 200.0 / 168, accounts: 2,
                                                 measuredHours: 48, isLowerBound: true)),
            "  burn vs refill:      88% (>=), 2 accounts over 48.0 h,"
                + " 1.042 pp/h burned vs 1.190 pp/h refilled",
            "an account's burn was suppressed by its ceiling and the line printed the floor as a "
                + "reading: `(>=)` is the panel's `≥` spelled for a terminal")
    }

    /// The hour has its own ambiguous bucket, filled by the hour's contested sessions.
    /// The fixture has a session contested over the hour and absent from the week's
    /// report, as when the two `/gw/sessions` calls fail apart (§2.9); a shared bucket
    /// would report this spend under `7d` or not at all.
    func testTheHourHasItsOwnAmbiguousBucket() throws {
        let first = try makeProject("switcher")
        let second = try makeProject("home-network")
        try file("s1", startedIn: first.path)
        try file("s1", startedIn: second.path)

        let hourly = UsageIndex.fold(sessions: [try session("s1", input: 12)],
                                     slugsBySessionId: UsageIndex.slugsBySessionId(
                                        for: ["s1"], projectsDirectory: transcripts))
        XCTAssertEqual(hourly.contested.count, 1, "the fixture has to be contested to be about this")
        let snapshot = DataSource.assemble(projects: [first, second],
                                           windows: [],
                                           sessions: [],
                                           tokensBySlug: [:],
                                           contested: [],
                                           hourlyTokensBySlug: hourly.tokensBySlug,
                                           hourlyContested: hourly.contested,
                                           worktrees: DataSource.worktrees(of: [first, second]),
                                           accessibilityTrusted: true)

        XCTAssertEqual(snapshot.ambiguousHourlySessions, 1)
        XCTAssertEqual(snapshot.ambiguousHourlyUsage.input, 12, "counted, and named as nobody's")
        XCTAssertEqual(snapshot.ambiguousUsageSessions, 0,
                       "the week's bucket did not inherit the hour's session")
        XCTAssertEqual(snapshot.ambiguousUsage, .zero)
        // The row is unwrapped first, on purpose: `first {…}?.hourlyUsage` is `nil`
        // when there is no such row at all, so the assertion would pass without
        // ever having asked about the spend.
        for path in [first.path, second.path] {
            let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == path },
                                    "no row for \(path) to refuse the spend")
            XCTAssertNil(row.hourlyUsage, "contested spend landed on a row anyway")
        }
    }

    /// And the control half: the same session, both copies inside one project, is
    /// not a contest at all — its hourly figure lands on the row.
    ///
    /// Without it the test above passes for any rule that refuses everything.
    func testAnHourlySessionWhoseSlugsAgreeLandsOnTheRow() throws {
        let project = try makeProject("switcher", worktrees: ["usage-ui"])
        try file("s1", startedIn: project.path)
        try file("s1", startedIn: worktreePath(of: project.path, "usage-ui").path)

        let hourly = UsageIndex.fold(sessions: [try session("s1", input: 12)],
                                     slugsBySessionId: UsageIndex.slugsBySessionId(
                                        for: ["s1"], projectsDirectory: transcripts))
        XCTAssertEqual(hourly.contested.count, 1, "still contested at the fold; the project settles it")
        let snapshot = DataSource.assemble(projects: [project],
                                           windows: [],
                                           sessions: [],
                                           hourlyTokensBySlug: hourly.tokensBySlug,
                                           hourlyContested: hourly.contested,
                                           worktrees: DataSource.worktrees(of: [project]),
                                           accessibilityTrusted: true)

        let row = snapshot.projects.first { $0.project?.path == project.path }
        XCTAssertEqual(row?.hourlyUsage?.input, 12, "one session, one aggregate, once")
        XCTAssertEqual(snapshot.ambiguousHourlySessions, 0,
                       "two directories of one project are not a disagreement")
    }

    // MARK: - A session resumed in another project, over two windows

    /// A resumed session cut down to what decides it: a copy under `hammerola` being
    /// written now and a copy under `cad_snapshot_hub` silent for days. Over the week
    /// both lives spent; over the hour only the first could have.
    /// The underscores are deliberate: `cad_snapshot_hub` and `cad-snapshot-hub` slug
    /// identically, so a slug cannot be read back into a directory name.
    private func resumedSession(now: Date, input: Int = 12, silentFor: TimeInterval = 3 * 86_400)
        throws -> (current: ProjectInfo, previous: ProjectInfo, contested: [ContestedSpend]) {
        let current = try makeProject("hammerola")
        let previous = try makeProject("cad_snapshot_hub")
        try file("s1", startedIn: current.path, writtenAt: now)
        try file("s1", startedIn: previous.path, writtenAt: now.addingTimeInterval(-silentFor))

        let folded = UsageIndex.fold(sessions: [try session("s1", input: input)],
                                     slugsBySessionId: UsageIndex.slugsBySessionId(
                                        for: ["s1"], projectsDirectory: transcripts))
        XCTAssertEqual(folded.contested.count, 1, "the fixture has to be contested to be about this")
        return (current, previous, folded.contested)
    }

    /// A live session file for `sessionId`, started in `cwd` — the record outside
    /// the transcript tree that says which life of the session is the current one.
    private func live(_ sessionId: String, startedIn cwd: String) -> ClaudeSessionInfo {
        TestFixtures.session(id: sessionId, cwd: cwd, state: .working)
    }

    private func narrow(_ contested: [ContestedSpend], since: Date) -> [ContestedSpend] {
        UsageIndex.narrowToWindow(contested, since: since, projectsDirectory: transcripts)
    }

    /// The hour gives the contest to the life actually being written (SPEC §2.9).
    /// mtime here is not a tie-break between transcripts (those stay rejected, see
    /// `DataSource.settle`): a file untouched for three days cannot have spent in the
    /// last hour.
    func testTheHourGivesTheContestToTheLifeThatWasWrittenInIt() throws {
        let now = Date()
        let fixture = try resumedSession(now: now)
        let projects = [fixture.current, fixture.previous]

        let snapshot = DataSource.assemble(
            projects: projects,
            windows: [],
            sessions: [live("s1", startedIn: fixture.current.path)],
            hourlyContested: narrow(fixture.contested,
                                    since: now.addingTimeInterval(-UsageStore.hourWindowSeconds)),
            worktrees: DataSource.worktrees(of: projects),
            accessibilityTrusted: true)

        let current = try XCTUnwrap(snapshot.projects.first { $0.project?.path == fixture.current.path })
        let previous = try XCTUnwrap(snapshot.projects.first { $0.project?.path == fixture.previous.path })
        XCTAssertEqual(current.hourlyUsage?.input, 12,
                       "the project being worked in right now still prints no rate")
        XCTAssertNil(previous.hourlyUsage, "the life that has been silent for days took the spend")
        XCTAssertEqual(snapshot.ambiguousHourlySessions, 0)
        XCTAssertEqual(snapshot.ambiguousHourlyUsage, .zero)
    }

    /// The week keeps the same contest ambiguous, because over a week both lives were
    /// running: handing it to `hammerola` would move days of another project's work
    /// onto the wrong row. Keeping only the newest copy would pass the hour's test and
    /// fail this one.
    func testTheWeekKeepsTheSameContestAmbiguousBecauseBothLivesRanInsideIt() throws {
        let now = Date()
        let fixture = try resumedSession(now: now)
        let projects = [fixture.current, fixture.previous]

        let snapshot = DataSource.assemble(
            projects: projects,
            windows: [],
            sessions: [live("s1", startedIn: fixture.current.path)],
            contested: narrow(fixture.contested,
                              since: now.addingTimeInterval(-UsageStore.windowSeconds)),
            worktrees: DataSource.worktrees(of: projects),
            accessibilityTrusted: true)

        for project in projects {
            let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == project.path })
            XCTAssertNil(row.usage, "a week of another project's work landed on \(project.rootName)")
        }
        XCTAssertEqual(snapshot.ambiguousUsageSessions, 1)
        XCTAssertEqual(snapshot.ambiguousUsage.input, 12, "counted, and still named as nobody's")
    }

    /// A copy that cannot be stat'ed keeps its claim on the window. A copy can vanish
    /// between listing and stat; if it was the winning one, dropping it would leave a
    /// single claim and `settle` would put the spend on the wrong row.
    ///
    /// `wasWrittenInWindow` stats two kinds of file, the parent transcript and every
    /// `*.jsonl` under `subagents/`, each with its own `else { return true }`, so both
    /// are asked. Four lives: written inside the window (kept), three days stale
    /// (dropped, the control), transcript missing (kept), stale transcript with an
    /// unstatable subagent entry (kept).
    func testACopyThatCannotBeStatedKeepsItsClaimOnTheWindow() throws {
        let now = Date()
        let longAgo = now.addingTimeInterval(-3 * 86_400)
        let fresh = try makeProject("hammerola")
        let stale = try makeProject("cad_snapshot_hub")
        let vanishing = try makeProject("research_mcp")
        let racing = try makeProject("ukuetis_site")
        try file("s1", startedIn: fresh.path, writtenAt: now)
        try file("s1", startedIn: stale.path, writtenAt: longAgo)
        let vanished = try file("s1", startedIn: vanishing.path, writtenAt: now)
        // Stale by its own transcript, so the listing is reached, and the only
        // thing the listing names is a file the stamp cannot answer about.
        try file("s1", startedIn: racing.path, writtenAt: longAgo)
        let raced = try unstatableSubagentFile("agent-1", of: "s1", startedIn: racing.path)

        // Listed first and removed second, which is the order the race takes: the
        // slug is in the contest because the listing saw it, and the file is gone
        // by the time the stamp is asked for.
        let contested = UsageIndex.fold(
            sessions: [try session("s1", input: 12)],
            slugsBySessionId: UsageIndex.slugsBySessionId(for: ["s1"],
                                                          projectsDirectory: transcripts)).contested
        XCTAssertEqual(contested.first?.slugs.count, 4, "the fixture has to hold all four lives")
        try FileManager.default.removeItem(at: transcripts.appendingPathComponent(vanished)
                                            .appendingPathComponent("s1.jsonl"))

        // The fourth life is only about the subagent branch if the listing really
        // does name the file and the stamp really is what fails. Both halves are
        // asked, because a fixture that quietly listed nothing would pass the
        // assertion below for the wrong reason.
        let subagents = transcripts.appendingPathComponent(raced)
            .appendingPathComponent("s1/subagents")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: subagents.path),
                       ["agent-1.jsonl"], "the listing has to name the file for this to be the race")
        XCTAssertNil(fileStamp(atPath: subagents.appendingPathComponent("agent-1.jsonl").path),
                     "and the stamp has to be the half that fails")

        let survivors = Set(narrow(contested,
                                   since: now.addingTimeInterval(-UsageStore.hourWindowSeconds))
            .first?.slugs ?? [])
        XCTAssertTrue(survivors.contains(ClaudeSessions.slug(forPath: fresh.path)),
                      "the life written inside the window lost its claim")
        XCTAssertTrue(survivors.contains(vanished),
                      "a copy that could not be stat'ed was dropped from the contest, which is "
                      + "how a whole session's spend is handed to whichever copy is left")
        XCTAssertTrue(survivors.contains(raced),
                      "a copy whose subagent file could not be stat'ed was dropped, which costs "
                      + "exactly what the parent transcript's half of this rule costs")
        XCTAssertFalse(survivors.contains(ClaudeSessions.slug(forPath: stale.path)),
                       "a life three days out of the window kept its claim, so this fixture "
                       + "would agree with a rule that narrows nothing")
    }

    /// A life whose subagent is writing could have spent, even while the session's own
    /// transcript stands still: subagent records go to
    /// `<slug>/<sessionId>/subagents/agent-*.jsonl` (§2.6.3) while the gateway reports
    /// one aggregate per `session_id`. The live-session veto is no backstop: it only
    /// sees sessions started from the VSCode extension.
    /// Both lives have a `subagents/` directory: what keeps the first is a write inside
    /// the window, not having subagents.
    func testASubagentWritingKeepsALifeWhoseTranscriptStandsStill() throws {
        let now = Date()
        let longAgo = now.addingTimeInterval(-3 * 86_400)
        let working = try makeProject("hammerola")
        let quiet = try makeProject("cad_snapshot_hub")
        try file("s1", startedIn: working.path, writtenAt: longAgo)
        try subagentFile("agent-1", of: "s1", startedIn: working.path, writtenAt: now)
        try file("s1", startedIn: quiet.path, writtenAt: longAgo)
        try subagentFile("agent-1", of: "s1", startedIn: quiet.path, writtenAt: longAgo)

        let contested = UsageIndex.fold(
            sessions: [try session("s1", input: 12)],
            slugsBySessionId: UsageIndex.slugsBySessionId(for: ["s1"],
                                                          projectsDirectory: transcripts)).contested
        XCTAssertEqual(contested.first?.slugs.count, 2, "the fixture has to be contested")

        let survivors = narrow(contested,
                               since: now.addingTimeInterval(-UsageStore.hourWindowSeconds))
            .first?.slugs
        XCTAssertEqual(survivors, [ClaudeSessions.slug(forPath: working.path)],
                       "the life being written to by a subagent was narrowed away, and the "
                       + "contest handed to the copy a resume had merely touched")
    }

    /// A workflow agent writing keeps the life too, though it writes two levels deeper:
    /// `subagents/workflows/wf_<id>/`. Here the flat `subagents/` file is stale and only
    /// the workflow agent's is fresh; both lives share the nested layout, so the date
    /// decides, not the shape.
    func testAWorkflowAgentWritingKeepsALifeWhoseTranscriptStandsStill() throws {
        let now = Date()
        let longAgo = now.addingTimeInterval(-3 * 86_400)
        let working = try makeProject("hammerola")
        let quiet = try makeProject("cad_snapshot_hub")
        for life in [working, quiet] {
            try file("s1", startedIn: life.path, writtenAt: longAgo)
            try subagentFile("agent-0", of: "s1", startedIn: life.path, writtenAt: longAgo)
        }
        try subagentFile("agent-1", of: "s1", startedIn: working.path, writtenAt: now,
                         nested: "workflows/wf_x")
        try subagentFile("agent-1", of: "s1", startedIn: quiet.path, writtenAt: longAgo,
                         nested: "workflows/wf_x")

        let contested = UsageIndex.fold(
            sessions: [try session("s1", input: 12)],
            slugsBySessionId: UsageIndex.slugsBySessionId(for: ["s1"],
                                                          projectsDirectory: transcripts)).contested
        XCTAssertEqual(contested.first?.slugs.count, 2, "the fixture has to be contested")

        let survivors = narrow(contested,
                               since: now.addingTimeInterval(-UsageStore.hourWindowSeconds))
            .first?.slugs
        XCTAssertEqual(survivors, [ClaudeSessions.slug(forPath: working.path)],
                       "the life being written to by a workflow agent was narrowed away, and "
                       + "the contest handed to the copy a resume had merely touched")
    }

    /// A workflow agent's file that cannot be stat'ed keeps the claim as well: the rule
    /// of `testACopyThatCannotBeStatedKeepsItsClaimOnTheWindow` at workflow depth. The
    /// racing life holds only `workflows/wf_x/` with a dangling `agent-1.jsonl`; a fresh
    /// and a stale life are the controls.
    func testAWorkflowAgentFileThatCannotBeStatedKeepsItsClaimOnTheWindow() throws {
        let now = Date()
        let longAgo = now.addingTimeInterval(-3 * 86_400)
        let fresh = try makeProject("hammerola")
        let stale = try makeProject("cad_snapshot_hub")
        let racing = try makeProject("ukuetis_site")
        try file("s1", startedIn: fresh.path, writtenAt: now)
        try file("s1", startedIn: stale.path, writtenAt: longAgo)
        try file("s1", startedIn: racing.path, writtenAt: longAgo)
        let raced = try unstatableSubagentFile("agent-1", of: "s1", startedIn: racing.path,
                                               nested: "workflows/wf_x")

        let contested = UsageIndex.fold(
            sessions: [try session("s1", input: 12)],
            slugsBySessionId: UsageIndex.slugsBySessionId(for: ["s1"],
                                                          projectsDirectory: transcripts)).contested
        XCTAssertEqual(contested.first?.slugs.count, 3, "the fixture has to hold all three lives")

        let workflow = transcripts.appendingPathComponent(raced)
            .appendingPathComponent("s1/subagents/workflows/wf_x")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workflow.path),
                       ["agent-1.jsonl"], "the listing has to name the file for this to be the race")
        XCTAssertNil(fileStamp(atPath: workflow.appendingPathComponent("agent-1.jsonl").path),
                     "and the stamp has to be the half that fails")

        let survivors = Set(narrow(contested,
                                   since: now.addingTimeInterval(-UsageStore.hourWindowSeconds))
            .first?.slugs ?? [])
        XCTAssertTrue(survivors.contains(ClaudeSessions.slug(forPath: fresh.path)),
                      "the life written inside the window lost its claim")
        XCTAssertTrue(survivors.contains(raced),
                      "a copy whose workflow agent's file could not be stat'ed was dropped")
        XCTAssertFalse(survivors.contains(ClaudeSessions.slug(forPath: stale.path)),
                       "a life three days out of the window kept its claim, so this fixture "
                       + "would agree with a rule that narrows nothing")
    }

    /// A live session whose own life was narrowed out of the window while a rival copy
    /// was written inside it: the safe answer is ambiguous.
    ///
    /// A running session always has a transcript under its start directory's slug, so
    /// the live slug is among the copies; what removes it is the narrowing (its own
    /// transcript silent longer than the window while the other life of the same
    /// `session_id` is written). Without the veto this spend lands on `hammerola`.
    func testALiveSessionWhoseOwnLifeFellOutOfTheWindowLeavesTheContestAmbiguous() throws {
        let now = Date()
        let fixture = try resumedSession(now: now)
        let projects = [fixture.current, fixture.previous]

        let snapshot = DataSource.assemble(
            projects: projects,
            windows: [],
            sessions: [live("s1", startedIn: fixture.previous.path)],
            hourlyContested: narrow(fixture.contested,
                                    since: now.addingTimeInterval(-UsageStore.hourWindowSeconds)),
            worktrees: DataSource.worktrees(of: projects),
            accessibilityTrusted: true)

        let current = try XCTUnwrap(snapshot.projects.first { $0.project?.path == fixture.current.path })
        XCTAssertNil(current.hourlyUsage,
                     "the surviving claim was taken for the answer while the live session says "
                     + "its own life is the other one")
        XCTAssertEqual(snapshot.ambiguousHourlySessions, 1)
    }

    /// One `session_id`, one live row: the invariant that lets
    /// `DataSource.liveSlugsBySessionId` be a map and the contest veto ask one question.
    /// `ClaudeSessions.liveSessions` dedupes by session id (keeping the
    /// lexicographically first `<pid>.json`); this must go red before that assumption
    /// is reopened.
    ///
    /// Two session files naming one identifier from two directories, with a live pid
    /// (this process), because `isSessionProcessAlive` drops everything else before the
    /// dedup.
    func testOneSessionIdYieldsOneLiveRow() throws {
        let sessionsDirectory = base.appendingPathComponent("claude-sessions")
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let identifier = "live-\(UUID().uuidString)"
        for (name, cwd) in [("100.json", "first"), ("200.json", "second")] {
            let body = """
            {"sessionId": "\(identifier)", "cwd": "\(projectsRoot.appendingPathComponent(cwd).path)",
             "entrypoint": "claude-vscode", "pid": \(getpid())}
            """
            try Data(body.utf8).write(to: sessionsDirectory.appendingPathComponent(name))
        }

        let sessions = ClaudeSessions.liveSessions(config: .default,
                                                   sessionsDirectory: sessionsDirectory)
        XCTAssertEqual(sessions.count, 1,
                       "two files named one session and both became rows, so the veto now has "
                       + "two answers to one question and the map keeps whichever it likes")
        XCTAssertEqual(sessions.first?.cwd, projectsRoot.appendingPathComponent("first").path,
                       "the winner is the lexicographically first file, not directory order")
        // Asked of the map's *answer*, not of its size: `count == 1` is true for
        // any non-empty `sessions` here, since the fixture has one identifier and
        // a dictionary keyed by it cannot hold two — an assertion with no "no" in
        // it, green under the very mutation it was put here to catch.
        XCTAssertEqual(DataSource.liveSlugsBySessionId(of: sessions)[identifier],
                       ClaudeSessions.slug(forPath: projectsRoot.appendingPathComponent("first").path),
                       "the veto is answered about a directory the surviving row does not name")
    }

    /// No live session and both copies written inside the window: two claims, nothing
    /// to choose between them, ambiguous. Keeping the newest copy would be a coin-flip
    /// `settle` refuses.
    func testWithNoLiveSessionAndBothLivesInsideTheWindowNothingIsResolved() throws {
        let now = Date()
        let fixture = try resumedSession(now: now.addingTimeInterval(-3 * 86_400),
                                         silentFor: 2 * 86_400)
        let projects = [fixture.current, fixture.previous]

        let snapshot = DataSource.assemble(
            projects: projects,
            windows: [],
            sessions: [],
            contested: narrow(fixture.contested,
                              since: now.addingTimeInterval(-UsageStore.windowSeconds)),
            worktrees: DataSource.worktrees(of: projects),
            accessibilityTrusted: true)

        for project in projects {
            let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == project.path })
            XCTAssertNil(row.usage, "\(project.rootName) was handed a contest nobody can settle")
        }
        XCTAssertEqual(snapshot.ambiguousUsageSessions, 1)
    }

    /// Both windows are settled against the same live sessions.
    ///
    /// `spread` is one function called twice because attribution may have only one
    /// policy per snapshot (SPEC §2.9); a window given the live-session map while the
    /// other went without would be invisible, since each window's figures are read on
    /// their own.
    ///
    /// The rival life is a month old, so both windows narrow it away and only the
    /// live session's refusal keeps either figure off a row. The live record names that
    /// rival life: a running session always has a transcript under its own slug (see
    /// `testALiveSessionWhoseOwnLifeFellOutOfTheWindowLeavesTheContestAmbiguous`).
    func testBothWindowsAreSettledAgainstTheSameLiveSessions() throws {
        let now = Date()
        let fixture = try resumedSession(now: now, silentFor: 30 * 86_400)
        let projects = [fixture.current, fixture.previous]

        let snapshot = DataSource.assemble(
            projects: projects,
            windows: [],
            sessions: [live("s1", startedIn: fixture.previous.path)],
            contested: narrow(fixture.contested,
                              since: now.addingTimeInterval(-UsageStore.windowSeconds)),
            hourlyContested: narrow(fixture.contested,
                                    since: now.addingTimeInterval(-UsageStore.hourWindowSeconds)),
            worktrees: DataSource.worktrees(of: projects),
            accessibilityTrusted: true)

        let current = try XCTUnwrap(snapshot.projects.first { $0.project?.path == fixture.current.path })
        XCTAssertNil(current.usage, "the week was settled without the live sessions")
        XCTAssertNil(current.hourlyUsage, "the hour was settled without the live sessions")
        XCTAssertEqual(snapshot.ambiguousUsageSessions, 1)
        XCTAssertEqual(snapshot.ambiguousHourlySessions, 1)
    }

    /// The worktree listing is the one piece of disk `assemble` cannot do for
    /// itself. A project with no `.claude/worktrees` must not appear in it at
    /// all — that guard is what keeps 96 failing `contentsOfDirectory` calls off
    /// a path that runs once a second.
    func testOnlyProjectsThatHaveWorktreesAreListed() throws {
        let bare = try makeProject("plain")
        let withTree = try makeProject("switcher", worktrees: ["usage-ui"])

        let found = DataSource.worktrees(of: [bare, withTree])
        XCTAssertNil(found[bare.path])
        XCTAssertEqual(found[withTree.path], [withTree.path + "/.claude/worktrees/usage-ui"])
    }
}

/// Folding per-session figures into per-directory and then per-project ones.
final class UsageJoinTests: XCTestCase {

    private func session(_ identifier: String, input: Int) throws -> GatewaySession {
        try UsageFixtures.decode("""
        {"session_id": "\(identifier)", "input_tokens": \(input), "output_tokens": 0,
         "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
        """, as: GatewaySession.self)
    }

    func testSessionsOfOneDirectoryAreSummed() throws {
        let folded = UsageIndex.fold(sessions: [try session("a", input: 10), try session("b", input: 5)],
                                     slugsBySessionId: ["a": ["-Users-x-project"], "b": ["-Users-x-project"]])
        XCTAssertEqual(folded.tokensBySlug["-Users-x-project"]?.input, 15)
        XCTAssertEqual(folded.unmatchedSessions, 0)
        XCTAssertEqual(folded.unmatched, .zero)
        XCTAssertTrue(folded.contested.isEmpty)
    }

    func testASessionWithNoLocalTranscriptIsUnmatchedRatherThanDropped() throws {
        let folded = UsageIndex.fold(sessions: [try session("a", input: 10), try session("node", input: 7)],
                                     slugsBySessionId: ["a": ["-Users-x-project"]])
        XCTAssertEqual(folded.tokensBySlug.count, 1)
        XCTAssertEqual(folded.unmatchedSessions, 1)
        XCTAssertEqual(folded.unmatched.input, 7)
    }

    /// A session found under two slugs is set aside whole rather than counted
    /// under either. The gateway reports one aggregate for the session and the
    /// fold has no project list to ask whether the two slugs mean two projects,
    /// so the question is passed on instead of being answered here.
    func testASessionUnderTwoSlugsIsSetAsideRatherThanCounted() throws {
        let folded = UsageIndex.fold(sessions: [try session("a", input: 10), try session("b", input: 5)],
                                     slugsBySessionId: ["a": ["-x-one", "-x-two"],
                                                        "b": ["-x-two"]])
        XCTAssertEqual(folded.tokensBySlug, ["-x-two": TokenCounts(input: 5, output: 0,
                                                                   cacheCreation: 0, cacheRead: 0)],
                       "only the session with one slug was folded")
        XCTAssertEqual(folded.contested, [ContestedSpend(sessionId: "a",
                                                         slugs: ["-x-one", "-x-two"],
                                                         tokens: try session("a", input: 10).tokens)])
        XCTAssertEqual(folded.unmatchedSessions, 0, "it has a transcript; whose is the open question")
    }

    func testAnUnnamedCounterSurvivesTheFold() throws {
        let partial = try UsageFixtures.decode("""
        {"session_id": "p", "input_tokens": 10, "output_tokens": null}
        """, as: GatewaySession.self)
        let folded = UsageIndex.fold(sessions: [try session("a", input: 1), partial],
                                     slugsBySessionId: ["a": ["-x"], "p": ["-x"]])
        XCTAssertEqual(folded.tokensBySlug["-x"]?.input, 11)
        XCTAssertEqual(folded.tokensBySlug["-x"]?.isComplete, false)
    }

    // MARK: - Attribution to rows

    private let projectPath = "/Users/x/Data/Projects/switcher"

    private func tokens(_ input: Int) -> TokenCounts {
        TokenCounts(input: input, output: 0, cacheCreation: 0, cacheRead: 0)
    }

    /// Keyed by directory here and slugged on the way in, exactly as Claude Code
    /// slugs it when it files a transcript. These tests are about which row the
    /// number lands on; that the slug of a directory on disk is the one the app
    /// computes is held by `UsageAttributionTests`, over real directories.
    private func assemble(spend: [String: TokenCounts],
                          hourly: [String: TokenCounts] = [:],
                          sessions: [ClaudeSessionInfo] = [],
                          windows: [VSCodeWindowInfo] = [],
                          worktrees: [String] = []) -> SwitcherSnapshot {
        DataSource.assemble(projects: [TestFixtures.project(path: projectPath, rootName: "switcher")],
                            windows: windows,
                            sessions: sessions,
                            tokensBySlug: Dictionary(uniqueKeysWithValues: spend.map {
                                (ClaudeSessions.slug(forPath: $0.key), $0.value)
                            }),
                            hourlyTokensBySlug: Dictionary(uniqueKeysWithValues: hourly.map {
                                (ClaudeSessions.slug(forPath: $0.key), $0.value)
                            }),
                            worktrees: worktrees.isEmpty ? [:] : [projectPath: worktrees],
                            accessibilityTrusted: true)
    }

    func testSpendInTheProjectDirectoryLandsOnItsRow() {
        let snapshot = assemble(spend: [projectPath: tokens(10)])
        let row = snapshot.projects.first { $0.project?.path == projectPath }
        XCTAssertEqual(row?.usage?.input, 10)
        XCTAssertEqual(row?.usageInputEquivalent, 10)
    }

    func testTheProjectAndItsWorktreesAddUp() {
        let one = projectPath + "/.claude/worktrees/one"
        let two = projectPath + "/.claude/worktrees/two"
        let snapshot = assemble(spend: [projectPath: tokens(10), one: tokens(7), two: tokens(3)],
                                worktrees: [one, two])
        let row = snapshot.projects.first { $0.project?.path == projectPath }
        XCTAssertEqual(row?.usage?.input, 20)
    }

    /// A subdirectory of a project is not the project, deliberately: matching is by
    /// slug, and a slug has lost its separators, so
    /// `-Users-x-Data-Projects-switcher-macos` is indistinguishable from a project
    /// called `switcher-macos`. Worktrees are the exception because they are enumerated
    /// and slugged from their real paths. Such spend lands on no row.
    func testSpendUnderASubdirectorySlugDoesNotReachTheProject() {
        let snapshot = assemble(spend: [projectPath + "/macos": tokens(3)])
        XCTAssertNil(snapshot.projects.first { $0.project?.path == projectPath }?.usage)
    }

    func testAWindowRowCarriesItsProjectsSpend() {
        let window = TestFixtures.window(index: 0, title: "topic \u{2014} switcher (Workspace)")
        let snapshot = assemble(spend: [projectPath: tokens(10)], windows: [window])
        XCTAssertEqual(snapshot.openWindows.first?.usage?.input, 10)
        XCTAssertTrue(snapshot.projects.isEmpty, "the project has a window, so it has no second row")
    }

    /// A directory outside every scan root has a row of its own as soon as an
    /// agent runs there, and that row keeps its own spend — found by slugging
    /// its own path, the same forward direction everything else uses.
    func testAnOrphanRowKeepsItsOwnSpend() {
        let snapshot = assemble(spend: [projectPath: tokens(10), "/tmp/scratch": tokens(4)],
                                sessions: [TestFixtures.session(id: "s1", cwd: "/tmp/scratch", state: .working)])
        let orphan = snapshot.projects.first { $0.id == "cwd:/tmp/scratch" }
        XCTAssertEqual(orphan?.usage?.input, 4)
        XCTAssertEqual(snapshot.projects.first { $0.project?.path == projectPath }?.usage?.input, 10)
    }

    func testARowWithNoSpendCarriesNoNumberRatherThanZero() {
        let snapshot = assemble(spend: [:])
        let row = snapshot.projects.first { $0.project?.path == projectPath }
        XCTAssertNil(row?.usage)
        XCTAssertNil(row?.usageInputEquivalent, "no figure at all is not a figure of zero")
    }

    /// Spend the gateway reports for a directory nobody has a row for is not
    /// invented into one: it stays in the snapshot's totals.
    func testSpendOutsideEveryRowDoesNotCreateARow() {
        let snapshot = assemble(spend: ["/tmp/finished-last-week": tokens(4)])
        XCTAssertNil(snapshot.projects.first { $0.id.hasPrefix("cwd:") })
    }

    /// Two windows on one project both carry the project's whole spend. Sessions reach a
    /// window only through `distribute`'s title-prefix guess (SPEC §8), so a per-window
    /// share would print that guess as a number; both rows are labelled with the
    /// project name. So rows no longer add up to the total once a project has two
    /// windows, which is why `--dump` asserts nothing between them.
    func testBothWindowsOfOneProjectCarryTheSameSpend() {
        let first = TestFixtures.window(index: 0,
                                        title: "one thing \u{2014} switcher (Workspace)",
                                        windowNumber: 11)
        let second = TestFixtures.window(index: 1,
                                         title: "another \u{2014} switcher (Workspace)",
                                         windowNumber: 12)
        let snapshot = assemble(spend: [projectPath: tokens(10)], windows: [first, second])

        XCTAssertEqual(snapshot.openWindows.count, 2)
        XCTAssertEqual(snapshot.openWindows.map { $0.usage?.input }, [10, 10],
                       "the project's spend, whole, on each of its windows")
        XCTAssertEqual(snapshot.openWindows.compactMap(\.usageInputEquivalent), [10, 10])
    }

    // MARK: - The sliding hour, on the same rows

    /// The hour is spread over the projects by the very same rule as the week —
    /// the same slug map, the same function — so it lands on the same row, and a
    /// worktree's slug folds onto its project here too.
    ///
    /// Asked with *different* numbers in the two windows, because equal ones would
    /// pass with the row wired to either: what this holds is that the row carries
    /// both and does not confuse them.
    func testTheHourLandsOnTheSameRowTheWeekDoes() throws {
        let worktree = projectPath + "/.claude/worktrees/one"
        let snapshot = assemble(spend: [projectPath: tokens(10)],
                                hourly: [projectPath: tokens(3), worktree: tokens(4)],
                                worktrees: [worktree])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })

        XCTAssertEqual(row.usage?.input, 10, "the week is where it was")
        XCTAssertEqual(row.hourlyUsage?.input, 7, "the project's hour, plus its worktree's")
        XCTAssertEqual(row.hourlyInputEquivalent, 7)
    }

    /// A window row carries its project's hour, exactly as it carries its week.
    func testAWindowRowCarriesItsProjectsHour() throws {
        let window = TestFixtures.window(index: 0, title: "topic \u{2014} switcher (Workspace)")
        let snapshot = assemble(spend: [projectPath: tokens(10)],
                                hourly: [projectPath: tokens(3)],
                                windows: [window])
        let row = try XCTUnwrap(snapshot.openWindows.first)
        XCTAssertEqual(row.usage?.input, 10)
        XCTAssertEqual(row.hourlyUsage?.input, 3)
    }

    /// And so does an orphan `cwd:` row, keyed by its own directory's slug. This
    /// is where a live agent outside the scan roots shows up, so it is the last
    /// row that may be left without the figure that says it is working (§2.2.1).
    func testAnOrphanRowKeepsItsOwnHour() throws {
        let snapshot = assemble(spend: ["/tmp/scratch": tokens(9)],
                                hourly: ["/tmp/scratch": tokens(4)],
                                sessions: [TestFixtures.session(id: "s1", cwd: "/tmp/scratch",
                                                                state: .working)])
        let orphan = try XCTUnwrap(snapshot.projects.first { $0.id == "cwd:/tmp/scratch" })
        XCTAssertEqual(orphan.usage?.input, 9)
        XCTAssertEqual(orphan.hourlyUsage?.input, 4)
    }

    /// The capped week: the gateway keeps its 200 largest weekly consumers, so a session
    /// spending now after a quiet week is in the hour's report and absent from the
    /// week's (§2.9). Its row still shows the rate. The fixture has no week figure for
    /// this project, so it proves the case.
    func testARowAbsentFromTheWeeksReportStillShowsItsHour() throws {
        let snapshot = assemble(spend: ["/tmp/somebody-else": tokens(500)],
                                hourly: [projectPath: tokens(6)])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })

        XCTAssertNil(row.usage, "the week's report does not mention this project at all")
        XCTAssertNil(row.usageInputEquivalent)
        XCTAssertEqual(row.hourlyUsage?.input, 6, "and the hour still reaches its row")
        XCTAssertEqual(SwitcherRowView.rateLabel(for: row), "6/h")
    }

    /// The mirror of `testARowWithNoSpendCarriesNoNumberRatherThanZero`: nothing
    /// reported for the hour is no figure, not a figure of zero.
    func testARowWithNoHourCarriesNoRateRatherThanZero() throws {
        let snapshot = assemble(spend: [projectPath: tokens(10)])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })
        XCTAssertNil(row.hourlyUsage)
        XCTAssertNil(row.hourlyInputEquivalent, "no figure at all is not a figure of zero")
        XCTAssertNil(SwitcherRowView.rateLabel(for: row))
        XCTAssertEqual(ConsoleDump.rateCell(for: row), "-")
    }

    /// The hour's lower bound is marked on both surfaces, on the same terms as the
    /// week's — and the week beside it stays exact, so neither mark can be the
    /// other's leaking through.
    func testAPartlyKnownHourIsMarkedAsALowerBound() throws {
        let partial = TokenCounts(input: 1000, output: nil, cacheCreation: nil, cacheRead: nil)
        let snapshot = assemble(spend: [projectPath: tokens(2000)], hourly: [projectPath: partial])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })

        XCTAssertTrue(row.hourlyIsLowerBound)
        XCTAssertEqual(SwitcherRowView.rateLabel(for: row), "≥1k/h")
        XCTAssertEqual(ConsoleDump.rateCell(for: row), ">=1k/h")
        XCTAssertFalse(row.usageIsLowerBound, "the week knows all four and says so")
        XCTAssertEqual(ConsoleDump.usageCell(for: row), "2k")
    }

    // MARK: - What is known, and what is only a lower bound

    /// The gateway named none of the four counters. `weighted()` folds every
    /// unnamed counter in as zero and so answers 0 — which is the sum of nothing
    /// known, not a spend of zero — and the flag that says so, `isComplete`, is
    /// gone the moment the number is taken out on its own. So the accessor the
    /// UI reads answers `nil` and the dump prints a dash.
    func testARowThatKnowsNothingShowsNoNumberRatherThanAConfidentZero() throws {
        let unnamed = TokenCounts(input: nil, output: nil, cacheCreation: nil, cacheRead: nil)
        let snapshot = assemble(spend: [projectPath: unnamed])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })

        XCTAssertNotNil(row.usage, "the gateway did report for this directory")
        XCTAssertEqual(row.usage?.weighted(), 0, "and the arithmetic still answers zero")
        XCTAssertNil(row.usageInputEquivalent, "which is not a number anybody may be shown")
        XCTAssertFalse(row.usageIsLowerBound, "there is no number for a bound to be under")
        XCTAssertEqual(ConsoleDump.usageCell(for: row), "-")
    }

    /// Part of the four named: the number is real and partial, so it is shown
    /// with the mark that says it is a floor.
    func testAPartlyKnownRowIsANumberMarkedAsALowerBound() throws {
        let partial = TokenCounts(input: 1000, output: nil, cacheCreation: nil, cacheRead: nil)
        let snapshot = assemble(spend: [projectPath: partial])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })

        XCTAssertEqual(row.usageInputEquivalent, 1000)
        XCTAssertTrue(row.usageIsLowerBound)
        XCTAssertEqual(ConsoleDump.usageCell(for: row), ">=1k")
    }

    func testACompletelyKnownRowIsANumberWithoutTheMark() throws {
        let snapshot = assemble(spend: [projectPath: tokens(1000)])
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == projectPath })
        XCTAssertFalse(row.usageIsLowerBound)
        XCTAssertEqual(ConsoleDump.usageCell(for: row), "1k")
    }

    /// The mark has to appear in both sections of the dump. The windows section
    /// prints the four counters, the projects section prints the one number, and
    /// the two columns are read against each other: a lower bound that looks
    /// exact in one of them is worse than in neither.
    func testBothDumpSectionsMarkALowerBound() throws {
        let partial = TokenCounts(input: 1000, output: nil, cacheCreation: nil, cacheRead: nil)
        let window = TestFixtures.window(index: 0, title: "topic \u{2014} switcher (Workspace)")

        let withWindow = assemble(spend: [projectPath: partial], windows: [window])
        let windowRow = try XCTUnwrap(withWindow.openWindows.first)
        XCTAssertTrue(ConsoleDump.formatTokens(try XCTUnwrap(windowRow.usage)).hasPrefix(">="),
                      "windows section")

        let withoutWindow = assemble(spend: [projectPath: partial])
        let projectRow = try XCTUnwrap(withoutWindow.projects.first { $0.project?.path == projectPath })
        XCTAssertTrue(ConsoleDump.usageCell(for: projectRow).hasPrefix(">="), "projects section")
    }

    /// Counters that name nothing print as a dash there too. `0 ie (in ?, out ?,
    /// cw ?, cr ?)` is the same confident zero, and the line it turns up on is
    /// `no local session: 0 sessions` — where it contradicts the count standing
    /// next to it.
    func testCountersThatNameNothingPrintAsADash() {
        XCTAssertEqual(ConsoleDump.formatTokens(.zero), "-")
        XCTAssertEqual(ConsoleDump.formatTokens(TokenCounts(input: nil, output: nil,
                                                            cacheCreation: nil, cacheRead: nil)), "-")
        XCTAssertEqual(ConsoleDump.formatTokens(TokenCounts(input: 0, output: 0,
                                                            cacheCreation: 0, cacheRead: 0)),
                       "0 ie (in 0, out 0, cw 0, cr 0)",
                       "a measured zero is a number and stays one")
    }
}

/// Which project a working directory belongs to, the rule both loops of `assemble`
/// route through.
/// Asked of `DataSource.project(for:in:prefixes:)` directly: through `assemble` a
/// wrong match comes back only as a figure missing from a row.
final class ProjectMatchingTests: XCTestCase {

    private func match(_ cwd: String, in paths: [String]) -> String? {
        let projects = paths.map {
            TestFixtures.project(path: $0, rootName: ($0 as NSString).lastPathComponent)
        }
        return DataSource.project(for: cwd,
                                  in: projects,
                                  prefixes: DataSource.prefixes(of: projects))?.path
    }

    /// A path that merely starts with a project's path is not inside it: that is the
    /// `+ "/"` separator's job (`asakusa_lab` beside `asakusa_lab_glaze_resolver`,
    /// `portainer` beside `portainer-agent`). Only three of the five assertions depend
    /// on it: with both projects listed the deeper prefix wins anyway, and the control
    /// is genuine containment.
    func testASiblingWhoseNameStartsWithAnothersIsNotInsideIt() {
        XCTAssertNil(match("/a/bc", in: ["/a/b"]),
                     "half a path component is not containment")
        XCTAssertNil(match("/a/bc/src", in: ["/a/b"]),
                     "and neither is anything below it")
        XCTAssertEqual(match("/a/b/src", in: ["/a/b"]), "/a/b",
                       "the control: the same shape one separator over")

        // The live pair, in the shape it has on disk, both alone and together.
        XCTAssertNil(match("/Users/x/Projects/portainer-agent", in: ["/Users/x/Projects/portainer"]))
        XCTAssertEqual(match("/Users/x/Projects/portainer-agent/src",
                             in: ["/Users/x/Projects/portainer", "/Users/x/Projects/portainer-agent"]),
                       "/Users/x/Projects/portainer-agent",
                       "the spend of the agent stays on the agent's row")
    }

    /// An exact match beats a containing project, in either arrival order: the walk
    /// returns on the exact match and keeps the deepest prefix as a running maximum.
    func testAnExactMatchWinsOverAProjectThatContainsIt() {
        XCTAssertEqual(match("/a/b/c", in: ["/a/b", "/a/b/c"]), "/a/b/c", "container first")
        XCTAssertEqual(match("/a/b/c", in: ["/a/b/c", "/a/b"]), "/a/b/c", "exact first")
    }

    /// Of several containing projects the deepest takes it, asked in both orders since
    /// the maximum is running and ties go to the first; with the deep project first a
    /// "first containing" rule would answer correctly by accident.
    func testTheDeepestContainingProjectWins() {
        XCTAssertEqual(match("/a/b/c/d", in: ["/a", "/a/b"]), "/a/b", "shallow first")
        XCTAssertEqual(match("/a/b/c/d", in: ["/a/b", "/a"]), "/a/b", "deep first")
    }
}

/// The one wire from the gateway poll into the panel.
final class UsageWiringTests: XCTestCase {

    /// `DataSource.build()` reads `UsageCache` and hands the numbers to
    /// `assemble`. That single argument is the whole feature: removing it leaves
    /// every other test in this file green, because they all call `assemble`
    /// directly and pass the spend in themselves.
    ///
    /// So this one goes the way the app does — a real `DataSource` over a real
    /// scan root, with the cache filled the way a finished poll fills it.
    func testTheSnapshotCarriesWhatThePollLeftInTheCache() throws {
        let root = try makeTemporaryDirectory()
        let project = root.appendingPathComponent("switcher")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)

        let cache = UsageCache()
        var polled = UsageSnapshot.empty
        polled.tokensBySlug = [ClaudeSessions.slug(forPath: project.path): TokenCounts(input: 10, output: 2,
                                                        cacheCreation: 0, cacheRead: 0)]
        cache.store(polled)

        var config = Config.default
        config.projectRoots = [root.path]
        config.scanDepth = 1
        // No application answers to this identifier, so the window list comes
        // back empty and the run needs no Accessibility grant — the same trick
        // `--no-windows` uses.
        config.editorBundleID = "xyz.vvzvlad.vscode-switcher.no-such-editor"

        let snapshot = DataSource(config: config, usage: cache).snapshot()
        let row = try XCTUnwrap(snapshot.projects.first { $0.project?.path == project.path },
                                "the scan should have found the project")
        XCTAssertEqual(row.usage?.input, 10)
        XCTAssertEqual(row.usageInputEquivalent, 20, "10 input plus 2 output at five times input")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.standardizedFileURL
    }
}

/// The pass itself: what it keeps when the gateway is not there, and where it
/// runs.
final class UsageStoreTests: XCTestCase {

    /// Answers the three endpoints from the fixtures, or fails whichever of them is
    /// handed `nil`.
    ///
    /// The history is checked first: its path (`/gw/usage/acc2/history`) begins with the
    /// quota endpoint's and would otherwise be served the quota body.
    /// - Parameters:
    ///   - sessionsBySince: a body for one `/gw/sessions` window, keyed by the `since` it
    ///     asks for. The pass calls that path twice (the week and the sliding hour), so a
    ///     test that tells them apart answers them apart; anything not named here falls
    ///     back to `sessions`.
    ///   - unreachableSince: the windows that fail instead of answering, same key.
    ///     Failing one window is the only way to ask whether the blame names it.
    private func transport(usage: String? = UsageFixtures.usage,
                           sessions: String? = "{\"since\": 1786761516, \"sessions\": []}",
                           sessionsBySince: [Int: String] = [:],
                           unreachableSince: Set<Int> = [],
                           history: String? = UsageStoreTests.risingHistory,
                           historyByLabel: [String: String] = [:],
                           rotation: String? = UsageStoreTests.nobodySwitchedOff,
                           status: Int = 200,
                           log: RequestLog? = nil) -> UsageClient.Transport {
        { request in
            let path = request.url?.path ?? ""
            log?.record(request.url)
            let body: String?
            if path.hasSuffix("/status") {
                // `/gw/status`, asked on the histories' cadence for who is switched out of the
                // rotation. Without this arm the path would fall to the `else` and get the
                // `/gw/usage` body, whose `accounts` is a dictionary, so every pass would set
                // `rotationFailure`.
                body = rotation
            } else if path.hasSuffix("/history") {
                // `/gw/usage/<label>/history`, so the label is the component
                // before the last one — which is what lets a fixture give two
                // accounts two different series.
                let label = request.url?.pathComponents.dropLast().last ?? ""
                body = historyByLabel[label] ?? history
            } else if path.hasSuffix("/sessions") {
                let since = request.url.flatMap {
                    URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                        .queryItems?.first { $0.name == "since" }?.value
                }.flatMap(Int.init)
                if let since, unreachableSince.contains(since) {
                    throw UsageError.unreachable("nothing listening")
                }
                body = since.flatMap { sessionsBySince[$0] } ?? sessions
            } else {
                body = usage
            }
            guard let body else { throw UsageError.unreachable("nothing listening") }
            let url = request.url ?? Config.default.resolvedUsageBaseURL
            guard let response = HTTPURLResponse(url: url, statusCode: status,
                                                 httpVersion: nil, headerFields: nil) else {
                throw UsageError.unreachable("no test response")
            }
            return (Data(body.utf8), response)
        }
    }

    /// One account's series as the gateway sends it, `readings` spread evenly
    /// over `overHours`.
    /// The instant every pass in this suite polls at, and the instant every
    /// history fixture below ends at: the figure is measured over the trailing
    /// `FleetCapacity.burnWindowHours` from the pass's own `now`, so a fixture anchored
    /// elsewhere would be refused.
    private static let pollInstant = Date(timeIntervalSince1970: 1_786_800_000)

    private static func historySeries(label: String = "acc2",
                                      readings: [Double],
                                      overHours: Double = 8) -> String {
        let start = pollInstant.timeIntervalSince1970 - overHours * 3600
        let step = readings.count > 1 ? overHours * 3600 / Double(readings.count - 1) : 0
        let points = readings.enumerated().map { index, value in
            "{\"ts\": \(start + Double(index) * step), \"util_7d\": \(value)}"
        }
        return "{\"label\": \"\(label)\", \"since\": \(start), "
            + "\"points\": [\(points.joined(separator: ","))]}"
    }

    /// The default history: acc2 burning 10 pp over the 8 h measurement window,
    /// which is 1.25 pp/h against the 0.5952 one account refills — 210%, and not a
    /// lower bound, so every field of the answer is distinguishable from a
    /// default.
    private static let risingHistory = historySeries(readings: [0, 5, 10])

    /// `GET /gw/status` for a fleet nobody has switched off: the default, since the
    /// switch is the exceptional state. All three labels any fixture in this file
    /// names, so swapping a `usage` body does not change who the rotation knows about.
    /// `eligible` is present because `GatewayStatus` refuses a row without it.
    static let nobodySwitchedOff = """
    {"accounts": [
       {"label": "acc2", "eligible": true, "disabled": false,
        "disabled_until": null, "disabled_reason": ""},
       {"label": "acc3", "eligible": true, "disabled": false,
        "disabled_until": null, "disabled_reason": ""},
       {"label": "main", "eligible": true, "disabled": false,
        "disabled_until": null, "disabled_reason": ""}
     ]}
    """

    private func client(_ transport: @escaping UsageClient.Transport) -> UsageClient {
        UsageClient(baseURL: Config.default.resolvedUsageBaseURL, transport: transport)
    }

    /// A window's worth of spending, for passes that need the sessions half to carry
    /// something. One session, weighing 65.6M input-equivalent:
    /// `50 + 5 x 24264 + 1.25 x 41120 + 0.1 x 654_181_300`.
    private static let spendingSessions = """
    {"since": 1786761516, "sessions": [
      {"session_id": "s-1", "input_tokens": 50, "output_tokens": 24264,
       "cache_creation_input_tokens": 41120, "cache_read_input_tokens": 654181300}]}
    """

    /// The histories half asks no `/gw/sessions` question of its own: both sides of the
    /// figure are percentage points, so there is nothing to convert.
    ///
    /// `/gw/sessions` is asked over exactly the panel's two windows, the week and the
    /// sliding hour, never the histories' 48 h. Driven from a real pass, because a
    /// caller making an extra request answers harmlessly and is only visible by
    /// counting calls.
    func testTheHistoriesHalfAsksNoSessionQuestionOfItsOwn() async {
        let log = RequestLog()
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        _ = await UsageStore.poll(client: client(transport(usage: UsageFixtures.usageWithTokens,
                                                           sessions: Self.spendingSessions,
                                                           log: log)),
                                  previous: .empty, now: now)

        let histories = log.windows(of: "/history")
        let sessions = log.windows(of: "/sessions")
        XCTAssertEqual(histories.count, 1, "the histories are asked for once and over one window")
        XCTAssertEqual(Set(sessions), [now.timeIntervalSince1970 - UsageStore.windowSeconds,
                                       now.timeIntervalSince1970 - UsageStore.hourWindowSeconds],
                       "the two windows the panel's own figures are counted over moved")
        XCTAssertEqual(sessions.count, 2, """
            the pass made a third call to /gw/sessions: the histories half is asking a question \
            of its own again, and nothing reads its answer
            """)
        XCTAssertFalse(sessions.contains(histories[0]), """
            a session report was asked for over the histories' own window, which is the request \
            that priced a point in tokens and has no reader left
            """)
    }

    /// A good pass produces both readings the surfaces print, the second being the
    /// arithmetic `FleetCapacity.burnAgainstRefill` was tested on.
    ///
    /// `usageWithTokens` names one account, `acc2`, and `risingHistory` is its series:
    /// 10 pp over the 8 h window, 1.25 pp/h. One contributor refills 100 pp over 168 h,
    /// 0.5952 pp/h. 210%, over the refill rate: the state the menu bar colours for.
    /// The pass polls at `pollInstant`, not `Date()`: against a trailing window a
    /// wall-clock `now` would leave the fixture outside it.
    func testAGoodPassProducesBothOfTheHeadlineReadings() async {
        let snapshot = await UsageStore.poll(
            client: client(transport(usage: UsageFixtures.usageWithTokens,
                                     sessions: Self.spendingSessions)),
            previous: .empty, now: Self.pollInstant)

        XCTAssertEqual(snapshot.fleetTokenRate ?? 0, 28_940_459.22, accuracy: 0.01,
                       "the live rate is the gateway's own, weighted and carried to the hour")
        let burn = try? XCTUnwrap(snapshot.fleetBurn)
        XCTAssertEqual(burn?.percent ?? 0, 210, accuracy: 0.01)
        XCTAssertEqual(burn?.burnRate ?? 0, 10.0 / 8, accuracy: 0.0001)
        XCTAssertEqual(burn?.refillRate ?? 0, 100.0 / 168, accuracy: 0.0001,
                       "one contributor refills one account's week and no more")
        XCTAssertEqual(burn?.accounts, 1)
        XCTAssertEqual(burn?.measuredHours ?? 0, 8, accuracy: 0.01)
        XCTAssertEqual(burn?.isLowerBound, false, "nothing in the series touched a ceiling")
        XCTAssertNil(snapshot.rotationFailure, "and `/gw/status` answered, so nobody is switched off")
    }

    /// The pass reads the operator's switch from `/gw/status`, and reads `disabled`
    /// rather than `eligible`. `UsageFixtures.status` holds all three states, and the
    /// burns make every wrong reading land on a different number:
    ///
    ///     acc2  eligible, switched on    1.25 pp/h   counted
    ///     acc3  not eligible, off        2.50 pp/h   excluded — the operator's switch
    ///     main  not eligible, switched on 0.50 pp/h  counted — this is the trap
    ///
    ///     by `disabled`   1.75 / (2 x 0.5952) = 147%   <- correct
    ///     no exclusion    4.25 / (3 x 0.5952) = 238%   <- switched-off account counted
    ///     by `eligible`   1.25 / (1 x 0.5952) = 210%   <- the easy wrong fix
    ///
    /// `eligible` goes false when a five-hour window fills, so reading it would drop
    /// `main`, an account in the rotation and burning. `AccountSwitch` does not carry
    /// `eligible` and `GatewayStatus` keeps it private, so that fix cannot be typed
    /// without widening the model first.
    func testTheSwitchedOffAccountLeavesTheFleetAndTheMerelyIneligibleDoesNot() async throws {
        let snapshot = await UsageStore.poll(
            client: client(transport(usage: UsageFixtures.usageThreeAccounts,
                                     sessions: Self.spendingSessions,
                                     historyByLabel: [
                                        "acc2": Self.historySeries(label: "acc2", readings: [0, 5, 10]),
                                        "acc3": Self.historySeries(label: "acc3", readings: [0, 10, 20]),
                                        "main": Self.historySeries(label: "main", readings: [0, 2, 4])],
                                     rotation: UsageFixtures.status)),
            previous: .empty, now: Self.pollInstant)

        let burn = try XCTUnwrap(snapshot.fleetBurn)
        XCTAssertEqual(burn.accounts, 2, """
            three accounts, one of them switched off: counting three means the switch was not read \
            at all, counting one means it was read off `eligible` and took a live account with it
            """)
        XCTAssertEqual(burn.refillRate, 2 * (100.0 / 168), accuracy: 0.0001,
                       "a switched-off account refills nothing the fleet can spend")
        XCTAssertEqual(burn.burnRate, 1.75, accuracy: 0.0001,
                       "and its own 2.5 pp/h is not in the numerator either")
        XCTAssertEqual(burn.percent, 147, accuracy: 0.01, """
            147% is the fleet without acc3 on both sides; 238% leaves it in, which is the defect \
            this was reported for, and 210% drops `main` for being ineligible, which is the \
            easy wrong fix
            """)
        XCTAssertFalse(burn.isLowerBound, """
            an excluded account moves the mean either way, so `≥` would be a claim about a \
            direction nobody knows
            """)
    }

    /// What the fail-open in `UsageStore.poll` costs, on a fleet that holds a
    /// switched-off account (the three accounts of
    /// `testTheSwitchedOffAccountLeavesTheFleetAndTheMerelyIneligibleDoesNot`, asked
    /// twice). `testTheHistoriesHalfIsBlamedByItsOwnName` cannot show the price: nobody
    /// is switched off there.
    ///
    /// Here it is 147% against 238%. The direction belongs to this fixture (acc3 burns
    /// more than its neighbours), not to the mechanism, so nothing asserts a direction.
    func testAFailedRotationLeavesTheFigureStandingAtWhateverThatCosts() async throws {
        func pass(rotation: String?) async -> UsageSnapshot {
            await UsageStore.poll(
                client: client(transport(usage: UsageFixtures.usageThreeAccounts,
                                         sessions: Self.spendingSessions,
                                         historyByLabel: [
                                            "acc2": Self.historySeries(label: "acc2", readings: [0, 5, 10]),
                                            "acc3": Self.historySeries(label: "acc3", readings: [0, 10, 20]),
                                            "main": Self.historySeries(label: "main", readings: [0, 2, 4])],
                                         rotation: rotation)),
                previous: .empty, now: Self.pollInstant)
        }

        let read = await pass(rotation: UsageFixtures.status)
        let answered = try XCTUnwrap(read.fleetBurn)
        XCTAssertEqual(answered.percent, 147, accuracy: 0.01,
                       "the fleet with the switch read: acc3 out of both sides of the division")

        let missed = await pass(rotation: nil)
        XCTAssertEqual(missed.rotationFailure?.contains("/gw/status"), true)
        let standing = try XCTUnwrap(missed.fleetBurn, """
            the figure was blanked because a 6 KB endpoint was down, which is the trade \
            `UsageStore.poll` refuses to make
            """)
        XCTAssertEqual(standing.accounts, 3,
                       "not knowing who is switched off leaves everybody in the division")
        XCTAssertEqual(standing.percent, 238, accuracy: 0.01, """
            the price of the miss on this fleet, and the number the live gateway printed on \
            2026-09-09 with a switched-off acc3 still in the denominator
            """)
        XCTAssertGreaterThan(abs(standing.percent - answered.percent), 1, """
            the miss cost nothing, so this fixture is not paying the price it was written to \
            price — the fleet needs an account the switch actually removes
            """)
    }

    /// The half's blame names the endpoint it asked, because a failure without a
    /// location cannot be debugged (§4). The histories failing must not reach the
    /// sessions half's blame, a separate field with its own window. `/gw/status` rides
    /// the histories' cadence and must be blamed by its own name in its own field, or a
    /// reader is sent to `/gw/usage/<label>/history`, which answered fine.
    func testTheHistoriesHalfIsBlamedByItsOwnName() async {
        let noHistory = await UsageStore.poll(
            client: client(transport(usage: UsageFixtures.usageWithTokens,
                                     sessions: Self.spendingSessions, history: nil)),
            previous: .empty, now: Self.pollInstant)
        XCTAssertEqual(noHistory.historiesFailure?.contains("/gw/usage/<label>/history"), true)
        XCTAssertNil(noHistory.rotationFailure, "the rotation answered and is not to blame")
        XCTAssertNil(noHistory.sessionsFailure, "the week's own half answered and is not to blame")
        XCTAssertNil(noHistory.quotaFailure)

        // And the other way round: the sessions half failing leaves the histories half
        // alone, figure and all.
        let noSessions = await UsageStore.poll(
            client: client(transport(usage: UsageFixtures.usageWithTokens, sessions: nil)),
            previous: .empty, now: Self.pollInstant)
        XCTAssertNil(noSessions.historiesFailure,
                     "the histories answered: blaming them would send the reader to the wrong place")
        XCTAssertEqual(noSessions.fleetBurn?.percent ?? 0, 210, accuracy: 0.01,
                       "the figure the histories did answer was thrown away with the other half")
        XCTAssertEqual(noSessions.sessionsFailure?.contains("/gw/sessions"), true)

        // The third of the three, and the one this half gained: `/gw/status` down
        // while both of the others answer. It is blamed where nothing else is, and
        // the figure survives — the trade `UsageStore.poll` works out.
        let noRotation = await UsageStore.poll(
            client: client(transport(usage: UsageFixtures.usageWithTokens,
                                     sessions: Self.spendingSessions, rotation: nil)),
            previous: .empty, now: Self.pollInstant)
        XCTAssertEqual(noRotation.rotationFailure?.contains("/gw/status"), true,
                       "the rotation request failed under another endpoint's name, or under none")
        XCTAssertNil(noRotation.historiesFailure, """
            the series answered: blaming the histories for `/gw/status` sends the reader to the \
            wrong endpoint, and takes the figure off both surfaces on the way
            """)
        XCTAssertEqual(noRotation.fleetBurn?.percent ?? 0, 210, accuracy: 0.01, """
            this half fails open on purpose: a dead `/gw/status` leaves the figure standing. What \
            the miss is worth cannot be seen here — nobody is switched off in this fleet, so the \
            price is identically zero whatever the endpoint does; \
            testAFailedRotationLeavesTheFigureStandingAtWhateverThatCosts is the one that pays it
            """)
        XCTAssertEqual(noRotation.failureText?.contains("/gw/status"), true,
                       "and `--dump` is the one place it is visible at all")
    }

    func testAGoodPassFillsInEverythingAndReportsNoFailure() async {
        let now = Date()
        let snapshot = await UsageStore.poll(client: client(transport()), previous: .empty, now: now)
        XCTAssertNil(snapshot.failureText)
        XCTAssertEqual(snapshot.since, Date(timeIntervalSince1970: 1_786_761_516))
        XCTAssertEqual(snapshot.fleetSevenDayMean, 58.667)
        XCTAssertEqual(snapshot.accounts.map(\.label), ["acc2"])
        XCTAssertEqual(snapshot.quotaFetchedAt, now)
    }

    /// A gateway that is not there is ordinary: the numbers from the pass before stay
    /// and only the blame changes. The stamp stays with the numbers it belongs to, so
    /// the popover never describes old figures as just fetched; a failed pass is seen
    /// through the numbers it left and the blame it wrote.
    func testAFailedPassKeepsThePreviousNumbersAndTheirStamps() async {
        let earlier = Date(timeIntervalSince1970: 1_786_700_000)
        var previous = UsageSnapshot.empty
        previous.tokensBySlug = ["-x": TokenCounts(input: 1, output: 2, cacheCreation: 3, cacheRead: 4)]
        previous.fleetSevenDayMean = 42
        previous.quotaFetchedAt = earlier

        let now = Date()
        let snapshot = await UsageStore.poll(client: client(transport(usage: nil, sessions: nil)),
                                             previous: previous,
                                             now: now)
        XCTAssertEqual(snapshot.tokensBySlug, previous.tokensBySlug)
        XCTAssertEqual(snapshot.fleetSevenDayMean, 42)
        XCTAssertEqual(snapshot.quotaFailure?.contains("/gw/usage"), true)
        XCTAssertEqual(snapshot.sessionsFailure?.contains("/gw/sessions"), true)
        XCTAssertEqual(snapshot.quotaFetchedAt, earlier, "the figures did not change hands")
    }

    /// The two halves fail separately, so one arriving must not be held back by
    /// the other — and neither may the other's stamp or the other's blame.
    func testOneHalfCanArriveWithoutTheOther() async {
        let earlier = Date(timeIntervalSince1970: 1_786_700_000)
        var previous = UsageSnapshot.empty
        previous.quotaFetchedAt = earlier
        let now = Date()

        let snapshot = await UsageStore.poll(client: client(transport(usage: nil)),
                                             previous: previous, now: now)
        XCTAssertEqual(snapshot.quotaFailure?.contains("/gw/usage"), true)
        XCTAssertNil(snapshot.sessionsFailure)
        XCTAssertEqual(snapshot.since, Date(timeIntervalSince1970: 1_786_761_516))
        XCTAssertEqual(snapshot.quotaFetchedAt, earlier)
    }

    /// And a half that comes back after a failure clears its own blame without
    /// touching the other's: two passes, the first with nothing listening, the
    /// second with the quota endpoint answering again.
    func testAHalfThatRecoversClearsOnlyItsOwnBlame() async {
        let first = await UsageStore.poll(client: client(transport(usage: nil, sessions: nil)),
                                          previous: .empty)
        XCTAssertNotNil(first.quotaFailure)
        XCTAssertNotNil(first.sessionsFailure)

        let second = await UsageStore.poll(client: client(transport(sessions: nil)), previous: first)
        XCTAssertNil(second.quotaFailure, "the quota half answered and is still blamed")
        XCTAssertNotNil(second.sessionsFailure, "the sessions half still is not answering")
        XCTAssertNotNil(second.quotaFetchedAt)
    }

    /// The bridge `--dump` uses, against a port nothing listens on: a missing gateway
    /// comes back as a line to print, not a hang or a crash.
    /// "A failure, no numbers, no fleet mean" is also what the 30-second watchdog
    /// (`UsageStore`, `semaphore.wait(timeout: .now() + 30)`) returns, so the failure
    /// must name the unreachable endpoints and the call must finish well before the
    /// watchdog (two refused connections are immediate).
    func testTheSynchronousPassSurvivesAGatewayThatIsNotThere() throws {
        var config = Config.default
        config.usageBaseURL = "http://127.0.0.1:1"

        let started = Date()
        let snapshot = UsageStore.pollOnce(config: config)
        let elapsed = Date().timeIntervalSince(started)

        let failure = try XCTUnwrap(snapshot.failureText)
        XCTAssertTrue(failure.contains("/gw/usage: unreachable"), "got \(failure)")
        // Both session windows, each named: with a gateway that is not there they
        // fail together, and a line naming only one of them would read as though
        // the other had answered.
        XCTAssertTrue(failure.contains("/gw/sessions?since=-168h: unreachable"), "got \(failure)")
        XCTAssertTrue(failure.contains("/gw/sessions?since=-1h: unreachable"), "got \(failure)")
        XCTAssertLessThan(elapsed, 5,
                          "a refused connection is immediate; this waited like a pass that hung")
        XCTAssertTrue(snapshot.tokensBySlug.isEmpty)
        XCTAssertTrue(snapshot.hourlyTokensBySlug.isEmpty)
        XCTAssertNil(snapshot.fleetSevenDayMean)
    }

    /// The pass must not need the main thread (§6): the synchronous `--dump` bridge
    /// blocks the main thread while it waits. Reading a `static let` on the
    /// `@MainActor` store makes the compiler insert a silent hop to the main actor, even
    /// under `-strict-concurrency=complete`. A timed wait makes a regression a failure,
    /// not a hung run.
    func testPollDoesNotNeedTheMainThread() {
        let client = client(transport())
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            _ = await UsageStore.poll(client: client, previous: .empty)
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success,
                       "the pass waited for a main thread that is standing right here")
    }

    // MARK: - The sliding hour

    private func makeProjectsDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-hour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// A transcript filed under the slug of `directory`, where Claude Code files
    /// one. Never opened — the slug of the directory is the whole signal, and
    /// `writtenAt` is the one thing about the file itself that anything reads.
    private func file(_ sessionId: String,
                      under directory: String,
                      in root: URL,
                      writtenAt: Date? = nil) throws {
        let slug = root.appendingPathComponent(ClaudeSessions.slug(forPath: directory))
        try FileManager.default.createDirectory(at: slug, withIntermediateDirectories: true)
        let transcript = slug.appendingPathComponent("\(sessionId).jsonl")
        try Data("not json at all".utf8).write(to: transcript)
        if let writtenAt {
            try FileManager.default.setAttributes([.modificationDate: writtenAt],
                                                  ofItemAtPath: transcript.path)
        }
    }

    /// A `/gw/sessions` body naming the given sessions, each with `input` input
    /// tokens and nothing else — so a figure that arrives is traceable to the
    /// window that carried it.
    private static func sessionsBody(_ sessionIds: [String], input: Int) -> String {
        let items = sessionIds.map {
            "{\"session_id\": \"\($0)\", \"input_tokens\": \(input), \"output_tokens\": 0, "
                + "\"cache_creation_input_tokens\": 0, \"cache_read_input_tokens\": 0}"
        }
        return "{\"since\": 1786761516, \"sessions\": [\(items.joined(separator: ","))]}"
    }

    /// The hour is asked for as exactly an hour, and that length is the figure's whole
    /// claim to being a rate: the gateway's aggregates are windowed (§2.9), so the
    /// spend for the last 3600 s already is tokens per hour and nothing divides it. At
    /// two hours the row would print twice the rate with no arithmetic to fail, so the
    /// value is asserted, as `historyWindowSeconds` is.
    /// The request must go out over this window, and the hour and the week must stay
    /// two different questions.
    func testTheHourlyFigureIsAskedOverExactlyOneSlidingHour() async {
        let log = RequestLog()
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        _ = await UsageStore.poll(client: client(transport(log: log)), previous: .empty, now: now)

        let windows = log.windows(of: "/sessions")
        XCTAssertTrue(windows.contains(now.timeIntervalSince1970 - UsageStore.hourWindowSeconds),
                      "no call asked for the sliding hour; the pass asked for \(windows)")
        XCTAssertEqual(Set(windows).count, 2, """
            the pass asks /gw/sessions over two windows — the week's and the hour's — and they \
            collapsed into one, so some figure is now counted over a window that is not its \
            own: got \(windows)
            """)
        XCTAssertEqual(UsageStore.hourWindowSeconds, 3600, """
            one hour exactly. The row prints the spend inside this window as tokens per hour \
            with no division anywhere, so any other value relabels the figure rather than \
            rescaling it. Move it and the docblock above says what else has to move
            """)
        XCTAssertLessThan(UsageStore.hourWindowSeconds, UsageStore.windowSeconds,
                          "the rate and the total became one question over one window")
    }

    /// Both reports resolve their slugs through one union of identifiers.
    ///
    /// `slugsBySessionId` walks every slug directory under `~/.claude/projects` and is
    /// the expensive part of the pass (§6), so it runs once with both reports'
    /// identifiers. The gateway keeps only the 200 largest weekly consumers, so a
    /// session burning now can be in the hour's report and missing from the week's.
    /// Each window's session is in a different project, so the folds cannot borrow each
    /// other's answer.
    func testBothWindowsFoldTheirSlugsThroughOneUnionOfIdentifiers() async throws {
        let root = try makeProjectsDirectory()
        try file("s-week", under: "/Users/x/slow", in: root)
        try file("s-hour", under: "/Users/x/busy", in: root)

        let now = Date(timeIntervalSince1970: 1_786_800_000)
        let weekSince = Int(now.timeIntervalSince1970 - UsageStore.windowSeconds)
        let hourSince = Int(now.timeIntervalSince1970 - UsageStore.hourWindowSeconds)

        let snapshot = await UsageStore.poll(
            client: client(transport(sessionsBySince: [
                weekSince: Self.sessionsBody(["s-week"], input: 11),
                hourSince: Self.sessionsBody(["s-hour"], input: 7)])),
            previous: .empty, now: now, projectsDirectory: root)

        XCTAssertEqual(snapshot.tokensBySlug["-Users-x-slow"]?.input, 11,
                       "the week's own fold stopped working")
        XCTAssertEqual(snapshot.hourlyTokensBySlug["-Users-x-busy"]?.input, 7, """
            the hour's session resolved to no slug at all, which is what a map built from the \
            week's identifiers alone does to a session the week's 200-session cap left out
            """)
        XCTAssertEqual(snapshot.unmatchedSessions, 0,
                       "a session with a transcript right here was called ownerless")
    }

    /// One window failing leaves the other's figure standing, and the blame names which
    /// window was lost: these are two independent answers over two windows. Both calls
    /// go to `/gw/sessions`, so the path names neither (§4). Each direction is checked
    /// for the blame it should carry and the one it should not.
    func testOneWindowFailingLeavesTheOtherStandingAndIsBlamedByName() async throws {
        let root = try makeProjectsDirectory()
        try file("s-week", under: "/Users/x/slow", in: root)
        try file("s-hour", under: "/Users/x/busy", in: root)

        let now = Date(timeIntervalSince1970: 1_786_800_000)
        let weekSince = Int(now.timeIntervalSince1970 - UsageStore.windowSeconds)
        let hourSince = Int(now.timeIntervalSince1970 - UsageStore.hourWindowSeconds)
        let bodies = [weekSince: Self.sessionsBody(["s-week"], input: 11),
                      hourSince: Self.sessionsBody(["s-hour"], input: 7)]

        let lostHour = await UsageStore.poll(
            client: client(transport(sessionsBySince: bodies, unreachableSince: [hourSince])),
            previous: .empty, now: now, projectsDirectory: root)
        XCTAssertEqual(lostHour.tokensBySlug["-Users-x-slow"]?.input, 11,
                       "the week answered and was discarded along with the hour")
        XCTAssertTrue(lostHour.hourlyTokensBySlug.isEmpty,
                      "a window that never answered left a figure behind")
        XCTAssertEqual(lostHour.sessionsFailure?.contains("since=-1h"), true,
                       "got \(lostHour.sessionsFailure ?? "no blame at all")")
        XCTAssertEqual(lostHour.sessionsFailure?.contains("-168h"), false,
                       "the week answered; naming it sends the reader to the wrong request")

        let lostWeek = await UsageStore.poll(
            client: client(transport(sessionsBySince: bodies, unreachableSince: [weekSince])),
            previous: .empty, now: now, projectsDirectory: root)
        XCTAssertEqual(lostWeek.hourlyTokensBySlug["-Users-x-busy"]?.input, 7,
                       "the hour answered and was discarded along with the week")
        XCTAssertTrue(lostWeek.tokensBySlug.isEmpty,
                      "a window that never answered left a figure behind")
        XCTAssertEqual(lostWeek.sessionsFailure?.contains("-168h"), true,
                       "got \(lostWeek.sessionsFailure ?? "no blame at all")")
        XCTAssertEqual(lostWeek.sessionsFailure?.contains("since=-1h"), false,
                       "the hour answered; naming it sends the reader to the wrong request")
    }

    /// The hour is folded by the same `fold` as the week, so a session resumed in
    /// another directory is set aside in both and counted in neither: one policy for
    /// "whose spend is this" per snapshot.
    func testTheHourSetsAsideAContestedSessionExactlyAsTheWeekDoes() async throws {
        let root = try makeProjectsDirectory()
        try file("s-both", under: "/Users/x/one", in: root)
        try file("s-both", under: "/Users/x/two", in: root)

        let now = Date(timeIntervalSince1970: 1_786_800_000)
        let hourSince = Int(now.timeIntervalSince1970 - UsageStore.hourWindowSeconds)
        let snapshot = await UsageStore.poll(
            client: client(transport(sessions: Self.sessionsBody(["s-both"], input: 9),
                                     sessionsBySince: [
                                        hourSince: Self.sessionsBody(["s-both"], input: 4)])),
            previous: .empty, now: now, projectsDirectory: root)

        XCTAssertEqual(snapshot.contested.map(\.slugs), [["-Users-x-one", "-Users-x-two"]])
        XCTAssertEqual(snapshot.hourlyContested.map(\.slugs), [["-Users-x-one", "-Users-x-two"]],
                       "the hour dropped a contested session the week kept")
        XCTAssertEqual(snapshot.hourlyContested.first?.tokens.input, 4,
                       "the hour's contested spend came from the week's body")
        XCTAssertTrue(snapshot.hourlyTokensBySlug.isEmpty,
                      "a contested session was counted onto a row after all")
    }

    /// Each window narrows a contested session against its own length. The second copy
    /// was last written three days ago: inside the week, outside the hour. So the week
    /// keeps both claims and the hour keeps one; which project each claim belongs to is
    /// settled a layer up.
    func testEachWindowNarrowsAContestedSessionAgainstItsOwnLength() async throws {
        let root = try makeProjectsDirectory()
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        try file("s-both", under: "/Users/x/current", in: root, writtenAt: now)
        try file("s-both", under: "/Users/x/stale", in: root,
                 writtenAt: now.addingTimeInterval(-3 * 86_400))

        let hourSince = Int(now.timeIntervalSince1970 - UsageStore.hourWindowSeconds)
        let snapshot = await UsageStore.poll(
            client: client(transport(sessions: Self.sessionsBody(["s-both"], input: 9),
                                     sessionsBySince: [
                                        hourSince: Self.sessionsBody(["s-both"], input: 4)])),
            previous: .empty, now: now, projectsDirectory: root)

        XCTAssertEqual(snapshot.contested.map(\.slugs), [["-Users-x-current", "-Users-x-stale"]],
                       "both lives ran inside the week and both have to keep their claim")
        XCTAssertEqual(snapshot.hourlyContested.map(\.slugs), [["-Users-x-current"]],
                       "a life last written three days ago still claims the last hour")
        XCTAssertEqual(snapshot.hourlyContested.first?.sessionId, "s-both",
                       "the identifier is what lets the live sessions be asked about this entry")
    }

    /// The hour's ownerless spend reaches the snapshot and a line of `--dump`: spend by
    /// a session with no local transcript (mostly the agent nodes). The line is printed
    /// even when it reads zero.
    func testTheHoursOwnerlessSpendIsKeptAndPrinted() async throws {
        let root = try makeProjectsDirectory()
        try file("s-here", under: "/Users/x/project", in: root)

        let now = Date(timeIntervalSince1970: 1_786_800_000)
        let hourSince = Int(now.timeIntervalSince1970 - UsageStore.hourWindowSeconds)
        let snapshot = await UsageStore.poll(
            client: client(transport(sessions: Self.sessionsBody(["s-here"], input: 11),
                                     sessionsBySince: [
                                        hourSince: Self.sessionsBody(["s-here", "s-node"], input: 7)])),
            previous: .empty, now: now, projectsDirectory: root)

        XCTAssertEqual(snapshot.hourlyUnmatchedSessions, 1)
        XCTAssertEqual(snapshot.hourlyUnmatched.input, 7, "counted, and counted as nobody's")
        XCTAssertEqual(snapshot.unmatchedSessions, 0,
                       "the week's session has a transcript right here; its bucket must stay empty")
        XCTAssertEqual(ConsoleDump.unmatchedLine(window: "1h",
                                                 sessions: snapshot.hourlyUnmatchedSessions,
                                                 tokens: snapshot.hourlyUnmatched),
                       "no local session 1h: 1 sessions, 7 ie (in 7, out 0, cw 0, cr 0)")
        XCTAssertEqual(ConsoleDump.unmatchedLine(window: "7d",
                                                 sessions: snapshot.unmatchedSessions,
                                                 tokens: snapshot.unmatched),
                       "no local session 7d: 0 sessions, -",
                       "printed empty, like every other bucket in the section")
    }

    // MARK: - The histories' own half

    /// The window the histories are asked over is a constant, and this holds the value,
    /// not merely a floor: a floor alone does not catch shortening it.
    ///
    /// The only reader, `FleetCapacity.burnAgainstRefill`, measures over a trailing
    /// `FleetCapacity.burnWindowHours` = 8 h and refuses a series shorter than
    /// `FleetCapacity.minimumMeasuredHours` = 6 h, so the 48 h fetch is deeper than its
    /// reader. The popover's chart asks over `HistoryPeriod.seconds`, not this window,
    /// asserted below. Shrinking the fetch is unmeasured (see
    /// `UsageStore.historyWindowSeconds`), so the value is pinned and moving it stays a
    /// deliberate act. Deeper than 48 h is not on offer: accounts are capped at
    /// `max_points` = 2000, so a week's request comes back truncated.
    func testTheHistoriesAreAskedOverOneFixedWindowWiderThanTheRatioMeasures() async {
        let log = RequestLog()
        let now = Self.pollInstant
        _ = await UsageStore.poll(client: client(transport(log: log)), previous: .empty, now: now)

        XCTAssertEqual(log.windows(of: "/history"),
                       [now.timeIntervalSince1970 - UsageStore.historyWindowSeconds],
                       "the pass asked for a window of its own rather than the one constant")
        XCTAssertEqual(UsageStore.historyWindowSeconds, 48 * 3600, """
            48 h, and what holds it is no longer the ratio: the figure is measured over the \
            trailing 8 h of whatever comes back, so this constant only decides how much is \
            fetched and thrown away. It is left oversized on purpose — a shorter fetch saves \
            about 1.1 MB/h of the 1.5 it costs and needs its own measurement of how much slack \
            the trim wants. Move it and read the docblock above first
            """)

        // And the "the chart draws the rest" defence, refused in the one way that
        // cannot rot: the popover asks over its own period and 48 h is not one of
        // them, so no setting of the chart makes this window somebody's.
        XCTAssertFalse(HistoryPeriod.allCases.map(\.seconds).contains(UsageStore.historyWindowSeconds),
                       """
                       a chart period grew to exactly this window, so the fetch has a second \
                       reader now and the docblock above is out of date
                       """)

        // The control: just under the measurement's floor nothing is answered, so the floor
        // is a boundary. Both halves are literals straddling `minimumMeasuredHours`, so
        // moving the constant cannot move the fixture with it. 5.99 h is an account that
        // went quiet for the first two hours of the measurement window.
        let floor = FleetCapacity.minimumMeasuredHours
        XCTAssertEqual(floor, 6, "the 5.99 h and 6.5 h below straddle this value and only this one")
        let shallow = await UsageStore.poll(
            client: client(transport(sessions: Self.spendingSessions,
                                     history: Self.historySeries(readings: [0, 5, 10],
                                                                 overHours: 5.99))),
            previous: .empty, now: now)
        XCTAssertNil(shallow.fleetBurn,
                     "5.99 h of readings answered a ratio, so the floor is not where it says")
        let deep = await UsageStore.poll(
            client: client(transport(sessions: Self.spendingSessions,
                                     history: Self.historySeries(readings: [0, 5, 10],
                                                                 overHours: 6.5))),
            previous: .empty, now: now)
        XCTAssertNotNil(deep.fleetBurn, "the floor is one to stand on, not one to fall through")
    }

    /// The same deadlock, one endpoint further on: `historyWindowSeconds` is a
    /// `static let` on a `@MainActor` type read from the `nonisolated async` pass, and
    /// losing `nonisolated` on it hops the rest of the pass onto a main thread blocked
    /// on a semaphore here.
    ///
    /// `historyIntervalSeconds` has no `async` reader, so losing its `nonisolated` fails
    /// the build under `-strict-concurrency=complete` instead; the compiler holds that
    /// one and the timeout below holds this one. Without the timeout a regression is a
    /// run that never returns.
    ///
    /// A previous snapshot with no stamp, so the half actually runs and reads the
    /// constant.
    func testTheHistoriesPassDoesNotNeedTheMainThread() {
        let client = client(transport())
        let semaphore = DispatchSemaphore(value: 0)
        let answer = PollAnswer()
        Task.detached {
            answer.value = await UsageStore.poll(client: client, previous: .empty)
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success,
                       "the pass waited for a main thread that is standing right here")
        // The arrival stamp rather than the figure, because the stamp is what
        // says the half *ran*: it goes on whatever the fleet turned out to
        // support, and a `nil` figure is an arrival too. That the half ran is the
        // whole claim — it is what read the constants.
        XCTAssertNotNil(answer.value.historiesFetchedAt,
                        "the histories were never fetched, so neither constant was ever read")
    }

    /// The half runs on its own clock for bandwidth: one round over the fleet is
    /// 248 015 B, 1.5 MB/h at this interval against 14.9 MB/h at the once-a-minute
    /// cadence of the rest of the pass, often on a tether (see
    /// `UsageStore.historyIntervalSeconds`).
    /// The first pass has to fetch, or "no second request" would hold for a store that
    /// never asks.
    func testTheHistoriesAreNotFetchedAgainWhileTheFigureIsYoung() async {
        let log = RequestLog()
        let client = client(transport(log: log))
        let start = Date(timeIntervalSince1970: 1_786_800_000)

        let first = await UsageStore.poll(client: client, previous: .empty, now: start)
        XCTAssertEqual(log.historyRequests, 1, "the first pass did not fetch a history at all")
        XCTAssertEqual(first.historiesFetchedAt, start)
        XCTAssertEqual(first.historiesCheckedAt, start,
                       "on a pass that answered, the attempt and the arrival are one moment")

        let interval = UsageStore.historyIntervalSeconds
        let soon = await UsageStore.poll(client: client, previous: first,
                                         now: start.addingTimeInterval(interval - 1))
        XCTAssertEqual(log.historyRequests, 1,
                       "the histories were fetched again a second before the interval was up")
        XCTAssertNotNil(first.fleetBurn, "with no figure to carry, carrying it proves nothing")
        XCTAssertEqual(soon.fleetBurn, first.fleetBurn,
                       "the figure changed on a pass that never asked")
        XCTAssertEqual(soon.historiesFetchedAt, start, "a skipped pass moved the stamp")

        let later = await UsageStore.poll(client: client, previous: soon,
                                          now: start.addingTimeInterval(interval))
        XCTAssertEqual(log.historyRequests, 2, "the interval came round and nothing was fetched")
        XCTAssertEqual(later.historiesFetchedAt, start.addingTimeInterval(interval))
    }

    /// The points that reach `FleetCapacity` are the gateway's own.
    ///
    /// `UsageHistoryModel.load` hands out `withoutSourceLag(answer.points)` for the
    /// chart; routing this half through it is an easy mistake to miss. The fixture is a
    /// lone reading one point below the ceiling among ceiling readings: exactly what the
    /// filter deletes, and the only thing keeping that account inside the measurement.
    /// Smoothed, the account is refused as blocked all window and leaves the
    /// denominator, so the figure goes up from 105% to 210%.
    ///
    /// Both halves are asserted: the filter is run on the same points to show it changes
    /// them, and the smoothed series is put through `FleetCapacity` to show the cost.
    func testTheFigureIsBuiltFromRawPointsRatherThanSmoothedOnes() async throws {
        // The shape the filter destroys: a lone reading one point under a ceiling
        // it is otherwise pinned to. That one 99 is the only evidence the account
        // was measured at all rather than merely watched.
        let pinned = Self.historySeries(label: "acc2", readings: [100, 99, 100, 100, 100])
        let series = try UsageFixtures.decode(pinned, as: HistorySeries.self)
        XCTAssertEqual(UsageHistoryModel.withoutSourceLag(series.points).map(\.sevenDay),
                       [100, 100, 100, 100, 100],
                       "the fixture is not a series the filter changes, so it proves nothing")

        // It takes two accounts to see the cost. On its own the pinned account is
        // the whole fleet, and a fleet of one refused account has no figure
        // either way — `nil` against `nil` says nothing about the filter. Beside
        // an account that does burn, the refusal is a number: acc3's 1.25 pp/h
        // against one week's refill instead of two.
        let burning = Self.historySeries(label: "acc3", readings: [0, 5, 10])
        let both = [pinned, burning]
        let smoothed = [Self.historySeries(label: "acc2", readings: [100, 100, 100, 100, 100]), burning]
        func figure(_ bodies: [String]) throws -> FleetCapacity.FleetBurn? {
            let accounts = try UsageFixtures.decode(UsageFixtures.usageTwoAccounts,
                                                    as: UsageReport.self).accounts
            var byLabel: [String: HistorySeries] = [:]
            for body in bodies {
                let series = try UsageFixtures.decode(body, as: HistorySeries.self)
                byLabel[series.label] = series
            }
            return FleetCapacity.burnAgainstRefill(histories: byLabel, accounts: accounts,
                                                   switchedOff: [], now: Self.pollInstant)
        }
        let raw = try XCTUnwrap(try figure(both))
        let filtered = try XCTUnwrap(try figure(smoothed))
        XCTAssertEqual(raw.accounts, 2)
        XCTAssertEqual(raw.percent, 105, accuracy: 0.01)
        XCTAssertTrue(raw.isLowerBound, "acc2 sat at its ceiling for four of five samples")
        XCTAssertEqual(filtered.accounts, 1,
                       "smoothed, the pinned account has no reading below its ceiling left and is "
                       + "refused — which is the whole cost being avoided")
        XCTAssertEqual(filtered.percent, 210, accuracy: 0.01,
                       "an account's whole week of refill left the denominator")
        XCTAssertFalse(filtered.isLowerBound, "and the `≥` on a blocked fleet went with it")

        // And the pass hands over what the client returned. Two accounts, two
        // series, and the answer has to be the raw one.
        let snapshot = await UsageStore.poll(
            client: client(transport(usage: UsageFixtures.usageTwoAccounts,
                                     sessions: Self.spendingSessions,
                                     historyByLabel: ["acc2": pinned, "acc3": burning])),
            previous: .empty, now: Self.pollInstant)
        let landed = try XCTUnwrap(snapshot.fleetBurn, """
            the pass answered nothing for a fleet with one account below its ceiling on one sample: \
            the points were smoothed on the way in and that account went out of the fraction \
            with its refill
            """)
        XCTAssertEqual(landed.accounts, 2)
        XCTAssertEqual(landed.percent, 105, accuracy: 0.01)
        XCTAssertTrue(landed.isLowerBound, "it sat at 100 for four of five samples")
    }

    /// A history that does not answer is ordinary, and it is one half of three.
    /// The previous figure stays where it was **and so does its age** — that
    /// stamp is what the popover's footer dates the screen by, and moving it
    /// along with a failed attempt is how a frozen figure gets called fresh. The
    /// blame names its own endpoint without touching the two that answered.
    func testAFailedHistoryHalfKeepsThePreviousFigureAndBlamesItsOwnEndpoint() async {
        let earlier = Date(timeIntervalSince1970: 1_786_700_000)
        var previous = UsageSnapshot.empty
        // The rates are the expressions production computes for three
        // contributors, not a pair copied off a probe: `0.6714 / 0.5952` stood
        // here and is the *per-account* form — 0.5952 is `100 / 168`, one
        // account's share — so with `accounts: 3` it was an object
        // `burnAgainstRefill` cannot produce. Same defect as the one fixed in
        // `testTheLeadLineNamesTheRatioItsDepthAndBothSidesOfTheDivision`.
        previous.fleetBurn = FleetCapacity.FleetBurn(
            percent: 112.8, burnRate: 112.8 / 100 * 3 * 100.0 / 168,
            refillRate: 3 * 100.0 / 168, accounts: 3,
            measuredHours: 48, isLowerBound: true)
        previous.historiesFetchedAt = earlier
        previous.historiesCheckedAt = earlier

        let now = Date()
        let snapshot = await UsageStore.poll(client: client(transport(history: nil)),
                                             previous: previous, now: now)
        XCTAssertEqual(snapshot.fleetBurn, previous.fleetBurn, "the figure blinked to blank")
        XCTAssertEqual(snapshot.historiesFetchedAt, earlier,
                       "the age of the figure moved to an attempt that brought nothing back")
        XCTAssertEqual(snapshot.historiesFailure?.contains("history"), true)
        XCTAssertNil(snapshot.quotaFailure, "the quota endpoint answered and is blamed anyway")
        XCTAssertNil(snapshot.sessionsFailure)
        XCTAssertEqual(snapshot.quotaFetchedAt, now)
    }

    /// The attempt is stamped anyway, so a half that keeps failing retries on its own
    /// ten-minute cadence rather than every minute with the rest of the pass (one round
    /// over the live fleet is about 481 KB). The footer shows the figure's age and the
    /// reason.
    /// The failing pass has to make its request first, or "no second request" would hold
    /// for a pass that never asked.
    func testAFailedHistoryHalfWaitsOutItsOwnIntervalBeforeRetrying() async {
        let log = RequestLog()
        let start = Date(timeIntervalSince1970: 1_786_800_000)
        let broken = client(transport(history: nil, log: log))

        let failed = await UsageStore.poll(client: broken, previous: .empty, now: start)
        XCTAssertEqual(log.historyRequests, 1, "the failing pass never asked, so it skipped nothing")
        XCTAssertNotNil(failed.historiesFailure)
        XCTAssertNil(failed.historiesFetchedAt, "nothing arrived, so nothing may carry an age")

        let minuteLater = await UsageStore.poll(client: broken, previous: failed,
                                                now: start.addingTimeInterval(60))
        XCTAssertEqual(log.historyRequests, 1,
                       "a failed round was retried a minute later, which is the 19 MB/h on a "
                       + "tether that the ten-minute cadence exists to avoid")

        let interval = UsageStore.historyIntervalSeconds
        _ = await UsageStore.poll(client: broken, previous: minuteLater,
                                  now: start.addingTimeInterval(interval))
        XCTAssertEqual(log.historyRequests, 2, "the interval came round and the retry never happened")
    }

    /// The histories are not asked for when the quota half did not answer: the fleet's
    /// membership and each account's window boundary come from that answer, and
    /// `FleetCapacity` reads a history only under a label the fleet has.
    /// The previous snapshot carries accounts; from `.empty` there is nothing to request
    /// whatever the guard does.
    func testNoHistoryIsFetchedWhenTheQuotaHalfDidNotAnswer() async throws {
        var previous = UsageSnapshot.empty
        previous.accounts = try UsageFixtures.decode(UsageFixtures.usage, as: UsageReport.self).accounts
        XCTAssertFalse(previous.accounts.isEmpty, "the fixture remembers no account to be tempted by")

        let log = RequestLog()
        let snapshot = await UsageStore.poll(client: client(transport(usage: nil, log: log)),
                                             previous: previous)
        XCTAssertEqual(log.historyRequests, 0,
                       "a history was fetched for a fleet whose membership nobody just confirmed")
        XCTAssertNil(snapshot.fleetBurn)
        XCTAssertNil(snapshot.historiesFailure, "the history half is blamed for the quota half's failure")
    }

    /// A `nil` from `FleetCapacity` is an arrival, not a failure: it is the
    /// answer "this fleet supports no figure", which happens when no account has
    /// `minimumMeasuredHours` of history and when every one of them is pinned at
    /// its ceiling. So it is stamped, it clears the blame, and it replaces
    /// whatever was there — holding the previous number over it would state a
    /// ratio for a fleet that stopped supporting one.
    func testAFleetThatSupportsNoFigureReplacesTheOneBeforeIt() async {
        var previous = UsageSnapshot.empty
        // Producible rates, for the reason given at the fixture above.
        previous.fleetBurn = FleetCapacity.FleetBurn(
            percent: 112.8, burnRate: 112.8 / 100 * 3 * 100.0 / 168,
            refillRate: 3 * 100.0 / 168, accounts: 3,
            measuredHours: 48, isLowerBound: false)
        previous.historiesFetchedAt = Date(timeIntervalSince1970: 1_786_700_000)

        let now = Date()
        // Four hours of history, under `FleetCapacity.minimumMeasuredHours`.
        let brief = Self.historySeries(readings: [0, 50], overHours: 4)
        let snapshot = await UsageStore.poll(client: client(transport(history: brief)),
                                             previous: previous, now: now)
        XCTAssertNil(snapshot.fleetBurn, "a figure nobody can measure was kept from the pass before")
        XCTAssertEqual(snapshot.historiesFetchedAt, now)
        XCTAssertNil(snapshot.historiesFailure, "nothing failed: the gateway answered and said so")
    }
}

/// What a transport was asked for, across the threads a pass runs on.
///
/// `@unchecked Sendable`: every access is under the lock.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URL] = []

    func record(_ url: URL?) {
        guard let url else { return }
        lock.lock()
        requests.append(url)
        lock.unlock()
    }

    private var all: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var historyRequests: Int { all.filter { $0.path.hasSuffix("/history") }.count }

    /// The `since` every request to one endpoint asked for, oldest first — which
    /// is what says whether two halves of one figure were measured over the same
    /// window.
    func windows(of endpoint: String) -> [Double] {
        all.filter { $0.path.hasSuffix(endpoint) }.compactMap { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "since" }?.value.flatMap(Double.init)
        }
    }
}

/// Carries one pass's answer out of a detached task to the test that waited on
/// it. `@unchecked Sendable` on the same terms as `UsageStore.PollResult`:
/// written once inside the task and read only after the semaphore was signalled.
private final class PollAnswer: @unchecked Sendable {
    var value: UsageSnapshot = .empty
}

/// The one new setting.
final class UsageConfigTests: XCTestCase {

    func testTheDefaultAddressIsTheLocalRelayAndItParses() {
        XCTAssertEqual(Config.default.usageBaseURL, "http://127.0.0.1:8788")
        XCTAssertEqual(Config.default.resolvedUsageBaseURL.absoluteString, "http://127.0.0.1:8788")
    }

    func testAConfiguredAddressIsTaken() throws {
        let config = try load(["usageBaseURL": "http://10.0.0.1:8787"])
        XCTAssertEqual(config.resolvedUsageBaseURL.absoluteString, "http://10.0.0.1:8787")
    }

    /// `URL(string:)` accepts far more than it looks like it does — `not a url
    /// at all` parses into a relative URL on macOS 14, which is why the check is
    /// for a scheme and a host rather than for a successful parse.
    func testAnAddressWithNothingToConnectToFallsBackToTheDefault() throws {
        XCTAssertEqual(try load(["usageBaseURL": ""]).usageBaseURL, Config.default.usageBaseURL)
        XCTAssertEqual(try load(["usageBaseURL": "not a url at all"]).usageBaseURL,
                       Config.default.usageBaseURL)
        XCTAssertEqual(try load(["usageBaseURL": "127.0.0.1:8788"]).usageBaseURL,
                       Config.default.usageBaseURL, "no scheme")
        XCTAssertEqual(try load(["usageBaseURL": "http:///gw"]).usageBaseURL,
                       Config.default.usageBaseURL, "no host")
        XCTAssertEqual(try load(["usageBaseURL": 8788]).usageBaseURL, Config.default.usageBaseURL)
    }

    /// Having a scheme is not the same as having one this client can speak.
    /// `ftp://host/x` and `file://localhost/tmp` both parse, both have a host,
    /// and both are exactly the permanent failure the check exists to keep out —
    /// one would answer "unsupported URL" every minute, the other would hand the
    /// decoder the contents of a directory.
    func testASchemeThatIsNotHTTPIsRejected() throws {
        XCTAssertEqual(try load(["usageBaseURL": "ftp://host/x"]).usageBaseURL,
                       Config.default.usageBaseURL, "ftp")
        XCTAssertEqual(try load(["usageBaseURL": "file://localhost/tmp"]).usageBaseURL,
                       Config.default.usageBaseURL, "file")
    }

    /// HTTPS is not the gateway's own address today, but it is what a reverse
    /// proxy in front of it would be, and rejecting it would be a surprise.
    func testHTTPSIsAccepted() throws {
        XCTAssertEqual(try load(["usageBaseURL": "https://gw.example.org:8787"]).usageBaseURL,
                       "https://gw.example.org:8787")
    }

    private func load(_ values: [String: Any]) throws -> Config {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-config-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: values).write(to: url)
        return Config.load(from: url)
    }
}
