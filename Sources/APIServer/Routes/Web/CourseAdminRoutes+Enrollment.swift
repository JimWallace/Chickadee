// APIServer/Routes/Web/CourseAdminRoutes+Enrollment.swift
//
// Enrollment-related handlers.  Phase 2 of the audit refactor moved them
// from `AssignmentRoutes` onto `CourseAdminRoutes`; the file name still
// starts with `AssignmentRoutes+` for blame continuity until the next
// rename pass.

import Core
import Fluent
import Vapor

extension CourseAdminRoutes {
    // MARK: - GET /instructor/enroll-csv

    @Sendable
    func enrollCSVForm(req: Request) async throws -> View {
        let caller = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: caller)
        guard let courseContext = courseState.active,
            let courseID = courseState.activeCourseUUID,
            let course = try await APICourse.find(courseID, on: req.db),
            !course.isArchived
        else {
            throw WebAssignmentError.noActiveCourse(action: "managing enrollments")
        }

        return try await req.view.render(
            "instructor-enroll-csv",
            EnrollCSVFormContext(
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
            let course = try await APICourse.find(courseID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Course")
        }
        let caller = try req.auth.require(APIUser.self)
        try await requireCourseInstructor(caller: caller, courseID: courseID, db: req.db)
        let body = try? req.content.decode(Body.self)
        course.enrollmentMode = CourseEnrollmentMode(rawValue: body?.enrollmentMode ?? "") ?? .open
        try await course.save(on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /courses/:courseID/enroll-csv

    @Sendable
    func instructorBulkEnrollCSV(req: Request) async throws -> View {
        // Both inputs are optional: the instructor can upload a CSV, type
        // user IDs into the textarea, or both.  Usernames from both sources
        // are merged (and deduplicated by `enrollUsernamesInCourse`).
        struct BulkEnrollForm: Content {
            var file: Data?
            var usernames: String?
        }

        guard
            let idString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: idString),
            let course = try await APICourse.find(courseID, on: req.db),
            !course.isArchived
        else {
            throw WebAssignmentError.invalidParameter(name: "courseID", reason: "Invalid or archived course.")
        }

        let caller = try req.auth.require(APIUser.self)
        try await requireCourseInstructor(caller: caller, courseID: courseID, db: req.db)

        let form = try req.content.decode(BulkEnrollForm.self)

        var rawUsernames: [String] = []
        if let file = form.file, !file.isEmpty {
            rawUsernames += parseUsernamesFromCSV(file)
        }
        if let typed = form.usernames {
            rawUsernames += parseUsernamesFromText(typed)
        }

        guard !rawUsernames.isEmpty else {
            return try await req.view.render(
                "instructor-enroll-csv",
                EnrollCSVFormContext(
                    currentUser: req.currentUserContext,
                    courseID: idString,
                    courseCode: course.code,
                    courseName: course.name,
                    error: "Upload a CSV file or type at least one user ID to enrol."
                ))
        }

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
                returnURL: "/instructor"
            ))
    }

    // MARK: - POST /courses/:courseID/unenroll/:userID

    @Sendable
    func instructorUnenrollUser(req: Request) async throws -> Response {
        guard
            let courseIDString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: courseIDString),
            let userIDString = req.parameters.get("userID"),
            let userID = UUID(uuidString: userIDString)
        else {
            throw WebAssignmentError.invalidParameter(
                name: "courseID/userID", reason: "Invalid courseID or userID parameter")
        }

        let caller = try req.auth.require(APIUser.self)
        try await requireCourseInstructor(caller: caller, courseID: courseID, db: req.db)

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
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /courses/:courseID/pre-unenroll/:preEnrollmentID
    //
    // Cancels a pending pre-enrollment (instructor bulk-uploaded the
    // username via CSV, the student hasn't logged in yet so there's no
    // APICourseEnrollment row yet).  Mirrors the regular unenroll
    // endpoint but operates on the `pre_enrollments` table.  Same
    // instructor-only authz; same redirect on success.

    @Sendable
    func instructorCancelPreEnrollment(req: Request) async throws -> Response {
        guard
            let courseIDString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: courseIDString),
            let preIDString = req.parameters.get("preEnrollmentID"),
            let preID = UUID(uuidString: preIDString)
        else {
            throw WebAssignmentError.invalidParameter(
                name: "courseID/preEnrollmentID", reason: "Invalid courseID or preEnrollmentID parameter")
        }

        let caller = try req.auth.require(APIUser.self)
        try await requireCourseInstructor(caller: caller, courseID: courseID, db: req.db)

        try await APIPreEnrollment.query(on: req.db)
            .filter(\.$id == preID)
            .filter(\.$course.$id == courseID)
            .delete()

        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /courses/:courseID/role/:userID
    //
    // Sets a roster member's per-course role (Phase 4b). Authorized per-course:
    // the caller must be an instructor in *this* course (or an admin), not just
    // an instructor somewhere — `requireCourseRole` checks the courseID param,
    // so the relaxed `/instructor` gate can't be driven against another course.

    @Sendable
    func instructorSetEnrollmentRole(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        guard
            let courseIDString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: courseIDString),
            let userIDString = req.parameters.get("userID"),
            let userID = UUID(uuidString: userIDString)
        else {
            throw WebAssignmentError.invalidParameter(
                name: "courseID/userID", reason: "Invalid courseID or userID parameter")
        }
        try await requireCourseInstructor(caller: caller, courseID: courseID, db: req.db)

        struct Body: Content { var role: String? }
        let body = try? req.content.decode(Body.self)
        guard let newRole = CourseRole(rawValue: body?.role ?? "") else {
            throw WebAssignmentError.invalidParameter(name: "role", reason: "Unknown per-course role.")
        }

        guard
            let enrollment = try await APICourseEnrollment.query(on: req.db)
                .filter(\.$course.$id == courseID)
                .filter(\.$userID == userID)
                .first()
        else {
            throw WebAssignmentError.notFound(resource: "Enrollment")
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
        return req.redirect(to: "/instructor/students")
    }
}
