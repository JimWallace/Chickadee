// APIServer/Routes/Web/CourseAdminRoutes+Enrollment.swift
//
// Enrollment-related handlers.  Phase 2 of the audit refactor moved them
// from `AssignmentRoutes` onto `CourseAdminRoutes`; the file name still
// starts with `AssignmentRoutes+` for blame continuity until the next
// rename pass.

import Core
import Fluent
import Vapor

/// Trims whitespace and collapses an empty string to nil, so blank form
/// fields are stored as NULL rather than "".
private func trimmedOrNil(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed?.isEmpty == false) ? trimmed : nil
}

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
        try await requireCourseWriteAccess(caller: caller, courseID: courseID, db: req.db)
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
        try await requireCourseWriteAccess(caller: caller, courseID: courseID, db: req.db)

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
        try await requireCourseWriteAccess(caller: caller, courseID: courseID, db: req.db)

        if let enrollment = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseID)
            .filter(\.$userID == userID)
            .first()
        {
            // Don't let a non-admin unenroll the course's last instructor (#417 Slice B).
            if enrollment.role == .instructor {
                try await ensureNotLastInstructor(
                    caller: caller, courseID: courseID, removing: userID, db: req.db)
            }
            try await enrollment.delete(on: req.db)
        }

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
        try await requireCourseWriteAccess(caller: caller, courseID: courseID, db: req.db)

        try await APIPreEnrollment.query(on: req.db)
            .filter(\.$id == preID)
            .filter(\.$course.$id == courseID)
            .delete()

        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /courses/:courseID/pre-enroll/:preEnrollmentID/register
    //
    // Manually materializes a pending pre-enrollment into a real APIUser +
    // enrollment, without waiting for the student to log in.  This is the
    // debug / grade-sync-testing escape valve: an instructor can register a
    // CSV-uploaded student now (supplying their SSO identity), then the
    // student appears on the assignment roster and can be assigned a grade
    // override that pushes to BrightSpace.
    //
    // SSO-safe: the user is created with authProvider "duo-oidc" and the
    // supplied externalSubject (if any).  When the real student later logs in,
    // the SSO upsert adopts the same row — by externalSubject when provided, or
    // by username (empty-subject adoption) otherwise — so no duplicate account
    // is created.

    @Sendable
    func instructorRegisterPreEnrollment(req: Request) async throws -> Response {
        struct Body: Content {
            var externalSubject: String?
            var displayName: String?
            var email: String?
            var studentID: String?
        }

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
        try await requireCourseWriteAccess(caller: caller, courseID: courseID, db: req.db)

        guard
            let preEnrollment = try await APIPreEnrollment.query(on: req.db)
                .filter(\.$id == preID)
                .filter(\.$course.$id == courseID)
                .first()
        else {
            throw WebAssignmentError.notFound(resource: "Pre-enrollment")
        }

        let body = try? req.content.decode(Body.self)
        let username = preEnrollment.username

        // Reuse an existing account with this username (e.g. the student
        // already logged into another course) instead of creating a duplicate.
        let user =
            try await APIUser.query(on: req.db)
            .filter(\.$username == username)
            .first()
            ?? APIUser(
                username: username,
                passwordHash: "",  // SSO users have no local password
                role: UserRole.user.rawValue,
                authProvider: "duo-oidc",
                externalSubject: trimmedOrNil(body?.externalSubject),
                email: trimmedOrNil(body?.email),
                studentID: trimmedOrNil(body?.studentID),
                displayName: trimmedOrNil(body?.displayName)
            )
        if user.id == nil {
            try await user.save(on: req.db)
        }
        let userID = try user.requireID()

        // Enrol (skip if already enrolled), then drop the pre-enrollment.
        let alreadyEnrolled =
            try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseID)
            .filter(\.$userID == userID)
            .first() != nil
        if !alreadyEnrolled {
            try await saveSeededEnrollment(for: user, courseID: courseID, on: req.db)
        }
        try await preEnrollment.delete(on: req.db)

        await AuditLogger.record(
            action: .userProvisioned,
            targetType: .user,
            targetID: userID.uuidString,
            metadata: [
                "username": username,
                "course_id": courseIDString,
                "source": "manual_register",
            ],
            on: req
        )
        return req.redirect(to: "/instructor/students")
    }

    // MARK: - POST /courses/:courseID/staff
    //
    // Self-serve staff invite (#417 Slice F). An instructor adds a co-instructor
    // or TA to *their* course by username or email. Unlike the CSV path — which
    // records a pre-enrollment that seeds to `.student` on first login — this
    // materializes the account immediately (SSO-style placeholder, adopted on
    // first login by username) and enrolls it at the chosen staff role, so the
    // role sticks. Instructor-only: TAs are read-only on the roster, so this
    // uses the `.instructor` write floor rather than the `.ta` content floor.

    @Sendable
    func instructorInviteStaff(req: Request) async throws -> Response {
        struct Body: Content {
            var identifier: String?
            var role: String?
        }

        guard
            let courseIDString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: courseIDString)
        else {
            throw WebAssignmentError.invalidParameter(name: "courseID", reason: "Invalid courseID parameter")
        }

        let caller = try req.auth.require(APIUser.self)
        try await requireCourseWriteAccess(
            caller: caller, courseID: courseID, atLeast: .instructor, db: req.db)

        let body = try? req.content.decode(Body.self)
        let identifier = (body?.identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Only staff roles may be added here; students enrol via CSV / self-serve.
        guard let role = CourseRole(rawValue: body?.role ?? ""), role >= .ta else {
            return req.redirect(to: "/instructor/students?staffError=role")
        }
        guard isAcceptableUsernameForEnrollment(identifier) else {
            return req.redirect(to: "/instructor/students?staffError=identifier")
        }

        // Reuse an existing account matched by username or email; otherwise mint
        // an SSO-style placeholder (no local password) that the real login adopts
        // by username — mirroring `instructorRegisterPreEnrollment`.
        let existing = try await APIUser.query(on: req.db)
            .group(.or) { or in
                or.filter(\.$username == identifier)
                or.filter(\.$email == identifier)
            }
            .first()

        let user: APIUser
        if let existing {
            user = existing
        } else {
            let looksLikeEmail = identifier.contains("@")
            user = APIUser(
                username: identifier,
                passwordHash: "",  // SSO users have no local password
                role: UserRole.user.rawValue,  // deployment role is user; staff authority is per-course
                authProvider: "duo-oidc",
                email: looksLikeEmail ? identifier : nil
            )
            try await user.save(on: req.db)
        }
        let userID = try user.requireID()

        // Enroll at the chosen staff role, or promote an existing enrollment to it.
        if let enrollment = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseID)
            .filter(\.$userID == userID)
            .first()
        {
            enrollment.role = role
            try await enrollment.save(on: req.db)
        } else {
            try await APICourseEnrollment(userID: userID, courseID: courseID, role: role)
                .save(on: req.db)
        }

        await AuditLogger.record(
            action: .enrollmentRoleChanged,
            targetType: .enrollment,
            targetID: userID.uuidString,
            metadata: [
                "course_id": courseIDString,
                "subject_user_id": userID.uuidString,
                "role": role.rawValue,
                "source": "staff_invite",
            ],
            on: req
        )
        return req.redirect(to: "/instructor/students?staffAdded=1")
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
        try await requireCourseWriteAccess(caller: caller, courseID: courseID, db: req.db)

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
        // Don't let a non-admin demote the course's last instructor (#417 Slice B).
        if enrollment.role == .instructor, newRole != .instructor {
            try await ensureNotLastInstructor(
                caller: caller, courseID: courseID, removing: userID, db: req.db)
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
