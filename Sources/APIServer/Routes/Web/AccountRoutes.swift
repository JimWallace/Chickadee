// APIServer/Routes/Web/AccountRoutes.swift
//
// User account & course membership routes (any authenticated user).
//
//   GET  /account                      → account.leaf (user info + enrolled courses)
//   POST /account/enroll               → join a course → redirect to /account
//   POST /account/unenroll/:courseID   → leave a course → redirect to /account

import Vapor
import Fluent
import Core

struct AccountRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("account",                          use: accountPage)
        routes.post("account", "enroll",               use: joinCourse)
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

        let enrolledRows = enrollments
            .compactMap { e -> AccountCourseRow? in
                guard let id = e.course.id else { return nil }
                return AccountCourseRow(
                    id: id.uuidString,
                    code: e.course.code,
                    name: e.course.name,
                    enrollmentMode: e.course.enrollmentMode.rawValue
                )
            }
            .sorted { $0.code < $1.code }

        let availableRows = allCourses
            .compactMap { c -> AccountCourseRow? in
                guard let id = c.id, !enrolledIDs.contains(id),
                      c.enrollmentMode == .open else { return nil }
                return AccountCourseRow(id: id.uuidString, code: c.code, name: c.name,
                                        enrollmentMode: c.enrollmentMode.rawValue)
            }

        return try await req.view.render("account", AccountContext(
            currentUser: req.currentUserContext,
            username: user.username,
            preferredName: user.preferredName,
            studentID: user.studentID,
            email: user.email,
            enrolledCourses: enrolledRows,
            availableCourses: availableRows,
            error: req.query[String.self, at: "error"]
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
            let enrollment = APICourseEnrollment(userID: userID, courseID: courseID)
            try await enrollment.save(on: req.db)
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
            throw Abort(.forbidden, reason: "You cannot leave a \(course.enrollmentMode.rawValue)-enrolment course.")
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

private struct AccountContext: Encodable {
    let currentUser: CurrentUserContext?
    let username: String
    let preferredName: String?
    let studentID: String?
    let email: String?
    let enrolledCourses: [AccountCourseRow]
    let availableCourses: [AccountCourseRow]
    let error: String?
}

private struct AccountCourseRow: Encodable {
    let id: String
    let code: String
    let name: String
    let enrollmentMode: String
}
