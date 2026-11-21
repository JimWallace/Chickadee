// Shared helpers for the MCP OAuth tests: the PKCE pair, the authorize URL,
// the consent step (GET the screen to mint the single-use token, then POST
// it), the token endpoint, and reading a redirect or a JSON reply.

import Crypto
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// The PKCE code verifier every OAuth test sends.
let mcpTestCodeVerifier = "abcdefghijklmnopqrstuvwxyz0123456789-._~ABCDEFGH"

/// The S256 code challenge for `mcpTestCodeVerifier`.
let mcpTestCodeChallenge = Data(SHA256.hash(data: Data(mcpTestCodeVerifier.utf8))).base64URLEncodedString()

/// The `/oauth/authorize` path for a PKCE (S256) code request with
/// `state=xyz`. A non-nil `resource` adds the RFC 8707 `resource` parameter.
func mcpAuthorizePath(
    clientID: String, redirectURI: String, scope: String, resource: String? = nil
) -> String {
    var components = URLComponents()
    components.path = "/oauth/authorize"
    var items = [
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "client_id", value: clientID),
        URLQueryItem(name: "redirect_uri", value: redirectURI),
        URLQueryItem(name: "scope", value: scope),
        URLQueryItem(name: "state", value: "xyz"),
        URLQueryItem(name: "code_challenge", value: mcpTestCodeChallenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    if let resource { items.append(URLQueryItem(name: "resource", value: resource)) }
    components.queryItems = items
    return components.string ?? "/oauth/authorize"
}

/// Renders the consent screen at `authorizePath` as the user behind `cookie`
/// and returns its single-use `request_token`.
func mintMCPConsentToken(
    _ app: Application, cookie: String, authorizePath: String
) async throws -> String {
    var html = ""
    try await app.asyncTest(
        .GET, authorizePath,
        beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
        afterResponse: { res in html = res.body.string })
    let marker = "name=\"request_token\" value=\""
    let after = try #require(html.range(of: marker)).upperBound
    let tail = html[after...]
    let end = try #require(tail.firstIndex(of: "\""))
    return String(tail[..<end])
}

/// Submits the consent decision. By default the session cookie is *not* sent
/// on the POST: the single-use token alone must carry identity and CSRF, as on
/// the cross-site connector hop (Safari/ITP drops the cookie there).
func submitMCPConsent(
    _ app: Application, token: String, decision: String = "authorize", cookie: String? = nil
) async throws -> TestResponse {
    try await app.asyncSendRequest(
        .POST, "/oauth/authorize",
        beforeRequest: { req in
            if let cookie { req.headers.add(name: .cookie, value: cookie) }
            try req.content.encode(
                ["request_token": token, "decision": decision], as: .urlEncodedForm)
        })
}

/// Runs the consent step (GET to mint the token, then a cookie-less POST) and
/// returns the POST response (a 303 to the client).
func mcpConsent(
    _ app: Application, cookie: String, authorizePath: String, decision: String = "authorize"
) async throws -> TestResponse {
    let token = try await mintMCPConsentToken(app, cookie: cookie, authorizePath: authorizePath)
    return try await submitMCPConsent(app, token: token, decision: decision)
}

/// POSTs `fields` as a form to `/oauth/token`.
func tokenPost(_ app: Application, fields: [String: String]) async throws -> TestResponse {
    try await app.asyncSendRequest(
        .POST, "/oauth/token",
        beforeRequest: { req in try req.content.encode(fields, as: .urlEncodedForm) })
}

/// The value of query item `name` in a redirect `location`.
func queryValue(_ name: String, in location: String?) -> String? {
    guard let location, let components = URLComponents(string: location) else { return nil }
    return components.queryItems?.first(where: { $0.name == name })?.value
}

/// The string field `name` of a JSON object response body.
func jsonField(_ name: String, in res: TestResponse) -> String? {
    let object = try? JSONSerialization.jsonObject(with: Data(res.body.string.utf8)) as? [String: Any]
    return object?[name] as? String
}
