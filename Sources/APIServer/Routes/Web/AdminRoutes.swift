// APIServer/Routes/Web/AdminRoutes.swift
//
// Admin-only routes for user management.
// Assignment publishing/open/close/delete have moved to AssignmentRoutes (instructor+).
// All routes here require admin role (enforced in routes.swift).
//
//   GET  /admin                              → admin.leaf  (user management dashboard)
//   POST /admin/users/:id/role               → change a user's role
//   POST /admin/runner-secret                → set/clear runtime runner secret
//   POST /admin/courses/:courseID/copy       → duplicate course (setups + assignments, no enrolments)

import Vapor
import Fluent
import Foundation

struct AdminRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let admin = routes.grouped("admin")
        admin.get(use: dashboard)
        admin.get("runners", use: runners)
        admin.get("workers", use: workers)
        admin.post("users", ":userID", "role", use: changeRole)
        admin.post("runner-secret", use: updateWorkerSecret)
        admin.post("worker-secret", use: updateWorkerSecret)
        admin.post("runner-autostart", use: updateLocalRunnerAutoStart)
        admin.get("courses", "new", use: newCourseForm)
        admin.post("courses", use: createCourse)
        admin.get("courses", ":courseID", use: courseDetail)
        admin.post("courses", ":courseID", "edit", use: editCourse)
        admin.post("courses", ":courseID", "archive", use: toggleCourseArchive)
        admin.post("courses", ":courseID", "copy",    use: copyCourse)
        admin.post("courses", ":courseID", "enroll-csv", use: adminBulkEnrollCSV)
        admin.post("courses", ":courseID", "unenroll", ":userID", use: unenrollUserFromCourse)
        admin.get("users", ":userID", use: userDetail)
        admin.post("users", ":userID", "enroll", use: adminEnrollUser)
        admin.post("users", ":userID", "unenroll", ":courseID", use: adminUnenrollUser)
    }

    // MARK: - GET /admin

    @Sendable
    func dashboard(req: Request) async throws -> View {
        let users = try await APIUser.query(on: req.db)
            .sort(\.$createdAt)
            .all()

        let userRows = users.map { u in
            AdminUserRow(
                id:        u.id?.uuidString ?? "",
                displayName: u.displayName,
                username:  u.username,
                role:      u.role,
                createdAt: u.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—",
                lastLoginAt: u.lastLoginAt.map { ISO8601DateFormatter().string(from: $0) }
            )
        }

        let workerRows = try await makeWorkerRows(req: req)
        let effectiveSecret = await req.application.workerSecretStore.effectiveSecret() ?? ""
        let localRunnerAutoStartEnabled = await req.application.localRunnerAutoStartStore.isEnabled()

        // Course management data.
        let allCourses = try await APICourse.query(on: req.db)
            .sort(\.$createdAt)
            .all()
        let enrollmentCounts = try await enrollmentCountsByCourse(on: req.db)
        let assignmentCounts = try await assignmentCountsByCourse(on: req.db)
        let courseRows = allCourses.compactMap { course -> AdminCourseRow? in
            guard let id = course.id else { return nil }
            return AdminCourseRow(
                id: id.uuidString,
                code: course.code,
                name: course.name,
                isArchived: course.isArchived,
                openEnrollment: course.openEnrollment,
                enrollmentCount: enrollmentCounts[id] ?? 0,
                assignmentCount: assignmentCounts[id] ?? 0,
                createdAt: course.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—"
            )
        }

        let ctx = AdminContext(
            currentUser: req.currentUserContext,
            users:       userRows,
            workers:     workerRows,
            workerSecret: effectiveSecret,
            localRunnerAutoStartEnabled: localRunnerAutoStartEnabled,
            courses: courseRows
        )
        return try await req.view.render("admin", ctx)
    }

    // MARK: - GET /admin/runners

    @Sendable
    func runners(req: Request) async throws -> [AdminWorkerRow] {
        try await makeWorkerRows(req: req)
    }

    // MARK: - GET /admin/workers (compat alias)

    @Sendable
    func workers(req: Request) async throws -> [AdminWorkerRow] {
        try await makeWorkerRows(req: req)
    }

    // MARK: - POST /admin/users/:id/role

    @Sendable
    func changeRole(req: Request) async throws -> Response {
        struct RoleBody: Content { var role: String }

        guard
            let idString = req.parameters.get("userID"),
            let uuid     = UUID(uuidString: idString),
            let user     = try await APIUser.find(uuid, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let body = try req.content.decode(RoleBody.self)
        guard ["student", "instructor", "admin"].contains(body.role) else {
            throw Abort(.badRequest, reason: "Invalid role: \(body.role)")
        }

        user.role = body.role
        try await user.save(on: req.db)
        return req.redirect(to: "/admin")
    }

    // MARK: - POST /admin/runner-secret

    @Sendable
    func updateWorkerSecret(req: Request) async throws -> Response {
        struct WorkerSecretBody: Content { var secret: String }
        let body = try req.content.decode(WorkerSecretBody.self)
        let trimmed = body.secret.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            await req.application.workerSecretStore.setRuntimeOverride(nil)
            if let persisted = readWorkerSecretFromDisk(workerSecretFilePath: req.application.workerSecretFilePath) {
                await req.application.workerSecretStore.setRuntimeOverride(persisted)
                req.logger.info("Admin reset runtime runner secret to persisted value.")
            }
            req.logger.info("Admin cleared runtime runner secret override.")
        } else {
            await req.application.workerSecretStore.setRuntimeOverride(trimmed)
            writeWorkerSecretToDisk(secret: trimmed, workerSecretFilePath: req.application.workerSecretFilePath)
            req.logger.info("Admin updated runtime runner secret override.")
        }
        return req.redirect(to: "/admin")
    }

    // MARK: - POST /admin/runner-autostart

    @Sendable
    func updateLocalRunnerAutoStart(req: Request) async throws -> Response {
        struct AutoStartBody: Content {
            var localRunnerAutoStart: String?
        }

        let body = try req.content.decode(AutoStartBody.self)
        let enabled = (body.localRunnerAutoStart == "on")
        await req.application.localRunnerAutoStartStore.setEnabled(enabled)
        writeLocalRunnerAutoStartToDisk(
            enabled: enabled,
            filePath: req.application.localRunnerAutoStartFilePath
        )
        req.logger.info("Admin updated local runner autostart setting: \(enabled)")
        return req.redirect(to: "/admin")
    }

    // MARK: - GET /admin/courses/new

    @Sendable
    func newCourseForm(req: Request) async throws -> View {
        let emptyCourse = AdminCourseRow(
            id:              "",
            code:            "",
            name:            "",
            isArchived:      false,
            openEnrollment:  true,
            enrollmentCount: 0,
            assignmentCount: 0,
            createdAt:       ""
        )
        return try await req.view.render("admin-course", AdminCourseDetailContext(
            currentUser:   req.currentUserContext,
            course:        emptyCourse,
            enrolledUsers: [],
            assignments:   [],
            isNew:         true,
            error:         req.query[String.self, at: "error"]
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
            let course   = try await APICourse.find(courseID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        course.isArchived.toggle()
        try await course.save(on: req.db)
        return req.redirect(to: "/admin/courses/\(idString)")
    }

    // MARK: - POST /admin/courses/:courseID/copy

    @Sendable
    func copyCourse(req: Request) async throws -> Response {
        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let source   = try await APICourse.find(courseID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let sourceID  = try source.requireID()
        let newCode   = try await uniqueCopyCode(base: source.code, db: req.db)
        let setupsDir = req.application.testSetupsDirectory

        // Load source data before the transaction (read-only queries).
        let setups = try await APITestSetup.query(on: req.db)
            .filter(\.$courseID == sourceID)
            .all()
        let assignments = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == sourceID)
            .sort(\.$sortOrder)
            .all()

        var newCourseID = UUID()

        try await req.db.transaction { db in
            // 1. Create the new course.
            let newCourse = APICourse(code: newCode, name: "\(source.name) (Copy)")
            try await newCourse.save(on: db)
            newCourseID = try newCourse.requireID()

            // 2. Copy each test setup (zip + optional notebook) to a new ID.
            var setupIDMap: [String: String] = [:]
            for setup in setups {
                guard let oldID = setup.id else { continue }
                let newID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
                setupIDMap[oldID] = newID

                let srcZip = URL(fileURLWithPath: setupsDir + "\(oldID).zip")
                let dstZip = URL(fileURLWithPath: setupsDir + "\(newID).zip")
                try FileManager.default.copyItem(at: srcZip, to: dstZip)

                var newNotebookPath: String? = nil
                if setup.notebookPath != nil {
                    let srcNb = URL(fileURLWithPath: setupsDir + "\(oldID).ipynb")
                    if FileManager.default.fileExists(atPath: srcNb.path) {
                        let dstNb = URL(fileURLWithPath: setupsDir + "\(newID).ipynb")
                        try FileManager.default.copyItem(at: srcNb, to: dstNb)
                        newNotebookPath = dstNb.path
                    }
                }

                let newSetup = APITestSetup(
                    id:           newID,
                    manifest:     setup.manifest,
                    zipPath:      dstZip.path,
                    notebookPath: newNotebookPath,
                    courseID:     newCourseID
                )
                try await newSetup.save(on: db)
            }

            // 3. Copy each assignment, remapping to the new test setup IDs.
            //    Validation state is reset so the instructor re-validates before opening.
            for (idx, a) in assignments.enumerated() {
                guard let newSetupID = setupIDMap[a.testSetupID] else { continue }
                let newAssignment = APIAssignment(
                    testSetupID:          newSetupID,
                    title:                a.title,
                    dueAt:                a.dueAt,
                    isOpen:               false,
                    sortOrder:            a.sortOrder ?? idx,
                    validationStatus:     nil,
                    validationSubmissionID: nil,
                    courseID:             newCourseID
                )
                try await newAssignment.save(on: db)
            }
        }

        req.logger.info("Admin copied course \(source.code) → \(newCode) (new ID: \(newCourseID))")
        return req.redirect(to: "/admin/courses/\(newCourseID.uuidString)")
    }

    // MARK: - POST /admin/courses/:courseID/edit

    @Sendable
    func editCourse(req: Request) async throws -> Response {
        struct EditCourseBody: Content {
            var code: String
            var name: String
            var openEnrollment: String?   // checkbox: "on" when checked, absent when unchecked
        }

        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let course   = try await APICourse.find(courseID, on: req.db)
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

        course.code           = code
        course.name           = name
        course.openEnrollment = (body.openEnrollment == "on")
        try await course.save(on: req.db)
        return req.redirect(to: "/admin/courses/\(idString)")
    }

    // MARK: - POST /admin/courses/:courseID/unenroll/:userID

    @Sendable
    func unenrollUserFromCourse(req: Request) async throws -> Response {
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

        return req.redirect(to: "/admin/courses/\(courseIDString)")
    }

    // MARK: - GET /admin/users/:userID

    @Sendable
    func userDetail(req: Request) async throws -> View {
        guard
            let idString = req.parameters.get("userID"),
            let userID   = UUID(uuidString: idString),
            let user     = try await APIUser.find(userID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let allCourses = try await APICourse.query(on: req.db)
            .filter(\.$isArchived == false)
            .sort(\.$code)
            .all()

        let enrollments = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .with(\.$course)
            .all()

        let enrolledIDs = Set(enrollments.map { $0.$course.id })

        let enrolledRows = enrollments
            .compactMap { e -> AdminUserCourseRow? in
                guard let id = e.course.id else { return nil }
                return AdminUserCourseRow(id: id.uuidString, code: e.course.code, name: e.course.name)
            }
            .sorted { $0.code < $1.code }

        let availableRows = allCourses.compactMap { c -> AdminUserCourseRow? in
            guard let id = c.id, !enrolledIDs.contains(id) else { return nil }
            return AdminUserCourseRow(id: id.uuidString, code: c.code, name: c.name)
        }

        return try await req.view.render("admin-user", AdminUserDetailContext(
            currentUser:      req.currentUserContext,
            targetUserID:     idString,
            displayName:      user.displayName,
            username:         user.username,
            role:             user.role,
            enrolledCourses:  enrolledRows,
            availableCourses: availableRows
        ))
    }

    // MARK: - GET /admin/courses/:courseID

    @Sendable
    func courseDetail(req: Request) async throws -> View {
        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let course   = try await APICourse.find(courseID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        let enrollmentCounts = try await enrollmentCountsByCourse(on: req.db)
        let assignmentCounts = try await assignmentCountsByCourse(on: req.db)
        let courseRow = AdminCourseRow(
            id:              idString,
            code:            course.code,
            name:            course.name,
            isArchived:      course.isArchived,
            openEnrollment:  course.openEnrollment,
            enrollmentCount: enrollmentCounts[courseID] ?? 0,
            assignmentCount: assignmentCounts[courseID] ?? 0,
            createdAt:       course.createdAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—"
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
                .sort(\.$username)
                .all()
            enrolledUsers = users.compactMap { u in
                guard let uid = u.id else { return nil }
                return AdminCourseEnrolledUserRow(
                    id:          uid.uuidString,
                    username:    u.username,
                    displayName: u.displayName,
                    role:        u.role
                )
            }
        }

        // Load assignments for this course.
        let assignmentModels = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseID)
            .sort(\.$dueAt)
            .all()
        let iso = ISO8601DateFormatter()
        let assignments = assignmentModels.map { a in
            AdminCourseAssignmentRow(
                id:     a.publicID,
                title:  a.title,
                dueAt:  a.dueAt.map { iso.string(from: $0) },
                isOpen: a.isOpen
            )
        }

        return try await req.view.render("admin-course", AdminCourseDetailContext(
            currentUser:   req.currentUserContext,
            course:        courseRow,
            enrolledUsers: enrolledUsers,
            assignments:   assignments,
            isNew:         false,
            error:         nil
        ))
    }

    // MARK: - POST /admin/users/:userID/enroll

    @Sendable
    func adminEnrollUser(req: Request) async throws -> Response {
        guard
            let idString = req.parameters.get("userID"),
            let userID   = UUID(uuidString: idString),
            let _        = try await APIUser.find(userID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        struct EnrollBody: Content { var courseID: String }
        let body = try req.content.decode(EnrollBody.self)

        guard
            let courseID = UUID(uuidString: body.courseID),
            let course   = try await APICourse.find(courseID, on: req.db),
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
            let idString       = req.parameters.get("userID"),
            let userID         = UUID(uuidString: idString),
            let courseIDString = req.parameters.get("courseID"),
            let courseID       = UUID(uuidString: courseIDString)
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
            let course   = try await APICourse.find(courseID, on: req.db),
            !course.isArchived
        else {
            throw Abort(.badRequest, reason: "Invalid or archived course.")
        }

        let form = try req.content.decode(BulkEnrollForm.self)

        // Parse unique, non-empty usernames from the CSV (first column, header auto-skipped).
        let rawUsernames = parseUsernamesFromCSV(form.file)
        var seen = Set<String>()
        let uniqueUsernames = rawUsernames.filter { seen.insert($0).inserted }

        // Match against APIUser.username in-memory (simpler than a Fluent IN query).
        let usernameSet = Set(uniqueUsernames)
        let allUsers = try await APIUser.query(on: req.db).all()
        let matchedUsers = allUsers.filter { usernameSet.contains($0.username) }

        let matchedUsernameSet = Set(matchedUsers.map { $0.username })
        let notFoundUsernames = uniqueUsernames
            .filter { !matchedUsernameSet.contains($0) }
            .sorted()

        // Load existing enrollments for this course to detect already-enrolled users.
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

        return try await req.view.render("admin-enroll-csv-result", AdminEnrollCSVResultContext(
            currentUser:          req.currentUserContext,
            courseID:             idString,
            courseCode:           course.code,
            courseName:           course.name,
            enrolledCount:        enrolledCount,
            alreadyEnrolledCount: alreadyEnrolledCount,
            notFoundUsernames:    notFoundUsernames
        ))
    }

}

/// Returns a course code derived from `base` that doesn't already exist in the DB.
/// Tries `{BASE}-COPY`, then `{BASE}-COPY-2` … `{BASE}-COPY-10`.
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
    throw Abort(.conflict, reason: "Could not generate a unique course code. Rename an existing copy first.")
}

private func makeWorkerRows(req: Request) async throws -> [AdminWorkerRow] {
    let iso = ISO8601DateFormatter()
    let workers = await req.application.workerActivityStore.snapshotsSortedByRecent()
    let submissions = try await APISubmission.query(on: req.db).all()

    var assignedByWorkerID: [String: Int] = [:]
    var processedByWorkerID: [String: Int] = [:]

    for submission in submissions {
        guard let workerID = submission.workerID, !workerID.isEmpty else { continue }
        if submission.status == "assigned" {
            assignedByWorkerID[workerID, default: 0] += 1
        }
        if submission.status == "complete" || submission.status == "failed" {
            processedByWorkerID[workerID, default: 0] += 1
        }
    }

    return workers.map { snapshot in
        let assigned = assignedByWorkerID[snapshot.workerID, default: 0]
        let processed = processedByWorkerID[snapshot.workerID, default: 0]
        return AdminWorkerRow(
            workerID: snapshot.workerID,
            lastActive: iso.string(from: snapshot.lastActive),
            status: assigned > 0 ? "busy" : "idle",
            assignedJobs: assigned,
            jobsProcessed: processed
        )
    }
}

private func enrollmentCountsByCourse(on db: Database) async throws -> [UUID: Int] {
    let enrollments = try await APICourseEnrollment.query(on: db).all()
    var counts: [UUID: Int] = [:]
    for e in enrollments {
        counts[e.$course.id, default: 0] += 1
    }
    return counts
}

private func assignmentCountsByCourse(on db: Database) async throws -> [UUID: Int] {
    let assignments = try await APIAssignment.query(on: db).all()
    var counts: [UUID: Int] = [:]
    for a in assignments {
        let cid = a.courseID
        counts[cid, default: 0] += 1
    }
    return counts
}

// MARK: - View context types

private struct AdminUserRow: Encodable {
    let id: String
    let displayName: String?
    let username: String
    let role: String
    let createdAt: String
    let lastLoginAt: String?
}

struct AdminWorkerRow: Content {
    let workerID: String
    let lastActive: String
    let status: String
    let assignedJobs: Int
    let jobsProcessed: Int
}

private struct AdminCourseRow: Encodable {
    let id: String
    let code: String
    let name: String
    let isArchived: Bool
    let openEnrollment: Bool
    let enrollmentCount: Int
    let assignmentCount: Int
    let createdAt: String
}

private struct AdminContext: Encodable {
    let currentUser: CurrentUserContext?
    let users: [AdminUserRow]
    let workers: [AdminWorkerRow]
    let workerSecret: String
    let localRunnerAutoStartEnabled: Bool
    let courses: [AdminCourseRow]
}

/// Parses a flat list of usernames from a CSV upload.
/// - Takes the first column of every non-blank line.
/// - Strips surrounding quotes and whitespace.
/// - Auto-detects and skips a header row when the first column matches a known keyword.
private func parseUsernamesFromCSV(_ data: Data) -> [String] {
    guard let text = String(data: data, encoding: .utf8)
                  ?? String(data: data, encoding: .isoLatin1) else {
        return []
    }

    var lines = text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    // Skip an obvious header row.
    if let firstLine = lines.first {
        let firstCol = firstLine
            .components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            ?? ""
        let headerKeywords = ["username", "user", "login", "id", "studentid", "userid", "loginid"]
        if headerKeywords.contains(firstCol) {
            lines.removeFirst()
        }
    }

    // Extract first column, strip surrounding quotes/whitespace.
    return lines.compactMap { line -> String? in
        let col = line
            .components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard let col, !col.isEmpty else { return nil }
        return col
    }
}

private struct AdminUserDetailContext: Encodable {
    let currentUser: CurrentUserContext?
    let targetUserID: String
    let displayName: String?
    let username: String
    let role: String
    let enrolledCourses: [AdminUserCourseRow]
    let availableCourses: [AdminUserCourseRow]
}

private struct AdminUserCourseRow: Encodable {
    let id: String
    let code: String
    let name: String
}

private struct AdminEnrollCSVResultContext: Encodable {
    let currentUser: CurrentUserContext?
    let courseID: String
    let courseCode: String
    let courseName: String
    let enrolledCount: Int
    let alreadyEnrolledCount: Int
    let notFoundUsernames: [String]
    // Precomputed for easy Leaf truthiness check.
    var hasNotFound: Bool { !notFoundUsernames.isEmpty }
    var notFoundCount: Int { notFoundUsernames.count }
}

private struct AdminCourseDetailContext: Encodable {
    let currentUser: CurrentUserContext?
    let course: AdminCourseRow
    let enrolledUsers: [AdminCourseEnrolledUserRow]
    let assignments: [AdminCourseAssignmentRow]
    let isNew: Bool
    let error: String?
    var assignmentCount: Int { assignments.count }
}

private struct AdminCourseEnrolledUserRow: Encodable {
    let id: String
    let username: String
    let displayName: String?
    let role: String
}

private struct AdminCourseAssignmentRow: Encodable {
    let id: String      // publicID — used in /assignments/:id/... URLs
    let title: String
    let dueAt: String?
    let isOpen: Bool
}
