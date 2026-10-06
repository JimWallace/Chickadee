// APIServer/Models/APIUser.swift
//
// User account model. Server-only — Worker never sees this.
//
// Phase 6: username/password auth, three roles.
// Phase 7+ can swap authentication to SSO without changing callers.

import Core
import Fluent
import Vapor

/// User roles in ascending order of privilege (`student` < `instructor` <
/// `admin`), plus the out-of-band `mcp` service-account role.
///
/// The `role` DB column stays a plain string (no migration); this enum is
/// the authoritative vocabulary for it.
enum UserRole: String, Sendable {
    /// The deployment-global role of an ordinary human account (#417). Teaching
    /// authority is per-course now (`CourseRole` on the enrollment), so the
    /// deployment role only distinguishes an ordinary `user` from an `admin`
    /// operator (and the non-human `mcp` service account). The retired global
    /// `student` / `instructor` roles were folded into `user` by the
    /// `CollapseUserRoles` migration and are no longer part of the vocabulary; a
    /// row that still carries one of those legacy strings simply decodes to
    /// `nil` (`roleValue`), which reads as a non-admin, non-agent user.
    case user
    case admin
    /// MCP service accounts (admin-provisioned, non-loginable agents).
    /// `mcp` is its own role — it does NOT imply admin.
    case mcp
}

final class APIUser: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context,
    // never across unstructured concurrency.
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "username")
    var username: String

    @Field(key: "password_hash")
    var passwordHash: String

    @OptionalField(key: "auth_provider")
    var authProvider: String?

    @OptionalField(key: "external_subject")
    var externalSubject: String?

    @OptionalField(key: "email")
    var email: String?

    @OptionalField(key: "preferred_name")
    var preferredName: String?

    @OptionalField(key: "user_id")
    var userIdentifier: String?

    @OptionalField(key: "student_id")
    var studentID: String?

    @OptionalField(key: "display_name")
    var displayName: String?

    /// Opaque 8-character token used in instructor-facing per-student
    /// URL paths (e.g. `/:courseCode/students/:urlToken/submissions`)
    /// so usernames stop leaking into request logs and Referer headers
    /// (#556).  Declared optional because the column originally shipped
    /// as a nullable post-hoc ALTER (Fluent + SQLite can't add NOT NULL
    /// to an existing table); in practice every row carries a token —
    /// fresh users get one from `init` below, and the historical
    /// url-token migration backfilled pre-existing rows.  Uniqueness is
    /// enforced by `idx_users_url_token`.
    @OptionalField(key: "url_token")
    var urlToken: String?

    @OptionalField(key: "last_login_at")
    var lastLoginAt: Date?

    /// Refreshed on every authenticated request (debounced) by
    /// `UserActivityMiddleware`. Drives the activity columns on the
    /// instructor and admin dashboards, where `lastLoginAt` would otherwise
    /// freeze at the original cookie-session login.
    @OptionalField(key: "last_seen_at")
    var lastSeenAt: Date?

    /// Cached D2L BrightSpace internal user ID (looked up once by studentID and stored).
    @OptionalField(key: "brightspace_user_id")
    var brightspaceUserID: String?

    /// The student's generated chickadee, as `AvatarSpec` JSON.
    ///
    /// Nullable because it is materialized the first time an avatar is needed
    /// (the account page, a roster, a leaderboard or an admin list), not at
    /// signup.
    /// Read it through `AvatarStore.ensureSpec`, which decodes it, draws one on
    /// first use, and stores the result — the spec is the record, not a seed to
    /// re-derive from (docs/student-avatars.md, decision 2).
    @OptionalField(key: "avatar_spec")
    var avatarSpecJSON: String?

    /// `UserRole` raw value; column stays a string.
    @Field(key: "role")
    var role: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        username: String,
        passwordHash: String,
        role: String,
        authProvider: String? = nil,
        externalSubject: String? = nil,
        email: String? = nil,
        preferredName: String? = nil,
        userIdentifier: String? = nil,
        studentID: String? = nil,
        displayName: String? = nil,
        urlToken: String? = nil,
        lastLoginAt: Date? = nil,
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.username = username
        self.passwordHash = passwordHash
        self.authProvider = authProvider
        self.externalSubject = externalSubject
        self.email = email
        self.preferredName = preferredName
        self.userIdentifier = userIdentifier
        self.studentID = studentID
        self.displayName = displayName
        self.urlToken = urlToken ?? APIUser.generateURLToken()
        self.lastLoginAt = lastLoginAt
        self.lastSeenAt = lastSeenAt
        self.role = role
    }

    /// Generates a fresh 8-character lowercase alphanumeric URL token.
    /// 36^8 ≈ 2.8 × 10^12 combinations leaves a comfortable margin even
    /// at institution-scale enrollment.  Uniqueness is enforced at the
    /// DB layer via `idx_users_url_token`; a caller that needs a
    /// guaranteed-unused token retries on collision.
    static func generateURLToken(length: Int = 8) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).compactMap { _ in alphabet.randomElement(using: &rng) })
    }
}

// MARK: - Role helpers

extension APIUser {
    /// The user's role as a typed enum, or nil if the stored string is
    /// outside the known vocabulary (defensive — should not happen).
    var roleValue: UserRole? { UserRole(rawValue: role) }

    var isAdmin: Bool { roleValue == .admin }

    /// True for MCP service accounts (admin-provisioned, non-loginable agents).
    /// `mcp` is its own role — it does NOT imply admin.
    var isMCPAgent: Bool { roleValue == .mcp }

    /// Roles that may be assigned automatically at first login (local
    /// registration or SSO mapping).  `mcp` is intentionally excluded: MCP
    /// service accounts are created only by an admin. The retired `student` /
    /// `instructor` roles are excluded too (#417 Slice G2), so an SSO claim can
    /// never re-mint them — a first login maps to `user` (or `admin`).
    static let autoAssignableRoles: Set<String> = [
        UserRole.user.rawValue,
        UserRole.admin.rawValue,
    ]

    /// Drops a proposed auto-assigned role that isn't in `autoAssignableRoles`
    /// (notably `mcp` and the retired `student`/`instructor`), returning nil so
    /// the caller falls back to `user`. Defence in depth for the first-login paths.
    static func sanitizedAutoAssignedRole(_ proposed: String?) -> String? {
        proposed.flatMap { autoAssignableRoles.contains($0) ? $0 : nil }
    }
}

// MARK: - URL token

extension APIUser {
    /// Non-optional accessor for `urlToken`.  The column is technically
    /// nullable (it originally shipped as a post-hoc ALTER on SQLite,
    /// which can't add NOT NULL to an existing table), but every row is
    /// expected to carry a token — fresh users get one from `init` and
    /// the historical migration backfilled the rest.  Throw rather than
    /// silently emit a broken URL if the invariant breaks.
    func requireURLToken() throws -> String {
        guard let token = urlToken, !token.isEmpty else {
            throw AppError.internalFailure(reason: "APIUser \(id?.uuidString ?? "?") is missing urlToken")
        }
        return token
    }
}

// MARK: - Vapor session authentication

extension APIUser: SessionAuthenticatable {
    /// The value stored in the session cookie. UUID string is stable and opaque.
    typealias SessionID = String

    var sessionID: String { id?.uuidString ?? "" }
}
