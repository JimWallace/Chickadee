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

/// Per-request cache of the course-aware nav context.  `NavCourseContextMiddleware`
/// populates it once for every authenticated web request so the shared nav
/// (Instructor link + course tabs) renders on *every* page — including the
/// course-free ones (admin, account, …) whose handlers only ever build a
/// `req.currentUserContext`.
private struct CourseAwareUserContextStorageKey: StorageKey {
    typealias Value = CurrentUserContext
}

/// Per-request cache of the resolved active-course state, so the several
/// callers in one request (the nav middleware, `ActiveCourseStaffMiddleware`,
/// and the page handler) share a single DB resolution rather than each
/// re-querying — and so the auto-enroll/session side effects run once.
private struct ResolvedCourseStateStorageKey: StorageKey {
    typealias Value = ResolvedCourseState
}

extension Request {
    /// Returns a Leaf-encodable snapshot of the current user for view contexts.
    ///
    /// Prefers the course-aware context resolved once per request by
    /// `NavCourseContextMiddleware`, so the nav's Instructor link and course
    /// tabs appear on every rendered page — not just the course-scoped ones.
    /// Falls back to a course-free snapshot when no middleware has populated the
    /// cache (e.g. the MCP OAuth consent flow or any non-web request), which
    /// keeps the historical behaviour for those callers.
    var currentUserContext: CurrentUserContext? {
        if let cached = storage[CourseAwareUserContextStorageKey.self] { return cached }
        guard let user = auth.get(APIUser.self) else { return nil }
        return CurrentUserContext(user: user)
    }

    /// Builds a `CurrentUserContext` populated with course information from the DB.
    /// Call this from any route that needs course tabs or active-course filtering.
    /// The result is cached on the request so `currentUserContext` and any later
    /// caller reuse it without re-querying.
    func courseAwareUserContext() async throws -> CurrentUserContext? {
        if let cached = storage[CourseAwareUserContextStorageKey.self] { return cached }
        guard let user = auth.get(APIUser.self) else { return nil }
        let state = try await resolveActiveCourse(for: user)
        let context = CurrentUserContext(
            user: user, activeCourse: state.active, enrolledCourses: state.all)
        storage[CourseAwareUserContextStorageKey.self] = context
        return context
    }

    private static let activeCourseSessionKey = "activeCourseID"

    /// Resolves the active course for `user`, consulting the session and DB.
    /// Auto-enrolls the user in every course with enrollmentMode == .auto.
    /// Returns `activeCourseUUID == nil` when the user is not enrolled anywhere.
    /// Cached per request (the underlying work, including its side effects, runs
    /// once); see `computeActiveCourse` for the resolution itself.
    func resolveActiveCourse(for user: APIUser) async throws -> ResolvedCourseState {
        if let cached = storage[ResolvedCourseStateStorageKey.self] { return cached }
        let state = try await computeActiveCourse(for: user)
        storage[ResolvedCourseStateStorageKey.self] = state
        return state
    }

    private func computeActiveCourse(for user: APIUser) async throws -> ResolvedCourseState {
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
                try? await saveSeededEnrollment(for: user, courseID: courseID, on: db)
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
            CourseContext(
                id: $0.id, code: $0.code, name: $0.name,
                isActive: $0.id == activeCourseID, role: $0.role)
        }
        let active = markedCourses.first(where: \.isActive)
        return ResolvedCourseState(active: active, all: markedCourses, activeCourseUUID: activeCourseUUID)
    }

    private func loadEnrolledCourseContexts(userID: UUID) async throws -> [CourseContext] {
        // Delegates to the shared visibility resolver (role-augmented) so the
        // tab strip and the MCP listing surface stay in lockstep on which
        // courses are visible; the per-course role rides along for the nav.
        try await enrolledCoursesWithRoles(for: userID, on: db).compactMap { pair in
            guard let id = pair.course.id else { return nil }
            return CourseContext(
                id: id.uuidString, code: pair.course.code, name: pair.course.name,
                isActive: false, role: pair.role)
        }
    }
}

// MARK: - Course context types

/// Lightweight course info safe to embed in Leaf view contexts.
struct CourseContext: Encodable {
    let id: String
    let code: String
    let name: String
    var isActive: Bool
    /// The caller's per-course role in this course (Phase 2 of
    /// docs/multi-course-roles.md). Carried so the nav can decide instructor
    /// surfaces from the *active course's* role rather than the global one.
    /// Behaviour-neutral today — every enrollment's role mirrors the global
    /// role (Phase 1 backfill).
    let role: CourseRole
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
    /// The course the user is currently viewing (nil if no course info was resolved).
    let activeCourse: CourseContext?
    /// All courses the user is enrolled in (empty if no course info was resolved).
    let enrolledCourses: [CourseContext]
    /// True when the user is enrolled in more than one course (tab strip should show).
    let showCourseTabs: Bool
    /// True when the user is *staff* (TA or instructor, or an admin) in the
    /// active course. The nav's Instructor tab keys off this; the finer
    /// per-action floor (`ta` vs `instructor`) is enforced server-side (#417
    /// Slice E). Renamed from `isInstructorInActiveCourse` in #1127 — the old
    /// name predated the TA rung and had come to mean "staff".
    let isStaffInActiveCourse: Bool
    /// Every enrolled course where the user is staff (role ≥ `.ta`), plus
    /// *all* enrolled courses for an admin (who instructs the whole
    /// deployment). Drives the nav's Instructor surface so staff always have
    /// a direct link into each course they teach, regardless of which course
    /// is currently active. Inherits the code-sorted order of
    /// `enrolledCourses`.
    let staffCourses: [CourseContext]
    /// True when `staffCourses` is non-empty — the user is staff in at least
    /// one enrolled course. The nav's Instructor entry shows whenever this is
    /// true, not only when the *active* course happens to be one they teach.
    let isStaffAnywhere: Bool
    /// True when the user is staff in more than one course, so the nav should
    /// render the per-course Instructor strip (mirrors `showCourseTabs`).
    let showStaffTabs: Bool
    /// The single course this user staffs, when there is exactly one — the
    /// nav renders one direct "Instructor" link for it instead of a strip.
    /// nil when they staff zero or many courses.
    let primaryStaffCourse: CourseContext?

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
        self.activeCourse = activeCourse
        self.enrolledCourses = enrolledCourses
        self.showCourseTabs = enrolledCourses.count > 1
        // Staff (TA or instructor) in the active course see the Instructor
        // surface; the finer per-action floor is enforced server-side (#417
        // Slice E).
        self.isStaffInActiveCourse =
            activeCourse != nil && ((activeCourse?.role ?? .student) >= .ta || user.isAdmin)
        // An admin instructs the whole deployment, so every enrollment counts;
        // everyone else, every course where they are staff (TA or instructor).
        // Order follows `enrolledCourses` (code-sorted).
        let staffCourses =
            user.isAdmin ? enrolledCourses : enrolledCourses.filter { $0.role >= .ta }
        self.staffCourses = staffCourses
        self.isStaffAnywhere = !staffCourses.isEmpty
        self.showStaffTabs = staffCourses.count > 1
        self.primaryStaffCourse = staffCourses.count == 1 ? staffCourses[0] : nil
    }
}
