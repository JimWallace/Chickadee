// APIServer/LTI/LTIAGSClient.swift
//
// The three AGS calls the grade sweep makes (docs/lti-1-3.md "Grades through
// AGS"): an access token by the client-credentials grant with a JWT assertion
// signed by the tool key, a line item found or created by `resourceId`, and a
// score POST. Access tokens are cached per platform until shortly before they
// expire. All HTTP goes through `send`, so a test can answer for the LMS.

import Foundation
import JWT
import Vapor

actor LTIAGSClient {
    typealias Send = @Sendable (ClientRequest) async throws -> ClientResponse

    /// The platform facts a call needs.
    struct Platform: Sendable {
        let id: UUID
        let clientID: String
        let accessTokenURL: String
    }

    static let lineItemContainerType = "application/vnd.ims.lis.v2.lineitemcontainer+json"
    static let lineItemType = "application/vnd.ims.lis.v2.lineitem+json"
    static let scoreType = "application/vnd.ims.lis.v1.score+json"
    static let scopes = [LTIAGSEndpoint.lineItemScope, LTIAGSEndpoint.scoreScope]

    /// A token is dropped this long before the platform says it expires.
    static let tokenMargin: TimeInterval = 60

    private struct CachedToken {
        let value: String
        let expiresAt: Date
    }

    private let send: Send
    private var tokens: [UUID: CachedToken] = [:]

    init(send: @escaping Send) {
        self.send = send
    }

    // MARK: - Line items

    /// The URL of the line item whose `resourceId` is `resourceID`, created
    /// with `label` and `scoreMaximum` when the LMS has none.
    func lineItemURL(
        resourceID: String, label: String, scoreMaximum: Double,
        lineItemsURL: String, platform: Platform, keys: LTIToolKeyAuthority
    ) async throws -> String {
        let token = try await accessToken(for: platform, keys: keys)

        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: token)
        headers.replaceOrAdd(name: .accept, value: Self.lineItemContainerType)
        let found = try await call(
            ClientRequest(
                method: .GET, url: URI(string: Self.url(lineItemsURL, addingResourceID: resourceID)),
                headers: headers),
            step: .findLineItem, platform: platform)
        let existing = try Self.decode([LineItem].self, from: found, step: .findLineItem)
        if let match = existing.first(where: { $0.resourceId == resourceID }), let id = match.id {
            return id
        }

        headers.replaceOrAdd(name: .accept, value: Self.lineItemType)
        headers.replaceOrAdd(name: .contentType, value: Self.lineItemType)
        let body = LineItem(id: nil, label: label, scoreMaximum: scoreMaximum, resourceId: resourceID)
        let created = try await call(
            ClientRequest(
                method: .POST, url: URI(string: lineItemsURL), headers: headers,
                body: ByteBuffer(data: try JSONEncoder().encode(body))),
            step: .createLineItem, platform: platform)
        guard let id = try Self.decode(LineItem.self, from: created, step: .createLineItem).id else {
            throw LTIAGSError.unreadableResponse(.createLineItem)
        }
        return id
    }

    // MARK: - Scores

    func postScore(
        _ score: LTIScore, lineItemURL: String, platform: Platform, keys: LTIToolKeyAuthority
    ) async throws {
        let token = try await accessToken(for: platform, keys: keys)
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: token)
        headers.replaceOrAdd(name: .contentType, value: Self.scoreType)
        do {
            _ = try await call(
                ClientRequest(
                    method: .POST, url: URI(string: Self.scoresURL(forLineItem: lineItemURL)),
                    headers: headers, body: ByteBuffer(data: try JSONEncoder().encode(score))),
                step: .postScore, platform: platform)
        } catch LTIAGSError.rejected(.postScore, status: 404) {
            throw LTIAGSError.lineItemGone
        }
    }

    // MARK: - Access token

    private func accessToken(for platform: Platform, keys: LTIToolKeyAuthority) async throws -> String {
        let now = Date()
        if let cached = tokens[platform.id], cached.expiresAt > now { return cached.value }

        let assertion = try await keys.sign(
            LTIClientAssertion(
                clientID: platform.clientID, audience: platform.accessTokenURL, issuedAt: now))
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/x-www-form-urlencoded")
        headers.replaceOrAdd(name: .accept, value: "application/json")
        let response = try await call(
            ClientRequest(
                method: .POST, url: URI(string: platform.accessTokenURL), headers: headers,
                body: ByteBuffer(string: Self.tokenRequestBody(assertion: assertion))),
            step: .token, platform: platform)
        let token = try Self.decode(TokenResponse.self, from: response, step: .token)
        let lifetime = TimeInterval(token.expiresIn ?? 3600) - Self.tokenMargin
        tokens[platform.id] = CachedToken(value: token.accessToken, expiresAt: now.addingTimeInterval(lifetime))
        return token.accessToken
    }

    private func call(
        _ request: ClientRequest, step: LTIAGSError.Step, platform: Platform
    ) async throws
        -> ClientResponse
    {
        let response = try await send(request)
        guard (200..<300).contains(response.status.code) else {
            // A refused token may have been revoked early: fetch a new one next time.
            if response.status == .unauthorized { tokens[platform.id] = nil }
            throw LTIAGSError.rejected(step, status: response.status.code)
        }
        return response
    }

    // MARK: - Wire formats

    private struct LineItem: Codable {
        let id: String?
        let label: String?
        let scoreMaximum: Double?
        let resourceId: String?
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    private static func decode<T: Decodable>(
        _ type: T.Type, from response: ClientResponse, step: LTIAGSError.Step
    )
        throws -> T
    {
        guard let body = response.body, let value = try? JSONDecoder().decode(T.self, from: body) else {
            throw LTIAGSError.unreadableResponse(step)
        }
        return value
    }

    /// The form body of the client-credentials token request.
    static func tokenRequestBody(assertion: String) -> String {
        let fields = [
            ("grant_type", "client_credentials"),
            ("client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"),
            ("client_assertion", assertion),
            ("scope", scopes.joined(separator: " ")),
        ]
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return
            fields
            .map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $1)" }
            .joined(separator: "&")
    }

    /// `lineItemsURL` with a `resource_id` filter, keeping any query it has.
    static func url(_ lineItemsURL: String, addingResourceID resourceID: String) -> String {
        guard var components = URLComponents(string: lineItemsURL) else { return lineItemsURL }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "resource_id", value: resourceID)]
        return components.string ?? lineItemsURL
    }

    /// The scores endpoint of a line item: its path plus `/scores`, keeping
    /// any query the line item URL has.
    static func scoresURL(forLineItem lineItemURL: String) -> String {
        guard var components = URLComponents(string: lineItemURL) else { return lineItemURL + "/scores" }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/scores"
        return components.string ?? lineItemURL + "/scores"
    }
}
