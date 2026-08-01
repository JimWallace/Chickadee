// APIServer/Services/BrightSpaceSyncTypes.swift
//
// The non-actor types of the BrightSpace sync subsystem: the env-derived
// sync configuration, the error vocabulary, and the Codable DTOs mirroring
// D2L Valence wire shapes (lookup results + the paged list envelope).
// Split out of BrightSpaceAPIClient.swift in the 0.5 cleanup so the client
// file is the actor and its request plumbing only.

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
    case groupCategoriesFetchFailed(orgUnitID: String, status: Int)
    case groupsFetchFailed(orgUnitID: String, categoryID: String, status: Int)

    /// D2L response bodies are embedded in descriptions only up to this many
    /// characters. The body is D2L-controlled text that can echo user-specific
    /// detail, and descriptions flow into logs, sync-log detail rows, and the
    /// admin diagnostic MCP surface (compliance audit F-2) — the truncated
    /// prefix keeps the error class diagnosable without the full payload.
    static let describedBodyLimit = 120

    var description: String {
        switch self {
        case .notConfigured:
            return "BrightSpace sync is not configured (missing env vars)"
        case .userLookupFailed(_, let s):
            // The orgDefinedId (an institutional student identifier) is
            // deliberately NOT described: descriptions reach the query_logs
            // buffer and the sync-log detail surfaced over the admin MCP
            // (compliance audit F-2). The associated value still carries it
            // for programmatic use.
            return "BrightSpace user lookup failed (HTTP \(s))"
        case .userNotFound:
            return "BrightSpace user not found in the org unit classlist"
        case .gradePushFailed(let s, let b):
            return "BrightSpace grade push failed (HTTP \(s))\(Self.describedBody(b))"
        case .missingPoints:
            return "No grade points available to push"
        case .whoamiFailed(let s, let b):
            return "BrightSpace whoami failed (HTTP \(s))\(Self.describedBody(b))"
        case .orgUnitLookupFailed(let id, let s):
            return "BrightSpace org unit lookup for '\(id)' failed (HTTP \(s))"
        case .gradeObjectsFetchFailed(let id, let s):
            return "BrightSpace grade-objects fetch for org unit '\(id)' failed (HTTP \(s))"
        case .classlistFetchFailed(let id, let s):
            return "BrightSpace classlist fetch for org unit '\(id)' failed (HTTP \(s))"
        case .groupCategoriesFetchFailed(let id, let s):
            return "BrightSpace group-categories fetch for org unit '\(id)' failed (HTTP \(s))"
        case .groupsFetchFailed(let id, let cat, let s):
            return "BrightSpace groups fetch for org unit '\(id)' category '\(cat)' failed (HTTP \(s))"
        }
    }

    /// ": <body prefix>" for a described D2L body, empty when the body is —
    /// truncated to `describedBodyLimit` (audit F-2).
    private static func describedBody(_ body: String) -> String {
        guard !body.isEmpty else { return "" }
        return ": \(body.prefix(describedBodyLimit))"
    }

    // Surface `description` through `localizedDescription` so the UI's
    // "Connection failed: \(error.localizedDescription)" shows the HTTP status
    // and the truncated D2L error body, not Swift's generic "(… error N.)".
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
    /// D2L grade item type: "Numeric", "PassFail", "SelectBox", "Text",
    /// "Calculated", "Formula", … nil when not captured. Chickadee only syncs
    /// points to "Numeric" items; the dropdown surfaces the type so an
    /// instructor doesn't map a category or a non-numeric item by mistake.
    let gradeType: String?
    /// Whether a numeric item accepts a value above its MaxPoints. nil = unknown.
    let canExceed: Bool?

    init(
        id: String, name: String, maxPoints: Double?,
        gradeType: String? = nil, canExceed: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.maxPoints = maxPoints
        self.gradeType = gradeType
        self.canExceed = canExceed
    }
}

/// D2L grade-object JSON, shared by the list (`grades/`) and single-item
/// (`grades/{id}`) endpoints, which return the same shape.
struct GradeObjectJSON: Decodable {
    let id: Int
    let name: String
    let maxPoints: Double?
    let gradeType: String?
    let canExceed: Bool?
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case maxPoints = "MaxPoints"
        case gradeType = "GradeType"
        case canExceed = "CanExceed"
    }
    var asGradeObject: BrightSpaceGradeObject {
        BrightSpaceGradeObject(
            id: String(id), name: name, maxPoints: maxPoints,
            gradeType: gradeType, canExceed: canExceed)
    }
}

/// A D2L group category (e.g. "Lab Sections"), which contains a set of groups
/// (e.g. "Lab 1", "Lab 2", …). One category per course is designated as the
/// section source via `APICourse.brightspaceSectionCategoryID`.
struct BrightSpaceGroupCategory: Content, Sendable {
    let categoryID: String
    let name: String
}

/// One group within a D2L group category, together with the D2L internal user
/// IDs of its current members.
struct BrightSpaceGroup: Content, Sendable {
    let groupID: String
    let name: String
    /// D2L internal user IDs (`Identifier`) of enrolled members.
    let enrollments: [String]
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
