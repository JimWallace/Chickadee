// APIServer/Services/BrightSpaceAPIClient.swift
//
// Thin D2L BrightSpace REST API client used for grade sync.
//
// Auth: OAuth2 client credentials (POST /d2l/auth/oauth2/token).
// Grade push: PUT /d2l/api/le/{ver}/{orgUnitId}/grades/{gradeObjectId}/values/{userId}
// User lookup: GET /d2l/api/lp/{ver}/users/?orgDefinedId={id}
//
// Tokens are cached in memory until 60 seconds before expiry.

import Vapor
import Foundation

// MARK: - Config

struct BrightSpaceSyncConfig: Sendable {
    let baseURL: String        // e.g. "https://uw.brightspace.com"
    let clientID: String
    let clientSecret: String
    let debounceSecs: TimeInterval  // default 90

    static let leAPIVersion = "1.85"
    static let lpAPIVersion = "1.28"

    static func fromEnvironment() -> Self? {
        guard
            let base   = Environment.get("BRIGHTSPACE_URL")?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
            !base.isEmpty,
            let id     = Environment.get("BRIGHTSPACE_CLIENT_ID")?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
            !id.isEmpty,
            let secret = Environment.get("BRIGHTSPACE_CLIENT_SECRET")?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
            !secret.isEmpty
        else { return nil }

        let debounce: TimeInterval
        if let raw = Environment.get("BRIGHTSPACE_SYNC_DEBOUNCE_SECS"),
           let secs = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           secs > 0 {
            debounce = secs
        } else {
            debounce = 90
        }

        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        return BrightSpaceSyncConfig(
            baseURL: trimmedBase,
            clientID: id,
            clientSecret: secret,
            debounceSecs: debounce
        )
    }
}

// MARK: - Error

enum BrightSpaceSyncError: Error, CustomStringConvertible {
    case notConfigured
    case tokenFetchFailed(status: Int, body: String)
    case userLookupFailed(orgDefinedId: String, status: Int)
    case userNotFound(orgDefinedId: String)
    case gradePushFailed(status: Int, body: String)
    case missingPoints

    var description: String {
        switch self {
        case .notConfigured:
            return "BrightSpace sync is not configured (missing env vars)"
        case .tokenFetchFailed(let s, let b):
            return "BrightSpace token fetch failed (HTTP \(s)): \(b)"
        case .userLookupFailed(let id, let s):
            return "BrightSpace user lookup for '\(id)' failed (HTTP \(s))"
        case .userNotFound(let id):
            return "BrightSpace user not found for orgDefinedId '\(id)'"
        case .gradePushFailed(let s, let b):
            return "BrightSpace grade push failed (HTTP \(s)): \(b)"
        case .missingPoints:
            return "No grade points available to push"
        }
    }
}

// MARK: - Token cache

private struct CachedToken: Sendable {
    let value: String
    let expiresAt: Date
}

// MARK: - Client

actor BrightSpaceAPIClient {
    private let config: BrightSpaceSyncConfig
    private var cachedToken: CachedToken?

    init(config: BrightSpaceSyncConfig) {
        self.config = config
    }

    // MARK: - Push grade

    /// Push `earnedPoints` for `bsUserID` to the BrightSpace grade item.
    /// Callers should resolve `bsUserID` first via `resolveUserID(orgDefinedId:on:)`.
    func pushGrade(
        orgUnitID: String,
        gradeObjectID: String,
        bsUserID: String,
        earnedPoints: Double,
        on application: Application
    ) async throws {
        let token = try await fetchToken(on: application)
        let url = "\(config.baseURL)/d2l/api/le/\(BrightSpaceSyncConfig.leAPIVersion)/\(orgUnitID)/grades/\(gradeObjectID)/values/\(bsUserID)"

        struct NumericGradeValue: Content {
            let GradeObjectType: Int
            let PointsNumerator: Double
        }
        let body = NumericGradeValue(GradeObjectType: 1, PointsNumerator: earnedPoints)

        let response = try await application.client.put(URI(string: url)) { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            req.headers.contentType = .json
            try req.content.encode(body, as: .json)
        }

        guard (200...299).contains(response.status.code) else {
            var bodyBuf = response.body
            let bodyLen = bodyBuf?.readableBytes ?? 0
            let bodyText = bodyBuf?.readString(length: bodyLen) ?? ""
            throw BrightSpaceSyncError.gradePushFailed(status: Int(response.status.code), body: bodyText)
        }
    }

    // MARK: - User ID lookup

    /// Looks up the D2L internal user ID for `orgDefinedId` (the student number).
    /// Returns nil when the student has no BrightSpace account.
    func lookupUserID(orgDefinedId: String, on application: Application) async throws -> String? {
        guard !orgDefinedId.isEmpty else { return nil }

        let token = try await fetchToken(on: application)
        let encoded = orgDefinedId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? orgDefinedId
        let url = "\(config.baseURL)/d2l/api/lp/\(BrightSpaceSyncConfig.lpAPIVersion)/users/?orgDefinedId=\(encoded)"

        let response = try await application.client.get(URI(string: url)) { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
        }

        guard response.status == .ok else {
            throw BrightSpaceSyncError.userLookupFailed(
                orgDefinedId: orgDefinedId,
                status: Int(response.status.code)
            )
        }

        // D2L returns { "Items": [{ "UserId": 12345, ... }], "PagingInfo": {...} }
        struct UserListResponse: Decodable {
            struct UserItem: Decodable {
                let UserId: Int
            }
            let Items: [UserItem]
        }
        let decoded = try response.content.decode(UserListResponse.self)
        guard let first = decoded.Items.first else { return nil }
        return String(first.UserId)
    }

    // MARK: - Token management

    private func fetchToken(on application: Application) async throws -> String {
        let now = Date()
        if let cached = cachedToken, cached.expiresAt > now {
            return cached.value
        }

        let url = "\(config.baseURL)/d2l/auth/oauth2/token"
        let credentials = "\(config.clientID):\(config.clientSecret)"
        let encoded = Data(credentials.utf8).base64EncodedString()

        let response = try await application.client.post(URI(string: url)) { req in
            req.headers.add(name: .authorization, value: "Basic \(encoded)")
            req.headers.contentType = .urlEncodedForm
            try req.content.encode(
                ["grant_type": "client_credentials", "scope": "core:*:*"],
                as: .urlEncodedForm
            )
        }

        guard response.status == .ok else {
            var tokenBuf = response.body
            let tokenLen = tokenBuf?.readableBytes ?? 0
            let bodyText = tokenBuf?.readString(length: tokenLen) ?? ""
            throw BrightSpaceSyncError.tokenFetchFailed(status: Int(response.status.code), body: bodyText)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int
        }
        let token = try response.content.decode(TokenResponse.self)
        let expiresAt = now.addingTimeInterval(TimeInterval(token.expires_in) - 60)
        cachedToken = CachedToken(value: token.access_token, expiresAt: expiresAt)
        return token.access_token
    }
}

// MARK: - Application storage

struct BrightSpaceAPIClientKey: StorageKey {
    typealias Value = BrightSpaceAPIClient
}

extension Application {
    var brightSpaceClient: BrightSpaceAPIClient? {
        get { storage[BrightSpaceAPIClientKey.self] }
        set { storage[BrightSpaceAPIClientKey.self] = newValue }
    }
}
