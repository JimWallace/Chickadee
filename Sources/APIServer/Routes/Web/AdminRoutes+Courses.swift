// APIServer/Routes/Web/AdminRoutes+Courses.swift
//
// Admin course management: create, edit, archive, delete, copy, and enrollment.
// All routes are registered in AdminRoutes.boot().

import Core
import Fluent
import Foundation
import Vapor

extension AdminRoutes {
    // MARK: - GET /admin/courses/new

    @Sendable
    func newCourseForm(req: Request) async throws -> View {
        let emptyCourse = AdminCourseRow(
            id: "",
            code: "",
            name: "",
            isArchived: false,
            enrollmentMode: CourseEnrollmentMode.open.rawValue,
            enrollmentCount: 0,
            assignmentCount: 0,
            createdAt: "",
            brightspaceOrgUnitID: nil,
            brightspaceSyncEnabled: req.application.brightSpaceClient != nil
        )
        return try await req.view.render(
            "admin-course",
            AdminCourseDetailContext(
                currentUser: req.currentUserContext,
                course: emptyCourse,
                enrolledUsers: [],
                assignments: [],
                isNew: true,
                error: req.query[String.self, at: "error"]
            ))
    }

    // MARK: - POST /admin/courses

    @Sendable
    func createCourse(req: Request) async throws -> Response {
        struct CourseBody: Content {
            var code: String
            var name: String
        }
        let body = try req.content.decode(CourseBody.self)
        let code = body.code.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !name.isEmpty else {
            return req.redirect(to: "/admin/courses/new?error=course_fields_required")
        }
        let course = APICourse(code: code, name: name)
        try await course.save(on: req.db)
        let id = try course.requireID().uuidString
        return req.redirect(to: "/admin/courses/\(id)")
    }

    // MARK: - POST /admin/courses/:courseID/archive

    @Sendable
    func toggleCourseArchive(req: Request) async throws -> Response {
        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let course = try await APICourse.find(courseID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        course.isArchived.toggle()
        try await course.save(on: req.db)
        return req.redirect(to: "/admin/courses/\(idString)")
    }

    // MARK: - POST /admin/courses/:courseID/enrollment-mode

    @Sendable
    func setEnrollmentMode(req: Request) async throws -> Response {
        struct Body: Content { var enrollmentMode: String? }
        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let course = try await APICourse.find(courseID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        let body = try? req.content.decode(Body.self)
        course.enrollmentMode = CourseEnrollmentMode(rawValue: body?.enrollmentMode ?? "") ?? .open
        try await course.save(on: req.db)
        return req.redirect(to: "/admin/courses/\(idString)")
    }

    // MARK: - POST /admin/courses/:courseID/copy

    @Sendable
    func copyCourse(req: Request) async throws -> Response {
        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let source = try await APICourse.find(courseID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let sourceID = try source.requireID()
        let newCode = try await uniqueCopyCode(base: source.code, db: req.db)
        let setupsDir = req.application.testSetupsDirectory

        // Load source data before the transaction (read-only queries).
        let setups = try await APITestSetup.query(on: req.db)
            .filter(\.$courseID == sourceID)
            .all()
        let assignments = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == sourceID)
            .sort(\.$sortOrder)
            .all()

        let newCourseID = try await req.db.transaction { db -> UUID in
            // 1. Create the new course.
            let newCourse = APICourse(code: newCode, name: "\(source.name) (Copy)")
            try await newCourse.save(on: db)
            let newCourseID = try newCourse.requireID()

            // 2. Copy each test setup (zip + optional notebook) to a new ID.
            var setupIDMap: [String: String] = [:]
            for setup in setups {
                guard let oldID = setup.id else { continue }
                let newID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
                setupIDMap[oldID] = newID

                let srcZip = URL(fileURLWithPath: setupsDir + "\(oldID).zip")
                let dstZip = URL(fileURLWithPath: setupsDir + "\(newID).zip")
                try FileManager.default.copyItem(at: srcZip, to: dstZip)

                var newNotebookPath: String?
                if setup.notebookPath != nil {
                    let srcNb = URL(fileURLWithPath: setupsDir + "\(oldID).ipynb")
                    if FileManager.default.fileExists(atPath: srcNb.path) {
                        let dstNb = URL(fileURLWithPath: setupsDir + "\(newID).ipynb")
                        try FileManager.default.copyItem(at: srcNb, to: dstNb)
                        newNotebookPath = dstNb.path
                    }
                }

                let newSetup = APITestSetup(
                    id: newID,
                    manifest: setup.manifest,
                    zipPath: dstZip.path,
                    notebookPath: newNotebookPath,
                    courseID: newCourseID
                )
                try await newSetup.save(on: db)
            }

            // 3. Copy each assignment, remapping to the new test setup IDs.
            //    Validation state is reset so the instructor re-validates before opening.
            for (idx, a) in assignments.enumerated() {
                guard let newSetupID = setupIDMap[a.testSetupID] else { continue }
                let newAssignment = APIAssignment(
                    testSetupID: newSetupID,
                    title: a.title,
                    slug: try await uniqueAssignmentSlug(title: a.title, courseID: newCourseID, db: db),
                    dueAt: a.dueAt,
                    isOpen: false,
                    sortOrder: a.sortOrder ?? idx,
                    validationStatus: nil,
                    validationSubmissionID: nil,
                    courseID: newCourseID
                )
                try await newAssignment.save(on: db)
            }

            return newCourseID
        }

        req.logger.info("Admin copied course \(source.code) → \(newCode) (new ID: \(newCourseID))")
        return req.redirect(to: "/admin/courses/\(newCourseID.uuidString)")
    }

    // MARK: - POST /admin/courses/:courseID/delete

    @Sendable
    func deleteCourse(req: Request) async throws -> Response {
        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let course = try await APICourse.find(courseID, on: req.db)
        else { throw Abort(.notFound) }
        guard course.isArchived else {
            throw AppError.badRequest(reason: "Only archived courses can be deleted.")
        }

        let setupsDir = req.application.testSetupsDirectory

        try await req.db.transaction { db in
            // 1. Test setups for this course.
            let setups = try await APITestSetup.query(on: db)
                .filter(\.$courseID == courseID).all()
            let setupIDs = setups.compactMap { $0.id }

            // 2. Submissions → results → delete.
            let submissions = try await APISubmission.query(on: db)
                .filter(\.$testSetupID ~~ setupIDs).all()
            let subIDs = submissions.compactMap { $0.id }
            if !subIDs.isEmpty {
                try await APIResult.query(on: db)
                    .filter(\.$submissionID ~~ subIDs).delete()
            }

            // 3. Delete submission zip files then submission records.
            for sub in submissions {
                try? FileManager.default.removeItem(atPath: sub.zipPath)
            }
            if !setupIDs.isEmpty {
                try await APISubmission.query(on: db)
                    .filter(\.$testSetupID ~~ setupIDs).delete()
            }

            // 4. Assignments.
            try await APIAssignment.query(on: db)
                .filter(\.$courseID == courseID).delete()

            // 5. Test setup files then setup records.
            for setup in setups {
                guard let sid = setup.id else { continue }
                try? FileManager.default.removeItem(atPath: setupsDir + "\(sid).zip")
                try? FileManager.default.removeItem(atPath: setupsDir + "\(sid).ipynb")
            }
            try await APITestSetup.query(on: db)
                .filter(\.$courseID == courseID).delete()

            // 6. Enrollments then course record.
            try await APICourseEnrollment.query(on: db)
                .filter(\.$course.$id == courseID).delete()
            try await course.delete(on: db)
        }

        req.logger.info("Admin permanently deleted course \(course.code) (\(idString))")
        return req.redirect(to: "/admin")
    }

    // MARK: - POST /admin/courses/:courseID/edit

    @Sendable
    func editCourse(req: Request) async throws -> Response {
        struct EditCourseBody: Content {
            var code: String
            var name: String
            var brightspaceOrgUnitID: String?
        }

        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let course = try await APICourse.find(courseID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let body = try req.content.decode(EditCourseBody.self)
        let rawCode = body.code.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fall back to the existing value if the field was submitted blank.
        let code = rawCode.isEmpty ? course.code : rawCode
        let name = rawName.isEmpty ? course.name : rawName

        // Reject duplicate code (excluding this course itself).
        let existing = try await APICourse.query(on: req.db)
            .filter(\.$code == code)
            .first()
        if let existing, existing.id != courseID {
            return req.redirect(to: "/admin/courses/\(idString)?error=code_taken")
        }

        course.code = code
        course.name = name
        if req.application.brightSpaceClient != nil {
            let rawOrgUnit = (body.brightspaceOrgUnitID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            course.brightspaceOrgUnitID = rawOrgUnit.isEmpty ? nil : rawOrgUnit
        }
        try await course.save(on: req.db)
        return req.redirect(to: "/admin/courses/\(idString)")
    }

    // MARK: - POST /admin/courses/:courseID/unenroll/:userID

    @Sendable
    func unenrollUserFromCourse(req: Request) async throws -> Response {
        guard
            let courseIDString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: courseIDString),
            let userIDString = req.parameters.get("userID"),
            let userID = UUID(uuidString: userIDString)
        else {
            throw Abort(.badRequest)
        }

        try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseID)
            .filter(\.$userID == userID)
            .delete()

        return req.redirect(to: "/admin/courses/\(courseIDString)")
    }

    // MARK: - GET /admin/courses/:courseID

    @Sendable
    func courseDetail(req: Request) async throws -> View {
        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let course = try await APICourse.find(courseID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        async let enrollmentCountFetch = enrolledStudentCount(forCourse: courseID, on: req.db)
        async let assignmentCountFetch = APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseID)
            .count()
        let courseRow = AdminCourseRow(
            id: idString,
            code: course.code,
            name: course.name,
            isArchived: course.isArchived,
            enrollmentMode: course.enrollmentMode.rawValue,
            enrollmentCount: try await enrollmentCountFetch,
            assignmentCount: try await assignmentCountFetch,
            createdAt: course.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—",
            brightspaceOrgUnitID: course.brightspaceOrgUnitID,
            brightspaceSyncEnabled: req.application.brightSpaceClient != nil
        )

        // Load enrollments for this course, then fetch the corresponding users.
        let enrollments = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseID)
            .all()

        let enrolledUserIDs = enrollments.map { $0.userID }
        let enrolledUsers: [AdminCourseEnrolledUserRow]
        if enrolledUserIDs.isEmpty {
            enrolledUsers = []
        } else {
            let users = try await APIUser.query(on: req.db)
                .filter(\.$id ~~ enrolledUserIDs)
                // Exclude `mcp` service accounts: enrolled to scope an agent's
                // access (admin MCP tab), not human roster members.
                .filter(\.$role != "mcp")
                .sort(\.$username)
                .all()
            enrolledUsers = users.compactMap { u in
                guard let uid = u.id else { return nil }
                return AdminCourseEnrolledUserRow(
                    id: uid.uuidString,
                    username: u.username,
                    displayName: u.displayName,
                    role: u.role
                )
            }
        }

        // Load assignments for this course.
        let assignmentModels = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseID)
            .sort(\.$dueAt)
            .all()
        let df = waterlooDateTimeFormatter()
        let assignments = assignmentModels.map { a in
            AdminCourseAssignmentRow(
                id: a.publicID,
                title: a.title,
                dueAt: a.dueAt.map { df.string(from: $0) },
                isOpen: a.isOpen
            )
        }

        return try await req.view.render(
            "admin-course",
            AdminCourseDetailContext(
                currentUser: req.currentUserContext,
                course: courseRow,
                enrolledUsers: enrolledUsers,
                assignments: assignments,
                isNew: false,
                error: nil
            ))
    }

    // MARK: - POST /admin/users/:userID/enroll

    @Sendable
    func adminEnrollUser(req: Request) async throws -> Response {
        guard
            let idString = req.parameters.get("userID"),
            let userID = UUID(uuidString: idString),
            try await APIUser.find(userID, on: req.db) != nil
        else {
            throw Abort(.notFound)
        }

        struct EnrollBody: Content { var courseID: String }
        let body = try req.content.decode(EnrollBody.self)

        guard
            let courseID = UUID(uuidString: body.courseID),
            let course = try await APICourse.find(courseID, on: req.db),
            !course.isArchived
        else {
            return req.redirect(to: "/admin/users/\(idString)?error=invalid_course")
        }

        let existing = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .count()

        if existing == 0 {
            let enrollment = APICourseEnrollment(userID: userID, courseID: courseID)
            try await enrollment.save(on: req.db)
        }

        return req.redirect(to: "/admin/users/\(idString)")
    }

    // MARK: - POST /admin/users/:userID/unenroll/:courseID

    @Sendable
    func adminUnenrollUser(req: Request) async throws -> Response {
        guard
            let idString = req.parameters.get("userID"),
            let userID = UUID(uuidString: idString),
            let courseIDString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: courseIDString)
        else {
            throw Abort(.badRequest)
        }

        try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .delete()

        return req.redirect(to: "/admin/users/\(idString)")
    }

    // MARK: - POST /admin/courses/:courseID/enroll-csv

    @Sendable
    func adminBulkEnrollCSV(req: Request) async throws -> View {
        struct BulkEnrollForm: Content {
            var file: Data
        }

        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let course = try await APICourse.find(courseID, on: req.db),
            !course.isArchived
        else {
            throw AppError.badRequest(reason: "Invalid or archived course.")
        }

        let form = try req.content.decode(BulkEnrollForm.self)

        let rawUsernames = parseUsernamesFromCSV(form.file)
        let result = try await enrollUsernamesInCourse(
            rawUsernames,
            courseID: courseID,
            on: req.db
        )

        return try await req.view.render(
            "admin-enroll-csv-result",
            EnrollCSVResultContext(
                currentUser: req.currentUserContext,
                courseCode: course.code,
                courseName: course.name,
                enrolledCount: result.enrolledCount,
                preEnrolledCount: result.preEnrolledCount,
                alreadyEnrolledCount: result.alreadyEnrolledCount,
                rejectedUsernames: result.rejectedUsernames,
                returnURL: "/admin/courses/\(idString)"
            ))
    }

}

// MARK: - Private helpers

private func uniqueCopyCode(base: String, db: Database) async throws -> String {
    let first = "\(base)-COPY"
    if try await APICourse.query(on: db).filter(\.$code == first).count() == 0 {
        return first
    }
    for n in 2...10 {
        let candidate = "\(base)-COPY-\(n)"
        if try await APICourse.query(on: db).filter(\.$code == candidate).count() == 0 {
            return candidate
        }
    }
    throw AppError.conflict(reason: "Could not generate a unique course code. Rename an existing copy first.")
}
