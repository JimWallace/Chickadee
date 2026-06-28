// APIServer/Routes/Web/EnrollmentRoutes.swift
//
// Course enrollment routes (any authenticated user).
//
//   GET  /enroll                        → enroll.leaf  (pick courses to join)
//   POST /enroll                        → save selections → redirect to /
//   POST /courses/:courseID/activate    → switch active course tab → redirect back

import Core
import Fluent
import Vapor

struct EnrollmentRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("enroll", use: enrollPage)
        routes.post("enroll", use: saveEnrollment)
        routes.post("courses", ":courseID", "activate", use: activateCourse)
    }

    // MARK: - GET /enroll

    @Sendable
    func enrollPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.internalServerError) }

        let allCourses = try await APICourse.query(on: req.db)
            .filter(\.$isArchived == false)
            .filter(\.$enrollmentModeRaw == CourseEnrollmentMode.open.rawValue)
            .sort(\.$code)
            .all()

        let enrolledIDs = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .all()
            .compactMap { $0.$course.id }

        let enrolledSet = Set(enrolledIDs)

        let rows = allCourses.compactMap { course -> EnrollCourseRow? in
            guard let id = course.id else { return nil }
            return EnrollCourseRow(
                id: id.uuidString,
                code: course.code,
                name: course.name,
                isEnrolled: enrolledSet.contains(id)
            )
        }

        return try await req.view.render(
            "enroll",
            EnrollContext(
                currentUser: req.currentUserContext,
                courses: rows
            ))
    }

    // MARK: - POST /enroll

    @Sendable
    func saveEnrollment(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.internalServerError) }

        struct EnrollBody: Content {
            var courseIDs: [String]?
        }
        let body = try req.content.decode(EnrollBody.self)
        let selectedIDs = Set((body.courseIDs ?? []).compactMap { UUID(uuidString: $0) })

        // Look up valid (non-archived) courses from the submitted IDs.
        let validCourses =
            selectedIDs.isEmpty
            ? []
            : try await APICourse.query(on: req.db)
                .filter(\.$id ~~ selectedIDs)
                .filter(\.$isArchived == false)
                .filter(\.$enrollmentModeRaw == CourseEnrollmentMode.open.rawValue)
                .all()
        let validIDs = Set(validCourses.compactMap(\.id))

        // Add new enrollments (ignore duplicates).
        for courseID in validIDs {
            let existing = try await APICourseEnrollment.query(on: req.db)
                .filter(\.$userID == userID)
                .filter(\.$course.$id == courseID)
                .count()
            if existing == 0 {
                try await saveSeededEnrollment(userID: userID, courseID: courseID, on: req.db)
            }
        }

        // If none selected → require at least one (stay on page).
        if validIDs.isEmpty {
            return req.redirect(to: "/enroll?error=none_selected")
        }

        return req.redirect(to: "/")
    }

    // MARK: - POST /courses/:courseID/activate

    @Sendable
    func activateCourse(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.internalServerError) }

        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString)
        else {
            throw Abort(.badRequest)
        }

        struct ActivateBody: Content {
            /// Optional post-activation destination. The instructor nav chips
            /// set this to "/instructor" so selecting a course jumps straight
            /// into its instructor view; the course strip omits it and lands
            /// back where the user clicked.
            var next: String?
        }
        let nextPath = (try? req.content.decode(ActivateBody.self))?.next

        // Verify the user is actually enrolled in this course.
        let activated: Bool
        if try await userIsEnrolled(userID: userID, inCourse: courseID, db: req.db) {
            req.session.data["activeCourseID"] = idString
            activated = true
        } else {
            activated = false
        }

        // Resolve the redirect target: an explicit (safe, local) `next` wins,
        // otherwise return to where the click came from, otherwise home.
        var target = safeLocalPath(nextPath) ?? req.headers.first(name: .referer) ?? "/"

        // Guard against an instructor dead-end: a target under /instructor 403s
        // unless the *newly active* course is one this user instructs. If the
        // just-activated course isn't, send them home instead of into a 403.
        if target.hasPrefix("/instructor") {
            let role = try await courseRole(of: userID, inCourse: courseID, db: req.db)
            let canInstruct = activated && (user.isAdmin || (role ?? .student) >= .instructor)
            if !canInstruct { target = "/" }
        }

        return req.redirect(to: target)
    }

    /// Returns `path` only when it is a safe in-app destination: a root-relative
    /// path (`/…`) that is not protocol-relative (`//host`). Anything else —
    /// absolute URLs, scheme-relative URLs, nil — returns nil so the caller
    /// falls back to the referer/home. Keeps the post-activation redirect from
    /// becoming an open redirect.
    private func safeLocalPath(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        return path
    }
}

// MARK: - View context types

private struct EnrollContext: Encodable {
    let currentUser: CurrentUserContext?
    let courses: [EnrollCourseRow]
    var error: String?
}

private struct EnrollCourseRow: Encodable {
    let id: String
    let code: String
    let name: String
    let isEnrolled: Bool
}
