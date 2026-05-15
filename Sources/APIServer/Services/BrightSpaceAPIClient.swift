// APIServer/Services/BrightSpaceAPIClient.swift
//
// Thin D2L BrightSpace REST API client used for grade sync.
//
// Auth: D2L Valence "App + User" key signing — each request URL is signed
//       with HMAC-SHA256 using the App Key (x_c) and User Key (x_d).
//       No token endpoint; signatures are computed per-request.
//
// Grade push: PUT /d2l/api/le/{ver}/{orgUnitId}/grades/{gradeObjectId}/values/{userId}
// User lookup: GET /d2l/api/lp/{ver}/users/?orgDefinedId={id}
//
// Required env vars: BRIGHTSPACE_URL, BRIGHTSPACE_APP_ID, BRIGHTSPACE_APP_KEY,
//                    BRIGHTSPACE_USER_ID, BRIGHTSPACE_USER_KEY
// Optional:          BRIGHTSPACE_SYNC_DEBOUNCE_SECS (default 90)

import Crypto
import Foundation
import Vapor

// MARK: - Config

struct BrightSpaceSyncConfig: Sendable {
    let baseURL: String
    let appID: String
    let appKey: String
    let userID: String
    let userKey: String
    let debounceSecs: TimeInterval

    static let leAPIVersion = "1.85"
    static let lpAPIVersion = "1.28"

    static func fromEnvironment() -> Self? {
        guard
            let base = trimmedEnv("BRIGHTSPACE_URL"),
            let appID = trimmedEnv("BRIGHTSPACE_APP_ID"),
            let appKey = trimmedEnv("BRIGHTSPACE_APP_KEY"),
            let userID = trimmedEnv("BRIGHTSPACE_USER_ID"),
            let userKey = trimmedEnv("BRIGHTSPACE_USER_KEY")
        else { return nil }

        let debounce = (environmentDouble("BRIGHTSPACE_SYNC_DEBOUNCE_SECS") ?? 90)
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        return BrightSpaceSyncConfig(
            baseURL: trimmedBase,
            appID: appID,
            appKey: appKey,
            userID: userID,
            userKey: userKey,
            debounceSecs: debounce > 0 ? debounce : 90
        )
    }
}

// MARK: - Error

enum BrightSpaceSyncError: Error, CustomStringConvertible {
    case notConfigured
    case userLookupFailed(orgDefinedId: String, status: Int)
    case userNotFound(orgDefinedId: String)
    case gradePushFailed(status: Int, body: String)
    case missingPoints

    var description: String {
        switch self {
        case .notConfigured:
            return "BrightSpace sync is not configured (missing env vars)"
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

// MARK: - Client

actor BrightSpaceAPIClient {
    private let config: BrightSpaceSyncConfig

    init(config: BrightSpaceSyncConfig) {
        self.config = config
    }

    // MARK: - Valence auth signing

    // Appends Valence auth query parameters to a URL.
    //
    // Signing base string: "<unix_timestamp>\n<METHOD>\n<lowercase_path>"
    // where path is the URL path only (no query string, no host).
    // x_c = HMAC-SHA256(appKey, baseString) as base64url (no padding)
    // x_d = HMAC-SHA256(userKey, baseString) as base64url (no padding)
    private func signed(url urlString: String, method: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        guard let path = URL(string: urlString)?.path else { return urlString }
        let baseString = "\(timestamp)\n\(method.uppercased())\n\(path.lowercased())"
        let appSig = hmacSHA256Base64URL(key: config.appKey, message: baseString)
        let userSig = hmacSHA256Base64URL(key: config.userKey, message: baseString)
        let sep = urlString.contains("?") ? "&" : "?"
        return
            "\(urlString)\(sep)x_a=\(config.appID)&x_b=\(config.userID)&x_c=\(appSig)&x_d=\(userSig)&x_t=\(timestamp)"
    }

    private func hmacSHA256Base64URL(key: String, message: String) -> String {
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
        return Data(mac).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Push grade

    /// Push `earnedPoints` for `bsUserID` to the BrightSpace grade item.
    /// Callers should resolve `bsUserID` first via `lookupUserID(orgDefinedId:on:)`.
    func pushGrade(
        orgUnitID: String,
        gradeObjectID: String,
        bsUserID: String,
        earnedPoints: Double,
        on application: Application
    ) async throws {
        let rawURL =
            "\(config.baseURL)/d2l/api/le/\(BrightSpaceSyncConfig.leAPIVersion)/\(orgUnitID)/grades/\(gradeObjectID)/values/\(bsUserID)"
        let url = signed(url: rawURL, method: "PUT")

        struct NumericGradeValue: Content {
            let GradeObjectType: Int
            let PointsNumerator: Double
        }
        let body = NumericGradeValue(GradeObjectType: 1, PointsNumerator: earnedPoints)

        let response = try await application.client.put(URI(string: url)) { req in
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

        let encoded = orgDefinedId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? orgDefinedId
        let rawURL = "\(config.baseURL)/d2l/api/lp/\(BrightSpaceSyncConfig.lpAPIVersion)/users/?orgDefinedId=\(encoded)"
        let url = signed(url: rawURL, method: "GET")

        let response = try await application.client.get(URI(string: url))

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
