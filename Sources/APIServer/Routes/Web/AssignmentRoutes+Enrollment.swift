// APIServer/Routes/Web/AssignmentRoutes+Enrollment.swift
//
// Enrollment-related handlers for AssignmentRoutes.
// Extracted from AssignmentRoutes.swift — no behaviour changes.

import Vapor
import Fluent

extension AssignmentRoutes {

    // MARK: - POST /courses/:courseID/open-enrollment

    @Sendable
    func toggleCourseOpenEnrollment(req: Request) async throws -> Response {
        struct Body: Content { var openEnrollment: String? }
        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let course   = try await APICourse.find(courseID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        // An unchecked checkbox sends no field at all (empty body); treat that as false.
        let body = try? req.content.decode(Body.self)
        course.openEnrollment = (body?.openEnrollment == "on")
        try await course.save(on: req.db)
        return req.redirect(to: "/assignments")
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
            returnURL:            "/assignments"
        ))
    }
}
