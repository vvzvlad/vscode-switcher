import Foundation

/// Why a call to the gateway produced no body.
///
/// Every failure here is ordinary: the relay may not be running, the WireGuard
/// tunnel may be down, the gateway may be mid-restart. Nothing in this file
/// traps, force-unwraps or throws anything the caller cannot print.
enum UsageError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The gateway answered, but not with a 2xx.
    case status(Int)
    /// It answered with a body that is not the JSON this app expects.
    case malformed(String)
    /// The request never completed at all.
    case unreachable(String)

    var description: String {
        switch self {
        case .status(let code): return "HTTP \(code)"
        case .malformed(let detail): return "malformed body: \(detail)"
        case .unreachable(let reason): return "unreachable: \(reason)"
        }
    }
}

/// Read-only HTTP client for the claude_gw gateway.
///
/// The gateway takes no authentication — it listens on the loopback relay
/// (`http://127.0.0.1:8788`) which forwards over WireGuard — so every call is a
/// bare GET.
///
/// The transport is injected with a default argument, the same seam
/// `DataSource` uses for its assembly: the tests drive real bodies and real
/// failures through the client without a network.
struct UsageClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Per-request timeout. The poll runs once a minute in the background, so
    /// there is no point waiting longer than a person would.
    static let timeoutSeconds: TimeInterval = 5

    let baseURL: URL
    private let transport: Transport

    init(baseURL: URL, transport: @escaping Transport = UsageClient.networkTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    // MARK: - Endpoints

    /// Token spend per client session, newest window first.
    func sessions(since: Date) async throws -> SessionsReport {
        try await fetch(pathSegments: ["gw", "sessions"], since: since)
    }

    /// Subscription quota utilisation, per account and averaged over the fleet.
    func usage() async throws -> UsageReport {
        try await fetch(pathSegments: ["gw", "usage"], since: nil)
    }

    /// Utilisation over time for one account.
    ///
    /// Two callers, on schedules an order of magnitude apart, and both ask once
    /// per account per pass. `UsageHistoryModel.load` draws the popover's chart
    /// and runs only while the popover is open, on its own minute cadence; it
    /// smooths what comes back (`withoutSourceLag`) because the chart wants the
    /// sawtooth gone. `UsageStore.histories` feeds `FleetCapacity` from `poll`,
    /// once every `UsageStore.allowanceIntervalSeconds`, and needs the **raw**
    /// points — that filter deletes exactly the lone below-ceiling reading that
    /// keeps a pinned account inside the measurement.
    ///
    /// So this endpoint is on the poll after all, but deliberately not on the
    /// poll's own minute: one round over the live fleet is 481 KB (measured
    /// 2026-08-18, three accounts over a 48 h window), which is 2.9 MB/h at ten
    /// minutes and ten times that at one, against about 3 KB for `/gw/usage`.
    func history(label: String, since: Date) async throws -> HistorySeries {
        try await fetch(pathSegments: ["gw", "usage", label, "history"], since: since)
    }

    // MARK: - Transport

    /// The real network. A value rather than a method so it can be swapped out
    /// wholesale in a test.
    static let networkTransport: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            // Reachable through a configured base URL with a non-HTTP scheme.
            throw UsageError.unreachable("not an HTTP response")
        }
        return (data, http)
    }

    private func fetch<Body: Decodable>(pathSegments: [String], since: Date?) async throws -> Body {
        var request = URLRequest(url: endpoint(pathSegments: pathSegments, since: since))
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeoutSeconds
        // The numbers change every minute and a cached body would be shown as
        // fresh; there is nothing here worth re-serving from a cache.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.unreachable(error.localizedDescription)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw UsageError.status(response.statusCode)
        }
        do {
            // A fresh decoder per call: one held in a `static let` is a mutable
            // class shared across tasks. Nothing here is snake-cased
            // automatically — every type spells its keys out.
            return try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw UsageError.malformed(Self.describe(error))
        }
    }

    /// Absolute URL of one endpoint.
    ///
    /// Built with `appending(path:)` and `appending(queryItems:)`, both of which
    /// return a `URL` rather than an optional, so there is no failure path here
    /// to invent an error for.
    private func endpoint(pathSegments: [String], since: Date?) -> URL {
        var url = baseURL
        for segment in pathSegments { url.append(path: segment) }
        guard let since else { return url }
        let seconds = String(Int(since.timeIntervalSince1970))
        return url.appending(queryItems: [URLQueryItem(name: "since", value: seconds)])
    }

    /// A short reason for a decoding failure — this string ends up in front of
    /// the user, so it names the field rather than dumping the coding path.
    private static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, _):
            return "no \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "bad \(context.codingPath.last?.stringValue ?? "value")"
        case .dataCorrupted:
            return "not JSON"
        @unknown default:
            return "unreadable"
        }
    }
}
