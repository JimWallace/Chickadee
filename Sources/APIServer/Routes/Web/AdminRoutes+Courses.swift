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
            submissionCount: 0,
            createdAt: "",
            brightspaceOrgUnitID: nil,
            brightspaceOrgUnitName: nil,
            brightspaceSyncEnabled: req.application.brightSpaceAppCredentials != nil
        )
        return try await req.view.render(
            "admin-course",
            AdminCourseDetailContext(
                currentUser: req.currentUserContext,
                course: emptyCourse,
                enrolledUsers: [],
                assignments: [],
                isNew: true,
                courseForm: CourseFieldsContext(
                    idPrefix: "new-course", code: "", name: "", term: nil,
                    error: CourseFormError.message(forQuery: req.query[String.self, at: "error"]),
                    autofocus: true)
            ))
    }

    // MARK: - POST /admin/courses

    @Sendable
    func createCourse(req: Request) async throws -> Response {
        struct CourseBody: Content {
            var code: String
            var name: String
            var termYear: String?
            var termSeason: String?
        }
        let body = try req.content.decode(CourseBody.self)
        let code = body.code.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !name.isEmpty else {
            return req.redirect(to: "/admin/courses/new?error=\(CourseFormError.fields.rawValue)")
        }
        // A new course declares its term (docs/course-terms.md). Nothing
        // guesses one, and the form starts empty.
        guard case .term(let term) = CourseTermInput(year: body.termYear, season: body.termSeason) else {
            return req.redirect(to: "/admin/courses/new?error=\(CourseFormError.term.rawValue)")
        }
        if try await activeCourseCodeIsTaken(code, term: term, excluding: nil, on: req.db) {
            return req.redirect(to: "/admin/courses/new?error=\(CourseFormError.codeTaken.rawValue)")
        }
        let course = APICourse(code: code, name: name, term: term)
        try await course.save(on: req.db)
        let id = try course.requireID().uuidString
        await AuditLogger.record(
            action: .courseCreated,
            targetType: .course,
            targetID: id,
            metadata: ["course_code": code, "course_name": name, "course_term": term.displayName],
            on: req
        )
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
        // Un-archiving re-enters the unique index over active courses. An
        // archived course may share a code and term with an active one (a
        // bundle import creates one beside it by design), so check the rule
        // the index enforces and report a duplicate instead of failing on it
        // (#1777), exactly as the edit route does.
        if course.isArchived,
            try await activeCourseCodeIsTaken(course.code, term: course.term, excluding: courseID, on: req.db)
        {
            return req.redirect(to: "/admin/courses/\(idString)?error=\(CourseFormError.codeTaken.rawValue)")
        }
        course.isArchived.toggle()
        // Archiving is Chickadee's "end of term" signal: stamp the moment so
        // the submission-retention clock has an anchor (see
        // SubmissionRetentionService). Un-archiving clears it so a course that
        // re-opens isn't carrying a stale retention deadline.
        course.archivedAt = course.isArchived ? Date() : nil
        try await course.save(on: req.db)
        await AuditLogger.record(
            action: course.isArchived ? .courseArchived : .courseUnarchived,
            targetType: .course,
            targetID: idString,
            metadata: ["course_code": course.code],
            on: req
        )
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

    /// One-click copy into the same term under a free `-COPY` code (a sandbox
    /// or a second section). The clone form below is the new-term door; both
    /// run `CourseCloneService`.
    @Sendable
    func copyCourse(req: Request) async throws -> Response {
        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let source = try await APICourse.find(courseID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        let newCode = try await uniqueCopyCode(base: source.code, db: req.db)
        let result = try await cloneCourse(
            source, code: newCode, name: "\(source.name) (Copy)", term: source.term, req: req)
        return req.redirect(to: "/admin/courses/\(try result.course.requireID().uuidString)")
    }

    // MARK: - POST /admin/courses/:courseID/clone

    /// "Clone for a new term": the admin names the new offering's code, name
    /// and term (docs/course-terms.md slice 4). The code may be the source's
    /// own, since codes are unique per term.
    @Sendable
    func cloneCourseForNewTerm(req: Request) async throws -> Response {
        struct CloneBody: Content {
            var code: String
            var name: String
            var termYear: String?
            var termSeason: String?
        }
        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let source = try await APICourse.find(courseID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        let body = try req.content.decode(CloneBody.self)
        let code = body.code.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let back = "/admin/courses/\(idString)"
        guard !code.isEmpty, !name.isEmpty else {
            return req.redirect(to: "\(back)?error=\(CourseCloneFormError.fields.rawValue)#clone-course")
        }
        guard case .term(let term) = CourseTermInput(year: body.termYear, season: body.termSeason) else {
            return req.redirect(to: "\(back)?error=\(CourseCloneFormError.term.rawValue)#clone-course")
        }
        if try await activeCourseCodeIsTaken(code, term: term, excluding: nil, on: req.db) {
            return req.redirect(to: "\(back)?error=\(CourseCloneFormError.codeTaken.rawValue)#clone-course")
        }
        let result = try await cloneCourse(source, code: code, name: name, term: term, req: req)
        return req.redirect(to: "/admin/courses/\(try result.course.requireID().uuidString)")
    }

    /// Runs the clone in one transaction and records it.
    private func cloneCourse(
        _ source: APICourse, code: String, name: String, term: AcademicTerm?, req: Request
    ) async throws -> CourseCloneResult {
        let directories = AuthoringDirectories(
            setups: req.application.testSetupsDirectory,
            submissions: req.application.submissionsDirectory)
        let contentFilesDirectory = req.application.contentFilesDirectory
        let result = try await req.db.transaction { db in
            try await CourseCloneService.clone(
                source: source, target: CourseCloneTarget(code: code, name: name, term: term),
                directories: directories, contentFilesDirectory: contentFilesDirectory, on: db)
        }
        let newID = try result.course.requireID().uuidString
        var metadata = [
            "source_course_code": source.code,
            "course_code": code,
            "course_name": name,
            "assignments": String(result.assignmentCount),
        ]
        metadata["course_term"] = term?.displayName
        await AuditLogger.record(
            action: .courseCloned, targetType: .course, targetID: newID, metadata: metadata, on: req)
        req.logger.info("Admin cloned course \(source.urlKey) → \(result.course.urlKey) (new ID: \(newID))")
        return result
    }

    // MARK: - POST /admin/courses/:courseID/delete

    @Sendable
    func deleteCourse(req: Request) async throws -> Response {
        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let course = try await APICourse.find(courseID, on: req.db)
        else { throw Abort(.notFound) }

        // Deletion is gated on the same retention window as Purge: a course
        // can only be deleted from the Retention tab once it has been archived
        // and its retention window has elapsed. Never trust the posting page.
        let retentionDays = req.application.appConfig.diagnostics.submissionRetentionDays
        guard course.isArchived, let archivedAt = course.archivedAt else {
            return req.redirect(
                to: retentionRedirect(error: "\(course.code) is not archived — cannot delete."))
        }
        let eligibleAt = SubmissionRetentionService.purgeEligibleDate(
            archivedAt: archivedAt, retentionDays: retentionDays)
        guard Date() >= eligibleAt else {
            return req.redirect(
                to: retentionRedirect(
                    error: "\(course.code) is not yet past its retention window."))
        }

        let setupsDir = req.application.testSetupsDirectory

        let purgedSubmissions = try await req.db.transaction { db -> Int in
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

            // 3. Delete submission zip files then submission records (variant
            // batches first — their FK is `.setNull`, so the other order
            // leaves unlinked rows for setups that no longer exist).
            for sub in submissions {
                try? FileManager.default.removeItem(atPath: sub.zipPath)
            }
            if !setupIDs.isEmpty {
                try await ValidationVariant.query(on: db)
                    .filter(\.$testSetupID ~~ setupIDs).delete()
                // The corpus runs go with the submissions they name. They are
                // the one class-level table holding WHO contributed rather than
                // only what was graded, which is why deletion reaches them
                // explicitly (docs/collaborative-class-assignments.md, Phase 4).
                try await APIClassCoverageRun.query(on: db)
                    .filter(\.$testSetupID ~~ setupIDs).delete()
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
            return submissions.count
        }

        // The course's version rows cascaded away with it, so their blobs now
        // have nothing pointing at them. This is the only moment version
        // history is ever removed, and therefore the only moment blobs become
        // reclaimable.
        await AssignmentVersionStore.reclaimOrphanedBlobs(
            testSetupsDirectory: setupsDir, logger: req.logger, on: req.db)

        req.logger.info("Admin permanently deleted course \(course.code) (\(idString))")
        await AuditLogger.record(
            action: .courseDeleted,
            targetType: .course,
            targetID: idString,
            metadata: ["course_code": course.code, "submissions_purged": String(purgedSubmissions)],
            on: req
        )
        // The one place student submissions are purged under the retention
        // policy — record it distinctly when anything was actually removed.
        if purgedSubmissions > 0 {
            await AuditLogger.record(
                action: .submissionsPurged,
                targetType: .course,
                targetID: idString,
                metadata: ["course_code": course.code, "count": String(purgedSubmissions)],
                on: req
            )
        }
        return req.redirect(
            to: retentionRedirect(ok: "Deleted \(course.code) and all its data."))
    }

    // MARK: - POST /admin/courses/:courseID/edit

    @Sendable
    func editCourse(req: Request) async throws -> Response {
        struct EditCourseBody: Content {
            var code: String
            var name: String
            var brightspaceOrgUnitID: String?
            var termYear: String?
            var termSeason: String?
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

        // The term fields set or change the term. A post without them (an
        // older client) leaves the term as it is; a post with an invalid pair
        // changes nothing.
        let term: AcademicTerm?
        switch CourseTermInput(year: body.termYear, season: body.termSeason) {
        case .absent: term = course.term
        case .term(let posted): term = posted
        case .invalid: return req.redirect(to: "/admin/courses/\(idString)?error=\(CourseFormError.term.rawValue)")
        }

        // Reject a duplicate of another active course in the same term — the
        // rule of the unique index (docs/course-terms.md). An archived course
        // is outside the index, so it may share a code.
        if !course.isArchived,
            try await activeCourseCodeIsTaken(code, term: term, excluding: courseID, on: req.db)
        {
            return req.redirect(to: "/admin/courses/\(idString)?error=\(CourseFormError.codeTaken.rawValue)")
        }

        course.term = term
        course.code = code
        course.name = name
        if let client = req.application.brightSpaceClient {
            let rawOrgUnit = (body.brightspaceOrgUnitID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let newOrgUnit = rawOrgUnit.isEmpty ? nil : rawOrgUnit
            course.brightspaceOrgUnitID = newOrgUnit
            // Verify the binding against D2L and cache the org-unit name so the
            // admin can confirm they pointed at the right course. Verification
            // failures (D2L unreachable, bad ID) don't block the save — the
            // name just stays nil and the UI shows "unverified".
            if let orgUnit = newOrgUnit {
                course.brightspaceOrgUnitName = await verifiedOrgUnitName(
                    orgUnitID: orgUnit, client: client, req: req)
            } else {
                course.brightspaceOrgUnitName = nil
            }
        }
        try await course.save(on: req.db)
        return req.redirect(to: "/admin/courses/\(idString)")
    }

    /// Looks the org unit up in D2L and returns its name, or nil if it can't
    /// be verified (not found, or D2L unreachable). Never throws — a failed
    /// verification must not block saving the course.
    private func verifiedOrgUnitName(
        orgUnitID: String, client: BrightSpaceAPIClient, req: Request
    ) async -> String? {
        do {
            return try await client.getOrgUnit(orgUnitID: orgUnitID, on: req.application)?.name
        } catch {
            req.logger.warning("BrightSpace org-unit verification failed for \(orgUnitID): \(error)")
            return nil
        }
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

        await AuditLogger.record(
            action: .enrollmentRemoved,
            targetType: .enrollment,
            targetID: userIDString,
            metadata: ["course_id": courseIDString, "subject_user_id": userIDString],
            on: req
        )
        return req.redirect(to: "/admin/courses/\(courseIDString)")
    }

    // MARK: - POST /admin/courses/:courseID/role/:userID
    //
    // Sets a roster member's per-course role from the admin course page —
    // the admin-side counterpart of the instructor roster dropdown (#417
    // Slice B), so an admin can assign a course's instructors/TAs without
    // first making the course their active one. Admin-only (admin route
    // group); admins are exempt from the last-instructor guard since they
    // can always re-grant.
    @Sendable
    func adminSetEnrollmentRole(req: Request) async throws -> Response {
        guard
            let courseIDString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: courseIDString),
            let userIDString = req.parameters.get("userID"),
            let userID = UUID(uuidString: userIDString)
        else {
            throw Abort(.badRequest)
        }

        struct Body: Content { var role: String? }
        let body = try? req.content.decode(Body.self)
        guard let newRole = CourseRole(rawValue: body?.role ?? "") else {
            throw Abort(.badRequest, reason: "Unknown per-course role.")
        }

        guard
            let enrollment = try await APICourseEnrollment.query(on: req.db)
                .filter(\.$course.$id == courseID)
                .filter(\.$userID == userID)
                .first()
        else {
            throw Abort(.notFound)
        }
        enrollment.role = newRole
        try await enrollment.save(on: req.db)

        await AuditLogger.record(
            action: .enrollmentRoleChanged,
            targetType: .enrollment,
            targetID: userIDString,
            metadata: [
                "course_id": courseIDString, "subject_user_id": userIDString, "role": newRole.rawValue,
            ],
            on: req
        )
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

        let courseRow = try await Self.courseDetailRow(
            for: course, id: idString, courseID: courseID,
            brightspaceSyncEnabled: req.application.brightSpaceAppCredentials != nil, on: req.db)
        let enrollments = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseID)
            .all()
        let enrolledUsers = try await Self.enrolledUserRows(for: enrollments, on: req.db)
        let assignments = try await Self.assignmentRows(forCourse: courseID, on: req.db)

        // One `error` query serves the settings and clone forms; each form
        // shows only the codes it owns.
        let errorCode = req.query[String.self, at: "error"]

        return try await req.view.render(
            "admin-course",
            AdminCourseDetailContext(
                currentUser: req.currentUserContext,
                course: courseRow,
                enrolledUsers: enrolledUsers,
                assignments: assignments,
                isNew: false,
                courseForm: CourseFieldsContext(
                    idPrefix: "course-settings", code: course.code, name: course.name, term: course.term,
                    error: CourseFormError.message(forQuery: errorCode)),
                // The clone defaults to the term after this course's, when it
                // has one (docs/course-terms.md slice 4): derived from the
                // course, never from today's date.
                cloneForm: CourseFieldsContext(
                    idPrefix: "clone", code: course.code, name: course.name, term: course.term?.next,
                    error: CourseCloneFormError.message(forQuery: errorCode))
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

        try await ensureSeededEnrollment(userID: userID, courseID: courseID, on: req.db)

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

        await AuditLogger.record(
            action: .enrollmentRemoved,
            targetType: .enrollment,
            targetID: idString,
            metadata: ["course_id": courseIDString, "subject_user_id": idString],
            on: req
        )
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

        await AuditLogger.record(
            action: .enrollmentBulkAdded,
            targetType: .course,
            targetID: idString,
            metadata: [
                "course_code": course.code,
                "enrolled": String(result.enrolledCount),
                "pre_enrolled": String(result.preEnrolledCount),
                "already_enrolled": String(result.alreadyEnrolledCount),
            ],
            on: req
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
    let candidates = ["\(base)-COPY"] + (2...10).map { "\(base)-COPY-\($0)" }
    let taken = Set(
        try await APICourse.query(on: db)
            .filter(\.$code ~~ candidates)
            .all()
            .map(\.code))
    if let available = candidates.first(where: { !taken.contains($0) }) {
        return available
    }
    throw AppError.conflict(reason: "Could not generate a unique course code. Rename an existing copy first.")
}
