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

    // Fallback API versions, used only when live version negotiation
    // (`/d2l/api/{product}/versions/`) is unavailable. Set to UW-known-good
    // values (the reference client pins le=1.75 / lp=1.47); the client prefers
    // the server's advertised `LatestVersion`. Hardcoding a version the LMS
    // doesn't support 404s every call, so these are a floor, not the target.
    static let leAPIVersion = "1.75"
    static let lpAPIVersion = "1.47"

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

enum BrightSpaceSyncError: Error, CustomStringConvertible, LocalizedError {
    case notConfigured
    case userLookupFailed(orgDefinedId: String, status: Int)
    case userNotFound(orgDefinedId: String)
    case gradePushFailed(status: Int, body: String)
    case missingPoints
    case whoamiFailed(status: Int, body: String)
    case orgUnitLookupFailed(orgUnitID: String, status: Int)
    case gradeObjectsFetchFailed(orgUnitID: String, status: Int)
    case classlistFetchFailed(orgUnitID: String, status: Int)

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
        case .whoamiFailed(let s, let b):
            return "BrightSpace whoami failed (HTTP \(s))\(b.isEmpty ? "" : ": \(b)")"
        case .orgUnitLookupFailed(let id, let s):
            return "BrightSpace org unit lookup for '\(id)' failed (HTTP \(s))"
        case .gradeObjectsFetchFailed(let id, let s):
            return "BrightSpace grade-objects fetch for org unit '\(id)' failed (HTTP \(s))"
        case .classlistFetchFailed(let id, let s):
            return "BrightSpace classlist fetch for org unit '\(id)' failed (HTTP \(s))"
        }
    }

    // Surface `description` through `localizedDescription` so the UI's
    // "Connection failed: \(error.localizedDescription)" shows the HTTP status
    // and D2L's error body, not Swift's generic "(… error N.)".
    var errorDescription: String? { description }
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

/// One member of a course's LEARN classlist, reduced to the identity fields
/// Chickadee can match a roster entry against.  `orgDefinedID` is the student
/// number (matches `APIUser.studentID`); `username` is the D2L login name.
struct BrightSpaceClasslistEntry: Content, Sendable {
    let orgDefinedID: String?
    let username: String?
    /// D2L internal user id (`Identifier`) — the key a grade push targets.
    let userID: String?
}

// MARK: - Paged list envelope

/// Decodes the two interchangeable Valence list envelopes: bookmark-paged
/// (`Items` + `PagingInfo`) and continuation-URL (`Objects` + `Next`). The
/// reference client's `get_paged` branches on which keys are present; the
/// pagination step itself is `valenceNextPageURL`.
struct ValencePagedEnvelope<Element: Decodable>: Decodable {
    let items: [Element]?
    let objects: [Element]?
    let pagingInfo: PagingInfo?
    let next: String?
    struct PagingInfo: Decodable {
        let bookmark: String?
        let hasMoreItems: Bool?
        enum CodingKeys: String, CodingKey {
            case bookmark = "Bookmark"
            case hasMoreItems = "HasMoreItems"
        }
    }
    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case objects = "Objects"
        case pagingInfo = "PagingInfo"
        case next = "Next"
    }
    var elements: [Element] { items ?? objects ?? [] }
}

// MARK: - Grading seam

/// The network-touching BrightSpace operations the grade-sync sweep depends on.
///
/// `BrightSpaceAPIClient` is the production conformer. Tests substitute an
/// in-memory fake so the sweep's grade-selection, debounce, and user-ID
/// caching logic can be exercised without a live D2L endpoint.
protocol BrightSpaceGrading: Sendable {
    func lookupUserID(orgDefinedId: String, on application: Application) async throws -> String?
    func fetchClasslist(
        orgUnitID: String, on application: Application
    ) async throws
        -> [BrightSpaceClasslistEntry]
    func pushGrade(
        orgUnitID: String,
        gradeObjectID: String,
        bsUserID: String,
        earnedPoints: Double,
        on application: Application
    ) async throws
}

// MARK: - Client

actor BrightSpaceAPIClient: BrightSpaceGrading {
    private let config: BrightSpaceSyncConfig

    /// Negotiated API version per D2L product code ("lp"/"le"), cached for the
    /// client's lifetime (the client is rebuilt on (re)authorize / restart).
    private var negotiatedVersions: [String: String] = [:]

    /// Clock-skew correction (seconds) learned from a D2L "Timestamp out of
    /// range" 403; added to the request timestamp on every subsequent signing.
    private var serverSkewSeconds = 0

    init(config: BrightSpaceSyncConfig) {
        self.config = config
    }

    // MARK: - Valence auth signing

    // Appends Valence auth query parameters to a URL.
    //
    // Signing base string: "<METHOD>&<lowercase_path>&<unix_timestamp>" where
    // path is the URL path only (no query string, no host) and the timestamp is
    // seconds (plus any learned clock skew). Verified against Brightspace's
    // official valence-sdk-python
    // (`'{0}&{1}&{2}'.format(method.upper(), path.lower(), time)`).
    // x_c = HMAC-SHA256(appKey, baseString) as base64url (no padding)
    // x_d = HMAC-SHA256(userKey, baseString) as base64url (no padding)
    private func signed(url urlString: String, method: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970) + serverSkewSeconds
        let path = valencePath(of: urlString)
        let baseString = valenceRequestBaseString(method: method, path: path, timestamp: timestamp)
        let appSig = hmacSHA256Base64URL(key: config.appKey, message: baseString)
        let userSig = hmacSHA256Base64URL(key: config.userKey, message: baseString)
        let sep = urlString.contains("?") ? "&" : "?"
        return
            "\(urlString)\(sep)x_a=\(config.appID)&x_b=\(config.userID)&x_c=\(appSig)&x_d=\(userSig)&x_t=\(timestamp)"
    }

    private func hmacSHA256Base64URL(key: String, message: String) -> String {
        let symmetricKey = SymmetricKey(data: Data(key.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symmetricKey)
        return Data(mac).base64URLEncodedString()
    }

    // MARK: - Request transport (signing + clock-skew retry)

    /// Signs `rawURL` for `method` ("GET"/"PUT") and sends it. If D2L rejects the
    /// request with a "Timestamp out of range" 403, learns the clock skew from
    /// the response body and retries exactly once with a corrected timestamp.
    private func sendSigned(
        method: String,
        rawURL: String,
        on app: Application,
        beforeSend: (@Sendable (inout ClientRequest) throws -> Void)? = nil
    ) async throws -> ClientResponse {
        func attempt() async throws -> ClientResponse {
            let uri = URI(string: signed(url: rawURL, method: method))
            if method.uppercased() == "PUT" {
                return try await app.client.put(uri) { req in try beforeSend?(&req) }
            }
            return try await app.client.get(uri) { req in try beforeSend?(&req) }
        }
        let response = try await attempt()
        guard response.status == .forbidden else { return response }
        // Peek the body non-destructively (a copied ByteBuffer has its own reader
        // index) so a genuine permission 403 is still returned intact to the caller.
        var bodyBuf = response.body
        let len = bodyBuf?.readableBytes ?? 0
        let bodyText = (len > 0 ? bodyBuf?.readString(length: len) : nil) ?? ""
        guard let serverTime = valenceServerTimeFromTimestampError(body: bodyText) else {
            return response
        }
        serverSkewSeconds = serverTime - Int(Date().timeIntervalSince1970)
        return try await attempt()
    }

    // MARK: - API version negotiation

    /// Resolves the API version for a D2L product code ("lp"/"le"): an ops env
    /// pin wins (`BRIGHTSPACE_LE_API_VERSION` / `BRIGHTSPACE_LP_API_VERSION`),
    /// otherwise the server's advertised `LatestVersion` from
    /// `/d2l/api/{product}/versions/` (cached), falling back to `fallback` when
    /// discovery is unavailable. Avoids 404s from requesting an unsupported
    /// version (the reference client pins these by hand).
    private func apiVersion(_ product: String, fallback: String, on app: Application) async -> String {
        if let pinned = trimmedEnv("BRIGHTSPACE_\(product.uppercased())_API_VERSION") {
            return pinned
        }
        if let cached = negotiatedVersions[product] { return cached }
        let rawURL = "\(config.baseURL)/d2l/api/\(product)/versions/"
        do {
            let response = try await sendSigned(method: "GET", rawURL: rawURL, on: app)
            guard response.status == .ok else { return fallback }
            struct ProductVersions: Decodable {
                let latestVersion: String
                enum CodingKeys: String, CodingKey { case latestVersion = "LatestVersion" }
            }
            let latest = try response.content.decode(ProductVersions.self)
                .latestVersion.trimmingCharacters(in: .whitespaces)
            let resolved = latest.isEmpty ? fallback : latest
            negotiatedVersions[product] = resolved
            return resolved
        } catch {
            return fallback
        }
    }

    // MARK: - Paged list reads

    /// Follows a Valence list endpoint across every page (either paging
    /// convention) and returns the concatenated elements. The 10_000-page guard
    /// is a safety stop against a server that never clears its "more" flag.
    private func fetchAllPages<Element: Decodable>(
        firstRawURL: String,
        on app: Application,
        failure: (Int) -> BrightSpaceSyncError
    ) async throws -> [Element] {
        var url = firstRawURL
        var collected: [Element] = []
        for _ in 0..<10_000 {
            let response = try await sendSigned(method: "GET", rawURL: url, on: app)
            guard response.status == .ok else { throw failure(Int(response.status.code)) }
            let page = try response.content.decode(ValencePagedEnvelope<Element>.self)
            collected.append(contentsOf: page.elements)
            guard
                let next = valenceNextPageURL(
                    firstPageURL: firstRawURL,
                    baseURL: config.baseURL,
                    pagingBookmark: page.pagingInfo?.bookmark,
                    pagingHasMore: page.pagingInfo?.hasMoreItems,
                    next: page.next)
            else { break }
            url = next
        }
        return collected
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
        let leVersion = await apiVersion(
            "le", fallback: BrightSpaceSyncConfig.leAPIVersion, on: application)
        let rawURL =
            "\(config.baseURL)/d2l/api/le/\(leVersion)/\(orgUnitID)/grades/\(gradeObjectID)/values/\(bsUserID)"

        // D2L's IncomingGradeValueNumeric requires `Comments` and
        // `PrivateComments` RichText blocks — omitting them 400s with
        // "Comments and PrivateComments are mandatory". We send empty Text.
        struct RichTextInput: Content {
            let content: String
            let type: String
            enum CodingKeys: String, CodingKey {
                case content = "Content"
                case type = "Type"
            }
        }
        struct NumericGradeValue: Content {
            let gradeObjectType: Int
            let pointsNumerator: Double
            let comments: RichTextInput
            let privateComments: RichTextInput
            enum CodingKeys: String, CodingKey {
                case gradeObjectType = "GradeObjectType"
                case pointsNumerator = "PointsNumerator"
                case comments = "Comments"
                case privateComments = "PrivateComments"
            }
        }
        let emptyRichText = RichTextInput(content: "", type: "Text")
        let body = NumericGradeValue(
            gradeObjectType: 1, pointsNumerator: earnedPoints,
            comments: emptyRichText, privateComments: emptyRichText)

        let response = try await sendSigned(method: "PUT", rawURL: rawURL, on: application) { req in
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

        let lpVersion = await apiVersion(
            "lp", fallback: BrightSpaceSyncConfig.lpAPIVersion, on: application)
        let encoded = orgDefinedId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? orgDefinedId
        let rawURL = "\(config.baseURL)/d2l/api/lp/\(lpVersion)/users/?orgDefinedId=\(encoded)"

        let response = try await sendSigned(method: "GET", rawURL: rawURL, on: application)

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
        let lpVersion = await apiVersion(
            "lp", fallback: BrightSpaceSyncConfig.lpAPIVersion, on: application)
        let rawURL = "\(config.baseURL)/d2l/api/lp/\(lpVersion)/users/whoami"
        let response = try await sendSigned(method: "GET", rawURL: rawURL, on: application)
        guard response.status == .ok else {
            var bodyBuf = response.body
            let bodyLen = bodyBuf?.readableBytes ?? 0
            let bodyText = bodyBuf?.readString(length: bodyLen) ?? ""
            throw BrightSpaceSyncError.whoamiFailed(
                status: Int(response.status.code), body: String(bodyText.prefix(500)))
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
        let lpVersion = await apiVersion(
            "lp", fallback: BrightSpaceSyncConfig.lpAPIVersion, on: application)
        let encoded = orgUnitID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? orgUnitID
        let rawURL = "\(config.baseURL)/d2l/api/lp/\(lpVersion)/orgstructure/\(encoded)"
        let response = try await sendSigned(method: "GET", rawURL: rawURL, on: application)
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
        let leVersion = await apiVersion(
            "le", fallback: BrightSpaceSyncConfig.leAPIVersion, on: application)
        let encoded = orgUnitID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? orgUnitID
        let rawURL = "\(config.baseURL)/d2l/api/le/\(leVersion)/\(encoded)/grades/"
        let response = try await sendSigned(method: "GET", rawURL: rawURL, on: application)
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

    // MARK: - Classlist (roster reconciliation)

    /// Fetches the org unit's current classlist so the Chickadee roster can be
    /// reconciled against LEARN.  Withdrawn / dropped students do not appear in
    /// the classlist, which is the signal the Students tab uses to flag stale
    /// enrollments for manual removal.
    func fetchClasslist(
        orgUnitID: String, on application: Application
    ) async throws
        -> [BrightSpaceClasslistEntry]
    {
        guard !orgUnitID.isEmpty else { return [] }
        let leVersion = await apiVersion(
            "le", fallback: BrightSpaceSyncConfig.leAPIVersion, on: application)
        let encoded = orgUnitID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? orgUnitID
        // The non-paged /classlist/ can truncate on large courses; /classlist/paged/
        // returns a bookmark-paged envelope we walk to completion (see fetchAllPages).
        let rawURL = "\(config.baseURL)/d2l/api/le/\(leVersion)/\(encoded)/classlist/paged/"
        // D2L returns ClasslistUser objects; we keep the identity fields we
        // match on plus `Identifier`, the internal user id a grade push targets.
        struct ClasslistUserResponse: Decodable {
            let identifier: String?
            let orgDefinedId: String?
            let username: String?
            enum CodingKeys: String, CodingKey {
                case identifier = "Identifier"
                case orgDefinedId = "OrgDefinedId"
                case username = "Username"
            }
        }
        let rows: [ClasslistUserResponse] = try await fetchAllPages(
            firstRawURL: rawURL, on: application
        ) { status in
            .classlistFetchFailed(orgUnitID: orgUnitID, status: status)
        }
        return rows.map {
            BrightSpaceClasslistEntry(
                orgDefinedID: $0.orgDefinedId, username: $0.username, userID: $0.identifier)
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
