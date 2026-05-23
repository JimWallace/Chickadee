// APIServer/Models/APIUser.swift
//
// User account model. Server-only — Worker never sees this.
//
// Phase 6: username/password auth, three roles.
// Phase 7+ can swap authentication to SSO without changing callers.

import Core
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

    /// Opaque 8-character token used in instructor-facing per-student
    /// URL paths (e.g. `/:courseCode/students/:urlToken/submissions`)
    /// so usernames stop leaking into request logs and Referer headers
    /// (#556).  Declared optional only because Fluent + SQLite can't
    /// add a NOT NULL column post-hoc; in practice every row carries a
    /// token — fresh users get one from `init` below, and the
    /// `AddUrlTokenToUsers` migration backfills pre-existing rows.
    /// Uniqueness is enforced by `idx_users_url_token`.
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
    /// DB layer via `idx_users_url_token`; callers that need a
    /// guaranteed-unused token (e.g. the `AddUrlTokenToUsers` migration)
    /// retry on collision.
    static func generateURLToken(length: Int = 8) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).compactMap { _ in alphabet.randomElement(using: &rng) })
    }
}

// MARK: - Role helpers

extension APIUser {
    var isAdmin: Bool { role == "admin" }
    var isInstructor: Bool { role == "instructor" || role == "admin" }

    /// True for MCP service accounts (admin-provisioned, non-loginable agents).
    /// `mcp` is its own role — it does NOT imply instructor/admin.
    var isMCPAgent: Bool { role == "mcp" }

    /// Roles that may be assigned automatically at first login (local
    /// registration or SSO mapping).  `mcp` is intentionally excluded: MCP
    /// service accounts are created only by an admin, so no auto-provisioning
    /// path can mint an agent identity.
    static let autoAssignableRoles: Set<String> = ["student", "instructor", "admin"]

    /// Drops a proposed auto-assigned role that isn't in `autoAssignableRoles`
    /// (notably `mcp`), returning nil so the caller falls back to `student`.
    /// Defence in depth for the first-login paths.
    static func sanitizedAutoAssignedRole(_ proposed: String?) -> String? {
        proposed.flatMap { autoAssignableRoles.contains($0) ? $0 : nil }
    }
}

// MARK: - URL token

extension APIUser {
    /// Non-optional accessor for `urlToken`.  The column is technically
    /// nullable so the `AddUrlTokenToUsers` migration could add it as a
    /// post-hoc field on SQLite (which can't add NOT NULL to an existing
    /// column), but every row is expected to carry a token — fresh users
    /// get one from `init` and the migration backfills the rest.  Throw
    /// rather than silently emit a broken URL if the invariant breaks.
    func requireURLToken() throws -> String {
        guard let token = urlToken, !token.isEmpty else {
            throw Abort(
                .internalServerError,
                reason: "APIUser \(id?.uuidString ?? "?") is missing urlToken"
            )
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

/// Resolves a session ID back to a User on every authenticated request.
struct UserSessionAuthenticator: AsyncSessionAuthenticator {
    typealias User = APIUser

    func authenticate(sessionID: String, for request: Request) async throws {
        guard let uuid = UUID(uuidString: sessionID),
            let user = try await APIUser.find(uuid, on: request.db)
        else { return }  // Not found → stay unauthenticated; middleware handles it.
        request.auth.login(user)
    }
}

// MARK: - Request helper

extension Request {
    /// Returns a Leaf-encodable snapshot of the current user for view contexts.
    /// Does not include course information; use `courseAwareUserContext()` for pages with tabs.
    var currentUserContext: CurrentUserContext? {
        guard let user = auth.get(APIUser.self) else { return nil }
        return CurrentUserContext(user: user)
    }

    /// Builds a `CurrentUserContext` populated with course information from the DB.
    /// Call this from any route that needs course tabs or active-course filtering.
    func courseAwareUserContext() async throws -> CurrentUserContext? {
        guard let user = auth.get(APIUser.self) else { return nil }
        let state = try await resolveActiveCourse(for: user)
        return CurrentUserContext(user: user, activeCourse: state.active, enrolledCourses: state.all)
    }

    private static let activeCourseSessionKey = "activeCourseID"

    /// Resolves the active course for `user`, consulting the session and DB.
    /// Auto-enrolls the user in every course with enrollmentMode == .auto.
    /// Returns `activeCourseUUID == nil` when the user is not enrolled anywhere.
    func resolveActiveCourse(for user: APIUser) async throws -> ResolvedCourseState {
        guard let userID = user.id else {
            return ResolvedCourseState(active: nil, all: [], activeCourseUUID: nil)
        }

        // Count all non-archived courses so we know if auto-enroll applies.
        let allCourses = try await APICourse.query(on: db)
            .filter(\.$isArchived == false)
            .sort(\.$createdAt)
            .all()

        guard !allCourses.isEmpty else {
            return ResolvedCourseState(active: nil, all: [], activeCourseUUID: nil)
        }

        // Fetch current enrollments.
        var enrolledContexts = try await loadEnrolledCourseContexts(userID: userID)

        // Auto-enroll in every course whose mode is .auto that the user isn't already in.
        let autoCourses = allCourses.filter { $0.enrollmentMode == .auto }
        var didEnroll = false
        for course in autoCourses {
            guard let courseID = course.id else { continue }
            let alreadyEnrolled = enrolledContexts.contains { $0.id == courseID.uuidString }
            if !alreadyEnrolled {
                let enrollment = APICourseEnrollment(userID: userID, courseID: courseID)
                try? await enrollment.save(on: db)
                didEnroll = true
            }
        }
        if didEnroll {
            enrolledContexts = try await loadEnrolledCourseContexts(userID: userID)
        }

        guard !enrolledContexts.isEmpty else {
            return ResolvedCourseState(active: nil, all: [], activeCourseUUID: nil)
        }

        // Determine active course from session, or fall back to first enrolled.
        let sessionID = session.data[Request.activeCourseSessionKey]
        let activeCourseID: String
        if let sid = sessionID, enrolledContexts.contains(where: { $0.id == sid }) {
            activeCourseID = sid
        } else {
            activeCourseID = enrolledContexts[0].id
            session.data[Request.activeCourseSessionKey] = activeCourseID
        }

        let activeCourseUUID = UUID(uuidString: activeCourseID)
        let markedCourses = enrolledContexts.map {
            CourseContext(id: $0.id, code: $0.code, name: $0.name, isActive: $0.id == activeCourseID)
        }
        let active = markedCourses.first(where: \.isActive)
        return ResolvedCourseState(active: active, all: markedCourses, activeCourseUUID: activeCourseUUID)
    }

    private func loadEnrolledCourseContexts(userID: UUID) async throws -> [CourseContext] {
        let enrollments = try await APICourseEnrollment.query(on: db)
            .filter(\.$userID == userID)
            .with(\.$course)
            .all()
        return
            enrollments
            .compactMap { e -> CourseContext? in
                guard let id = e.course.id else { return nil }
                guard !e.course.isArchived else { return nil }  // hide archived courses everywhere
                return CourseContext(id: id.uuidString, code: e.course.code, name: e.course.name, isActive: false)
            }
            .sorted { $0.code < $1.code }
    }
}

// MARK: - Course context types

/// Lightweight course info safe to embed in Leaf view contexts.
struct CourseContext: Encodable {
    let id: String
    let code: String
    let name: String
    var isActive: Bool
}

/// The result of resolving which course is "active" for the current request.
struct ResolvedCourseState {
    let active: CourseContext?  // nil → user is not enrolled anywhere
    let all: [CourseContext]  // all enrolled courses (isActive set on one)
    let activeCourseUUID: UUID?  // for DB query filters; nil → no active course
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
    /// The course the user is currently viewing (nil if no course info was resolved).
    let activeCourse: CourseContext?
    /// All courses the user is enrolled in (empty if no course info was resolved).
    let enrolledCourses: [CourseContext]
    /// True when the user is enrolled in more than one course (tab strip should show).
    let showCourseTabs: Bool

    init(user: APIUser, activeCourse: CourseContext? = nil, enrolledCourses: [CourseContext] = []) {
        let normalizedPreferredName = user.preferredName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredName = (normalizedPreferredName?.isEmpty == false) ? normalizedPreferredName : nil
        let normalizedDisplayName = user.displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (normalizedDisplayName?.isEmpty == false) ? normalizedDisplayName : nil
        let normalizedEmail = user.email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let email = (normalizedEmail?.isEmpty == false) ? normalizedEmail : nil

        self.username = user.username
        self.preferredName = preferredName
        self.displayName = displayName
        self.email = email
        self.role = user.role
        self.isAdmin = user.isAdmin
        self.isInstructor = user.isInstructor
        self.activeCourse = activeCourse
        self.enrolledCourses = enrolledCourses
        self.showCourseTabs = enrolledCourses.count > 1
    }
}
