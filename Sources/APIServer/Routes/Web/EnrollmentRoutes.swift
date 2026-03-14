// APIServer/Routes/Web/EnrollmentRoutes.swift
//
// Course enrollment routes (any authenticated user).
//
//   GET  /enroll                        → enroll.leaf  (pick courses to join)
//   POST /enroll                        → save selections → redirect to /
//   POST /courses/:courseID/activate    → switch active course tab → redirect back

import Vapor
import Fluent

struct EnrollmentRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("enroll",  use: enrollPage)
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
            .filter(\.$openEnrollment == true)
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

        return try await req.view.render("enroll", EnrollContext(
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
        let validCourses = selectedIDs.isEmpty
            ? []
            : try await APICourse.query(on: req.db)
                .filter(\.$id ~~ selectedIDs)
                .filter(\.$isArchived == false)
                .filter(\.$openEnrollment == true)
                .all()
        let validIDs = Set(validCourses.compactMap(\.id))

        // Add new enrollments (ignore duplicates).
        for courseID in validIDs {
            let existing = try await APICourseEnrollment.query(on: req.db)
                .filter(\.$userID == userID)
                .filter(\.$course.$id == courseID)
                .count()
            if existing == 0 {
                let enrollment = APICourseEnrollment(userID: userID, courseID: courseID)
                try await enrollment.save(on: req.db)
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

        // Verify the user is actually enrolled in this course.
        let enrolled = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .count()

        if enrolled > 0 {
            req.session.data["activeCourseID"] = idString
        }

        // Redirect back to where the user came from (tab click).
        let referer = req.headers.first(name: .referer) ?? "/"
        return req.redirect(to: referer)
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
