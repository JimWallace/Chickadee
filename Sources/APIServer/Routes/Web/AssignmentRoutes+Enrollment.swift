// APIServer/Routes/Web/AssignmentRoutes+Enrollment.swift
//
// Enrollment-related handlers for AssignmentRoutes.
// Extracted from AssignmentRoutes.swift — no behaviour changes.

import Vapor
import Fluent
import Core

extension AssignmentRoutes {
    // MARK: - GET /instructor/enroll-csv

    @Sendable
    func enrollCSVForm(req: Request) async throws -> View {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isInstructor else { throw Abort(.forbidden) }

        let courseState = try await req.resolveActiveCourse(for: caller)
        guard let courseContext = courseState.active,
              let courseID = courseState.activeCourseUUID,
              let course = try await APICourse.find(courseID, on: req.db),
              !course.isArchived
        else {
            throw Abort(.badRequest, reason: "No active course selected.")
        }

        struct EnrollCSVFormContext: Encodable {
            let currentUser: CurrentUserContext?
            let courseID: String
            let courseCode: String
            let courseName: String
            let error: String?
        }

        return try await req.view.render("instructor-enroll-csv", EnrollCSVFormContext(
            currentUser: req.currentUserContext,
            courseID: courseID.uuidString,
            courseCode: courseContext.code,
            courseName: courseContext.name,
            error: req.query[String.self, at: "error"]
        ))
    }

    // MARK: - POST /courses/:courseID/enrollment-mode

    @Sendable
    func setCourseEnrollmentMode(req: Request) async throws -> Response {
        struct Body: Content { var enrollmentMode: String? }
        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let course   = try await APICourse.find(courseID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        let body = try? req.content.decode(Body.self)
        course.enrollmentMode = CourseEnrollmentMode(rawValue: body?.enrollmentMode ?? "") ?? .open
        try await course.save(on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /courses/:courseID/enroll-csv

    @Sendable
    func instructorBulkEnrollCSV(req: Request) async throws -> View {
        struct BulkEnrollForm: Content { var file: Data }

        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let course   = try await APICourse.find(courseID, on: req.db),
            !course.isArchived
        else {
            throw Abort(.badRequest, reason: "Invalid or archived course.")
        }

        let form = try req.content.decode(BulkEnrollForm.self)

        let rawUsernames = parseUsernamesFromCSV(form.file)
        var seen = Set<String>()
        let uniqueUsernames = rawUsernames.filter { seen.insert($0).inserted }

        let usernameSet = Set(uniqueUsernames)
        let allUsers = try await APIUser.query(on: req.db).all()
        let matchedUsers = allUsers.filter { usernameSet.contains($0.username) }

        let matchedUsernameSet = Set(matchedUsers.map { $0.username })
        let notFoundUsernames = uniqueUsernames
            .filter { !matchedUsernameSet.contains($0) }
            .sorted()

        let existingEnrollments = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseID)
            .all()
        let alreadyEnrolledUserIDs = Set(existingEnrollments.map { $0.userID })

        var enrolledCount = 0
        var alreadyEnrolledCount = 0

        for user in matchedUsers {
            guard let userID = user.id else { continue }
            if alreadyEnrolledUserIDs.contains(userID) {
                alreadyEnrolledCount += 1
            } else {
                let enrollment = APICourseEnrollment(userID: userID, courseID: courseID)
                try await enrollment.save(on: req.db)
                enrolledCount += 1
            }
        }

        return try await req.view.render("admin-enroll-csv-result", EnrollCSVResultContext(
            currentUser:          req.currentUserContext,
            courseCode:           course.code,
            courseName:           course.name,
            enrolledCount:        enrolledCount,
            alreadyEnrolledCount: alreadyEnrolledCount,
            notFoundUsernames:    notFoundUsernames,
            returnURL:            "/instructor"
        ))
    }

    // MARK: - POST /courses/:courseID/unenroll/:userID

    @Sendable
    func instructorUnenrollUser(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isInstructor else { throw Abort(.forbidden) }

        guard
            let courseIDString = req.parameters.get("courseID"),
            let courseID       = UUID(uuidString: courseIDString),
            let userIDString   = req.parameters.get("userID"),
            let userID         = UUID(uuidString: userIDString)
        else {
            throw Abort(.badRequest)
        }

        try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseID)
            .filter(\.$userID == userID)
            .delete()

        return req.redirect(to: "/instructor")
    }
}
