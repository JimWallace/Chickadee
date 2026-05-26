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
    case whoamiFailed(status: Int)
    case orgUnitLookupFailed(orgUnitID: String, status: Int)
    case gradeObjectsFetchFailed(orgUnitID: String, status: Int)

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
        case .whoamiFailed(let s):
            return "BrightSpace whoami failed (HTTP \(s))"
        case .orgUnitLookupFailed(let id, let s):
            return "BrightSpace org unit lookup for '\(id)' failed (HTTP \(s))"
        case .gradeObjectsFetchFailed(let id, let s):
            return "BrightSpace grade-objects fetch for org unit '\(id)' failed (HTTP \(s))"
        }
    }
}

// MARK: - Read-only lookup result types

/// Identity of the D2L account the configured service keys act as.
struct BrightSpaceWhoAmI: Content, Sendable {
    let identifier: String
    let uniqueName: String
    let displayName: String
}

/// Minimal org-unit info used to verify + label a course→org-unit binding.
struct BrightSpaceOrgUnitInfo: Content, Sendable {
    let identifier: String
    let name: String
    let code: String?
}

/// A grade item (grade object) within a course's grade book.
struct BrightSpaceGradeObject: Content, Sendable {
    let id: String
    let name: String
    let maxPoints: Double?
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
            let gradeObjectType: Int
            let pointsNumerator: Double
            enum CodingKeys: String, CodingKey {
                case gradeObjectType = "GradeObjectType"
                case pointsNumerator = "PointsNumerator"
            }
        }
        let body = NumericGradeValue(gradeObjectType: 1, pointsNumerator: earnedPoints)

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
        struct UserItem: Decodable {
            let userId: Int
            enum CodingKeys: String, CodingKey { case userId = "UserId" }
        }
        struct UserListResponse: Decodable {
            let items: [UserItem]
            enum CodingKeys: String, CodingKey { case items = "Items" }
        }
        let decoded = try response.content.decode(UserListResponse.self)
        guard let first = decoded.items.first else { return nil }
        return String(first.userId)
    }

    // MARK: - Connection test (whoami)

    /// Validates the configured service keys by calling the D2L `whoami`
    /// endpoint, returning the identity the keys act as.  Used by the
    /// "Test connection" button — surfaces auth problems before grades fail.
    func whoami(on application: Application) async throws -> BrightSpaceWhoAmI {
        let rawURL = "\(config.baseURL)/d2l/api/lp/\(BrightSpaceSyncConfig.lpAPIVersion)/users/whoami"
        let url = signed(url: rawURL, method: "GET")
        let response = try await application.client.get(URI(string: url))
        guard response.status == .ok else {
            throw BrightSpaceSyncError.whoamiFailed(status: Int(response.status.code))
        }
        struct WhoAmIResponse: Decodable {
            let identifier: String
            let firstName: String?
            let lastName: String?
            let uniqueName: String?
            enum CodingKeys: String, CodingKey {
                case identifier = "Identifier"
                case firstName = "FirstName"
                case lastName = "LastName"
                case uniqueName = "UniqueName"
            }
        }
        let decoded = try response.content.decode(WhoAmIResponse.self)
        let display = [decoded.firstName, decoded.lastName]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return BrightSpaceWhoAmI(
            identifier: decoded.identifier,
            uniqueName: decoded.uniqueName ?? "",
            displayName: display.isEmpty ? (decoded.uniqueName ?? decoded.identifier) : display
        )
    }

    // MARK: - Org unit lookup (verify course binding)

    /// Looks up an org unit by ID to confirm it exists and label it with its
    /// D2L name/code.  Returns nil when the org unit is not found (HTTP 404),
    /// so the caller can flag an unverified binding without throwing.
    func getOrgUnit(orgUnitID: String, on application: Application) async throws -> BrightSpaceOrgUnitInfo? {
        guard !orgUnitID.isEmpty else { return nil }
        let encoded = orgUnitID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? orgUnitID
        let rawURL = "\(config.baseURL)/d2l/api/lp/\(BrightSpaceSyncConfig.lpAPIVersion)/orgstructure/\(encoded)"
        let url = signed(url: rawURL, method: "GET")
        let response = try await application.client.get(URI(string: url))
        if response.status == .notFound { return nil }
        guard response.status == .ok else {
            throw BrightSpaceSyncError.orgUnitLookupFailed(
                orgUnitID: orgUnitID, status: Int(response.status.code))
        }
        struct OrgUnitResponse: Decodable {
            let identifier: String
            let name: String
            let code: String?
            enum CodingKeys: String, CodingKey {
                case identifier = "Identifier"
                case name = "Name"
                case code = "Code"
            }
        }
        let decoded = try response.content.decode(OrgUnitResponse.self)
        return BrightSpaceOrgUnitInfo(
            identifier: decoded.identifier, name: decoded.name, code: decoded.code)
    }

    // MARK: - Grade objects (dropdown source)

    /// Lists the grade items (grade objects) in a course's grade book so the
    /// instructor can pick one instead of hand-typing the numeric ID.
    func listGradeObjects(orgUnitID: String, on application: Application) async throws -> [BrightSpaceGradeObject] {
        guard !orgUnitID.isEmpty else { return [] }
        let encoded = orgUnitID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? orgUnitID
        let rawURL = "\(config.baseURL)/d2l/api/le/\(BrightSpaceSyncConfig.leAPIVersion)/\(encoded)/grades/"
        let url = signed(url: rawURL, method: "GET")
        let response = try await application.client.get(URI(string: url))
        guard response.status == .ok else {
            throw BrightSpaceSyncError.gradeObjectsFetchFailed(
                orgUnitID: orgUnitID, status: Int(response.status.code))
        }
        struct GradeObjectResponse: Decodable {
            let id: Int
            let name: String
            let maxPoints: Double?
            enum CodingKeys: String, CodingKey {
                case id = "Id"
                case name = "Name"
                case maxPoints = "MaxPoints"
            }
        }
        let decoded = try response.content.decode([GradeObjectResponse].self)
        return decoded.map {
            BrightSpaceGradeObject(id: String($0.id), name: $0.name, maxPoints: $0.maxPoints)
        }
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
