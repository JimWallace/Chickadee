// APIServer/GitHub/GitHubTransport.swift
//
// The one way the server sends a request to GitHub (#1769). The repository
// client, the OAuth client and the App-manifest converter each wrote GitHub's
// headers themselves, and only the repository client recorded reachability, so
// a GitHub outage during account linking or course binding was invisible to
// the egress rule that exists because of a 38-hour silent failure
// (`OutboundReachabilityStore`). Every request sent here records reachability
// and has a timeout.

import NIOCore
import Vapor

struct GitHubTransport: Sendable {
    let app: Application

    static let api = "https://api.github.com"

    /// GitHub asks every client to name itself.
    static let userAgent = "Chickadee"

    /// How long one call may take. Vapor's shared client sets no read timeout
    /// of its own, so without this a GitHub connection that stops answering
    /// holds the caller for as long as the socket lives (#1773).
    static let callTimeout: TimeAmount = .seconds(30)

    /// The headers every REST API call sends, with a bearer token when one is
    /// given.
    static func apiHeaders(bearer token: String? = nil) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .accept, value: "application/vnd.github+json")
        headers.replaceOrAdd(name: "X-GitHub-Api-Version", value: "2022-11-28")
        headers.replaceOrAdd(name: .userAgent, value: userAgent)
        if let token { headers.bearerAuthorization = BearerAuthorization(token: token) }
        return headers
    }

    /// Sends one request to `url` and records whether GitHub answered. Only
    /// the send is recorded: a non-2xx answer still means GitHub was reached,
    /// which the rule must not report as an outage. `encode` writes the body.
    func send(
        _ method: HTTPMethod, _ url: String, headers: HTTPHeaders,
        encode: @Sendable (inout ClientRequest) throws -> Void = { _ in }
    ) async throws -> ClientResponse {
        let client = app.client
        return try await app.recordingReachability(.github) {
            try await client.send(method, headers: headers, to: URI(string: url)) { request in
                request.timeout = Self.callTimeout
                try encode(&request)
            }
        }
    }
}
