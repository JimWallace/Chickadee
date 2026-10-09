// APIServer/LTI/LTIServiceClient.swift
//
// The LTI Advantage service calls (docs/lti-1-3.md): the AGS line item and
// score calls the grade sweep makes, and the NRPS membership read the roster
// check makes. Each gets an access token by the client-credentials grant with
// a JWT assertion signed by the tool key. Tokens are cached per platform and
// scope set until shortly before they expire. All HTTP goes through `send`, so
// a test can answer for the LMS.

import Foundation
import JWT
import Vapor

actor LTIServiceClient {
    typealias Send = @Sendable (ClientRequest) async throws -> ClientResponse

    /// The platform facts a call needs.
    struct Platform: Sendable {
        let id: UUID
        let clientID: String
        let accessTokenURL: String
        /// The token-request JWT audience; nil = `accessTokenURL`.
        var tokenAudience: String?
        /// The hosts a call may reach (`LTIServiceHost`).
        let serviceHosts: Set<String>

        /// The service facts of a stored registration.
        init(id: UUID, registration platform: APILTIPlatform) {
            self.init(
                id: id, clientID: platform.clientID, accessTokenURL: platform.accessTokenURL,
                tokenAudience: platform.tokenAudience, serviceHosts: platform.registeredHosts)
        }

        /// A platform whose calls may reach the token URL's host and the
        /// hosts in `serviceHosts`.
        init(
            id: UUID, clientID: String, accessTokenURL: String, tokenAudience: String? = nil,
            serviceHosts: Set<String> = []
        ) {
            self.id = id
            self.clientID = clientID
            self.accessTokenURL = accessTokenURL
            self.tokenAudience = tokenAudience
            self.serviceHosts = serviceHosts.union(LTIServiceHost.hosts(of: [accessTokenURL]))
        }
    }

    static let lineItemContainerType = "application/vnd.ims.lis.v2.lineitemcontainer+json"
    static let lineItemType = "application/vnd.ims.lis.v2.lineitem+json"
    static let scoreType = "application/vnd.ims.lis.v1.score+json"
    static let membershipContainerType = "application/vnd.ims.lti-nrps.v2.membershipcontainer+json"
    static let agsScopes = [LTIAGSEndpoint.lineItemScope, LTIAGSEndpoint.scoreScope]
    static let nrpsScopes = [LTINRPSEndpoint.membershipScope]

    /// The most membership pages one read follows, so a platform whose `next`
    /// links loop cannot hold the request forever.
    static let maximumMembershipPages = 100

    /// A token is dropped this long before the platform says it expires.
    static let tokenMargin: TimeInterval = 60

    private struct CachedToken {
        let value: String
        let expiresAt: Date
    }

    private struct TokenKey: Hashable {
        let platformID: UUID
        let scopes: [String]
    }

    private let send: Send
    private var tokens: [TokenKey: CachedToken] = [:]

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
        let token = try await accessToken(for: platform, scopes: Self.agsScopes, keys: keys)

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
            throw LTIServiceError.unreadableResponse(.createLineItem)
        }
        return id
    }

    // MARK: - Scores

    func postScore(
        _ score: LTIScore, lineItemURL: String, platform: Platform, keys: LTIToolKeyAuthority
    ) async throws {
        let token = try await accessToken(for: platform, scopes: Self.agsScopes, keys: keys)
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: token)
        headers.replaceOrAdd(name: .contentType, value: Self.scoreType)
        do {
            _ = try await call(
                ClientRequest(
                    method: .POST, url: URI(string: Self.scoresURL(forLineItem: lineItemURL)),
                    headers: headers, body: ByteBuffer(data: try JSONEncoder().encode(score))),
                step: .postScore, platform: platform)
        } catch LTIServiceError.rejected(.postScore, status: 404) {
            throw LTIServiceError.lineItemGone
        }
    }

    // MARK: - Memberships

    /// Every member of the context whose NRPS membership URL is
    /// `membershipsURL`, following the `next` links of a paged answer.
    func members(
        membershipsURL: String, platform: Platform, keys: LTIToolKeyAuthority
    ) async throws
        -> [LTIMember]
    {
        let token = try await accessToken(for: platform, scopes: Self.nrpsScopes, keys: keys)
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: token)
        headers.replaceOrAdd(name: .accept, value: Self.membershipContainerType)

        var members: [LTIMember] = []
        var next: String? = membershipsURL
        var pages = 0
        while let url = next, pages < Self.maximumMembershipPages {
            let response = try await call(
                ClientRequest(method: .GET, url: URI(string: url), headers: headers),
                step: .memberships, platform: platform)
            members += try Self.decode(MembershipContainer.self, from: response, step: .memberships).members
            next = Self.nextPageURL(response.headers)
            pages += 1
        }
        return members
    }

    // MARK: - Access token

    private func accessToken(
        for platform: Platform, scopes: [String], keys: LTIToolKeyAuthority
    ) async throws
        -> String
    {
        let now = Date()
        let key = TokenKey(platformID: platform.id, scopes: scopes)
        if let cached = tokens[key], cached.expiresAt > now { return cached.value }

        let assertion = try await keys.sign(
            LTIClientAssertion(
                clientID: platform.clientID, audience: platform.tokenAudience ?? platform.accessTokenURL,
                issuedAt: now))
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/x-www-form-urlencoded")
        headers.replaceOrAdd(name: .accept, value: "application/json")
        let response = try await call(
            ClientRequest(
                method: .POST, url: URI(string: platform.accessTokenURL), headers: headers,
                body: ByteBuffer(string: Self.tokenRequestBody(assertion: assertion, scopes: scopes))),
            step: .token, platform: platform)
        let token = try Self.decode(TokenResponse.self, from: response, step: .token)
        let lifetime = TimeInterval(token.expiresIn ?? 3600) - Self.tokenMargin
        tokens[key] = CachedToken(value: token.accessToken, expiresAt: now.addingTimeInterval(lifetime))
        return token.accessToken
    }

    private func call(
        _ request: ClientRequest, step: LTIServiceError.Step, platform: Platform
    ) async throws
        -> ClientResponse
    {
        // Every URL a call uses passes here, the ones the platform sent in a
        // launch or a response included (docs/compliance/lti-audit-2026-10.md L-1).
        guard LTIServiceHost.permits(request.url.string, hosts: platform.serviceHosts) else {
            throw LTIServiceError.foreignHost(step)
        }
        let response = try await send(request)
        guard (200..<300).contains(response.status.code) else {
            // A refused token may have been revoked early: fetch a new one next time.
            if response.status == .unauthorized { tokens = tokens.filter { $0.key.platformID != platform.id } }
            throw LTIServiceError.rejected(step, status: response.status.code)
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

    private struct MembershipContainer: Decodable {
        let members: [LTIMember]
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
        _ type: T.Type, from response: ClientResponse, step: LTIServiceError.Step
    )
        throws -> T
    {
        guard let body = response.body, let value = try? JSONDecoder().decode(T.self, from: body) else {
            throw LTIServiceError.unreadableResponse(step)
        }
        return value
    }

    /// The form body of the client-credentials token request.
    static func tokenRequestBody(assertion: String, scopes: [String]) -> String {
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

    /// The `rel="next"` target of an RFC 8288 `Link` header, if any.
    static func nextPageURL(_ headers: HTTPHeaders) -> String? {
        for value in headers[.link] {
            for link in value.split(separator: ",") {
                let parts = link.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                guard let target = parts.first, target.hasPrefix("<"), target.hasSuffix(">"),
                    parts.dropFirst().contains(where: { $0.replacingOccurrences(of: "\"", with: "") == "rel=next" })
                else { continue }
                return String(target.dropFirst().dropLast())
            }
        }
        return nil
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
