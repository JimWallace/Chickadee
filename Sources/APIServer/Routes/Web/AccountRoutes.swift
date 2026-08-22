// APIServer/Routes/Web/AccountRoutes.swift
//
// User account & course membership routes (any authenticated user).
//
//   GET  /account                      → account.leaf (user info + enrolled courses)
//   POST /account/enroll               → join a course → redirect to /account
//   POST /account/unenroll/:courseID   → leave a course → redirect to /account

import Core
import Fluent
import Vapor

struct AccountRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("account", use: accountPage)
        routes.post("account", "enroll", use: joinCourse)
        routes.post("account", "unenroll", ":courseID", use: leaveCourse)
    }

    // MARK: - GET /account

    @Sendable
    func accountPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.internalServerError) }

        // All non-archived courses.
        let allCourses = try await APICourse.query(on: req.db)
            .filter(\.$isArchived == false)
            .sort(\.$code)
            .all()

        // Current enrollments.
        let enrollments = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .with(\.$course)
            .all()
        let enrolledIDs = Set(enrollments.compactMap { $0.$course.id })

        // Slip-day balances per enrolled course (#1228): one query for every
        // unrefunded spend, grouped by course in memory.
        let unrefundedSpends = try await APISlipDaySpend.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$refundedAt == nil)
            .all()
        var spendCountByCourseID: [UUID: Int] = [:]
        for spend in unrefundedSpends {
            spendCountByCourseID[spend.courseID, default: 0] += 1
        }

        // Per-course handles, materialized on first view — for STUDENT
        // enrollments only, the same gate the slip-day line below applies and
        // for the same kind of reason: a pseudonym is for a student who will
        // appear pseudonymously, and staff teaching a course appear under their
        // own name. Gating here also keeps staff from consuming handles out of
        // a course's finite space. `ensureHandle` is a no-op read once the row
        // carries one.
        var handlesByCourseID: [UUID: String] = [:]
        for enrollment in enrollments where enrollment.role == .student {
            guard let courseID = enrollment.course.id else { continue }
            handlesByCourseID[courseID] = try await AvatarStore.ensureHandle(
                for: enrollment, on: req.db)
        }

        let enrolledRows =
            enrollments
            .compactMap { e -> AccountCourseRow? in
                guard let id = e.course.id else { return nil }
                // "N of M slip days left" only where it means something: the
                // course has slip days on and this enrollment is a student
                // (staff never hold a balance). The phrase carries its own
                // noun so the row needs no "Slip days:" label beside it.
                let policy = e.course.slipDayPolicy
                let slipDaysText: String?
                if policy.enabled, e.role == .student {
                    let total = policy.daysPerStudent + (e.slipDaysAdjustment ?? 0)
                    let used = spendCountByCourseID[id] ?? 0
                    slipDaysText = "\(max(total - used, 0)) of \(total) slip days left"
                } else {
                    slipDaysText = nil
                }
                return AccountCourseRow(
                    id: id.uuidString,
                    code: e.course.code,
                    name: e.course.name,
                    enrollmentMode: e.course.enrollmentMode.rawValue,
                    slipDaysText: slipDaysText,
                    handle: handlesByCourseID[id]
                )
            }
            .sorted { $0.code < $1.code }

        let availableRows =
            allCourses
            .compactMap { c -> AccountCourseRow? in
                guard let id = c.id, !enrolledIDs.contains(id),
                    c.enrollmentMode == .open
                else { return nil }
                return AccountCourseRow(
                    id: id.uuidString, code: c.code, name: c.name,
                    enrollmentMode: c.enrollmentMode.rawValue,
                    slipDaysText: nil, handle: nil)
            }

        // Personal-data export state (#557) for the "Your data" section.
        let export = try await APIDataExport.query(on: req.db)
            .filter(\.$userID == userID)
            .first()
        let dateFormatter = waterlooDateTimeFormatter()

        let identityName = accountIdentityName(
            displayName: user.displayName,
            preferredName: user.preferredName,
            username: user.username)
        return try await req.view.render(
            "account",
            AccountContext(
                currentUser: req.currentUserContext,
                username: user.username,
                preferredName: user.preferredName,
                identityName: identityName,
                identitySecondary: accountIdentitySecondary(
                    identityName: identityName, username: user.username),
                avatar: AvatarPresentation(
                    for: try await AvatarStore.ensureSpec(for: user, on: req.db),
                    size: .standard,
                    accessibility: .decorative),
                studentID: user.studentID,
                email: user.email,
                enrolledCourses: enrolledRows,
                availableCourses: availableRows,
                hasEnrolledCourses: !enrolledRows.isEmpty,
                hasAvailableCourses: !availableRows.isEmpty,
                error: req.query[String.self, at: "error"],
                exportStatus: export?.statusValue?.rawValue ?? "none",
                exportRequestedAtDisplay: export.map { dateFormatter.string(from: $0.requestedAt) },
                exportCompletedAtDisplay: export?.completedAt.map(dateFormatter.string(from:)),
                exportCanRequest: dataExportCanBeRequested(export),
                exportNotice: req.query[String.self, at: "exportNotice"],
                exportError: req.query[String.self, at: "exportError"]
            ))
    }

    // MARK: - POST /account/enroll

    @Sendable
    func joinCourse(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.internalServerError) }

        struct JoinBody: Content { var courseID: String }
        let body = try req.content.decode(JoinBody.self)

        guard let courseID = UUID(uuidString: body.courseID),
            let course = try await APICourse.find(courseID, on: req.db),
            !course.isArchived
        else {
            return req.redirect(to: "/account?error=invalid")
        }

        let existing = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .count()

        if existing == 0 {
            try await saveSeededEnrollment(userID: userID, courseID: courseID, on: req.db)
        }

        return req.redirect(to: "/account")
    }

    // MARK: - POST /account/unenroll/:courseID

    @Sendable
    func leaveCourse(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.internalServerError) }

        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString)
        else {
            throw Abort(.badRequest)
        }

        // Only open-mode courses can be self-left.
        // Closed courses are instructor-managed; auto courses are mandatory.
        guard let course = try await APICourse.find(courseID, on: req.db) else {
            throw Abort(.notFound)
        }
        guard course.enrollmentMode == .open else {
            throw AppError.forbidden(action: "leave a \(course.enrollmentMode.rawValue)-enrolment course")
        }

        try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .delete()

        // If the session active course was this one, clear it so next request re-selects.
        if req.session.data["activeCourseID"] == idString {
            req.session.data["activeCourseID"] = nil
        }

        return req.redirect(to: "/account")
    }
}

// MARK: - View context types

/// The name shown beside the identity circle: the full name the IdP released
/// when there is one, else the preferred name, else the username.
///
/// One resolution, used for the heading and for the identity row, so the two
/// can never disagree.
func accountIdentityName(displayName: String?, preferredName: String?, username: String) -> String {
    for candidate in [displayName, preferredName] {
        if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty {
            return candidate
        }
    }
    return username
}

/// The muted line under the identity name, or nil when it would merely repeat
/// it. A local account with no name on file resolves its heading to the
/// username, and printing the username twice reads as a bug rather than as
/// identity.
func accountIdentitySecondary(identityName: String, username: String) -> String? {
    identityName == username ? nil : username
}

private struct AccountContext: Encodable {
    let currentUser: CurrentUserContext?
    let username: String
    let preferredName: String?
    /// The heading beside the avatar. See `accountIdentityName`.
    let identityName: String
    /// The username under the heading, nil when the heading already IS the
    /// username. See `accountIdentitySecondary`.
    let identitySecondary: String?
    /// The student's generated chickadee, replacing the initials monogram this
    /// page carried until v0.5.  Materialized on first render by
    /// `AvatarStore.ensureSpec`, and decorative: the name beside it carries the
    /// identity, so announcing the bird too would only repeat it.
    let avatar: AvatarPresentation
    let studentID: String?
    let email: String?
    let enrolledCourses: [AccountCourseRow]
    let availableCourses: [AccountCourseRow]
    /// Emptiness, decided in Swift because Leaf cannot decide it.
    ///
    /// LeafKit has no property resolution for `.isEmpty` on an array: the path
    /// resolves to nil, so `#if(rows.isEmpty)` is ALWAYS false and
    /// `#if(!rows.isEmpty)` is ALWAYS true. Both spellings therefore render the
    /// table, which is why this page showed an "Available courses" heading over
    /// a header-only table with nothing in it. (The type-level coercion is a
    /// second trap in the same area: `#if(array)` converts via `.bool(isEmpty)`,
    /// so a bare array test is true when the array is EMPTY.)
    let hasEnrolledCourses: Bool
    let hasAvailableCourses: Bool
    let error: String?
    /// Personal-data export state (#557): "none" | "pending" | "complete" |
    /// "failed", plus display timestamps and whether the request button shows.
    let exportStatus: String
    let exportRequestedAtDisplay: String?
    let exportCompletedAtDisplay: String?
    let exportCanRequest: Bool
    let exportNotice: String?
    let exportError: String?
}

private struct AccountCourseRow: Encodable {
    let id: String
    let code: String
    let name: String
    let enrollmentMode: String
    /// "1 of 2 remaining" — the slip-day balance for a student enrollment in
    /// a course with the policy on; nil hides the line (#1228).
    let slipDaysText: String?
    /// This student's pseudonym in this course, "Quiet Cedar". nil hides the
    /// line — a course whose word lists are exhausted, which is a real state
    /// rather than an error: the avatar still shows.
    let handle: String?
}
