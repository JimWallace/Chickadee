// APIServer/Models/APIUser.swift
//
// User account model. Server-only — Worker never sees this.
//
// Phase 6: username/password auth, three roles.
// Phase 7+ can swap authentication to SSO without changing callers.

import Fluent
import Vapor

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

    @OptionalField(key: "last_login_at")
    var lastLoginAt: Date?

    /// "student" | "instructor" | "admin"
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
        lastLoginAt: Date? = nil
    ) {
        self.id           = id
        self.username     = username
        self.passwordHash = passwordHash
        self.authProvider = authProvider
        self.externalSubject = externalSubject
        self.email = email
        self.preferredName = preferredName
        self.userIdentifier = userIdentifier
        self.studentID = studentID
        self.displayName = displayName
        self.lastLoginAt = lastLoginAt
        self.role         = role
    }
}

// MARK: - Role helpers

extension APIUser {
    var isAdmin:      Bool { role == "admin" }
    var isInstructor: Bool { role == "instructor" || role == "admin" }
}

// MARK: - Vapor session authentication

extension APIUser: SessionAuthenticatable {
    /// The value stored in the session cookie. UUID string is stable and opaque.
    typealias SessionID = String

    var sessionID: String { id?.uuidString ?? "" }
}

/// Resolves a session ID back to a User on every authenticated request.
struct UserSessionAuthenticator: AsyncSessionAuthenticator {
    typealias User = APIUser

    func authenticate(sessionID: String, for request: Request) async throws {
        guard let uuid = UUID(uuidString: sessionID),
              let user = try await APIUser.find(uuid, on: request.db)
        else { return }    // Not found → stay unauthenticated; middleware handles it.
        request.auth.login(user)
    }
}

// MARK: - Request helper

extension Request {
    /// Returns a Leaf-encodable snapshot of the current user for view contexts.
    var currentUserContext: CurrentUserContext? {
        guard let user = auth.get(APIUser.self) else { return nil }
        return CurrentUserContext(user: user)
    }
}

/// Encodable snapshot of the authenticated user, safe to embed in any Leaf context.
struct CurrentUserContext: Encodable {
    let username: String
    let preferredName: String?
    let displayName: String?
    let email: String?
    let role: String
    let isAdmin: Bool
    let isInstructor: Bool

    init(user: APIUser) {
        let normalizedPreferredName = user.preferredName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredName = (normalizedPreferredName?.isEmpty == false) ? normalizedPreferredName : nil
        let normalizedDisplayName = user.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (normalizedDisplayName?.isEmpty == false) ? normalizedDisplayName : nil
        let normalizedEmail = user.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (normalizedEmail?.isEmpty == false) ? normalizedEmail : nil

        self.username     = user.username
        self.preferredName = preferredName
        self.displayName  = displayName
        self.email        = email
        self.role         = user.role
        self.isAdmin      = user.isAdmin
        self.isInstructor = user.isInstructor
    }
}
