// APIServer/Routes/Web/InstructorDashboardRoutes+Students.swift
//
// The Students and BrightSpace tabs of the instructor view.  The Overview
// tab (assignment listing + dashboard metrics) stays on the `list` handler
// in InstructorDashboardRoutes.swift; the enrolled-students roster and the
// grade-export controls were split into their own tabs in the v0.4
// instructor-view rework so each panel can render — and, for the roster,
// self-update — independently.
//
//   GET /instructor/students       → InstructorStudentsPage
//   GET /instructor/students-data  → [EnrolledStudentRow] JSON (5s poll)
//   GET /instructor/brightspace    → InstructorBrightspacePage

import Core
import Elementary
import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - GET /instructor/students

    @Sendable
    func studentsPage(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)

        // Match `list`: a user with no active course but existing courses
        // belongs on the enrol page, not an empty roster.
        if courseState.active == nil {
            let courseCount = try await APICourse.query(on: req.db).count()
            if courseCount > 0 {
                return req.redirect(to: "/enroll")
            }
        }

        let fmt = waterlooDateTimeFormatter()

        var enrolledStudents: [EnrolledStudentRow] = []
        var courseEnrollmentMode = CourseEnrollmentMode.open.rawValue
        var courseIsArchived = false

        if let activeCourseUUID = courseState.activeCourseUUID {
            let roster = try await loadEnrolledStudentRows(
                req: req,
                activeCourseUUID: activeCourseUUID,
                activeCourseKey: courseState.active?.urlKey ?? "",
                fmt: fmt
            )
            enrolledStudents = roster.rows
            if let course = try await APICourse.find(activeCourseUUID, on: req.db) {
                courseEnrollmentMode = course.enrollmentMode.rawValue
                courseIsArchived = course.isArchived
            }
        }

        // Roster management (roles, unenroll, staff invite) is instructor-only;
        // a TA in the active course reaches this page but sees it read-only.
        let canManageRoster =
            user.isAdmin || (courseState.active?.role ?? .student) >= .instructor

        var flashSuccess: String? =
            req.query[String.self, at: "staffAdded"] != nil
            ? "Staff member added." : nil
        if let changed = req.query[String.self, at: "handleChanged"],
            let activeCourseUUID = courseState.activeCourseUUID
        {
            flashSuccess = try await Self.handleChangedFlash(
                userIDString: changed, courseID: activeCourseUUID, on: req.db)
        }
        let flashError: String? = {
            switch req.query[String.self, at: "handleError"] {
            case "exhausted": return "No unused class handle is left in this course."
            case "notEnrolled": return "That person is not enrolled in this course."
            default: return nil
            }
        }()

        let (staffRows, studentRows) = Self.splitRoster(enrolledStudents)
        let pendingCount = studentRows.filter(\.isPending).count
        let page = try await PageRequestContext.courseAware(req)
        return try await HTMLResponse {
            InstructorStudentsPage(
                page: page,
                flash: FlashMessages(success: flashSuccess, error: flashError),
                activeCourseID: courseState.active?.id,
                students: studentRows,
                staffRows: staffRows,
                activeStudentCount: studentRows.count - pendingCount,
                pendingCount: pendingCount,
                showStudentFilter: ListFilterPolicy.showsFilter(rowCount: studentRows.count),
                courseEnrollmentMode: courseEnrollmentMode,
                rosterReadOnly: courseIsArchived || !canManageRoster,
                staffForm: StaffFieldsContext(
                    idPrefix: "add-staff", placeholderAllowed: true, defaultRole: .ta,
                    errorQuery: req.query[String.self, at: "staffError"])
            )
        }
        .encodeResponse(for: req)
    }

    /// Instructor and TA rows on one side, student rows and pending
    /// pre-enrolments on the other. The polled table is the second list only;
    /// someone whose role changes moves lists on the next full page load.
    static func splitRoster(
        _ rows: [EnrolledStudentRow]
    ) -> (staff: [EnrolledStudentRow], students: [EnrolledStudentRow]) {
        let staff = rows.filter { !$0.isPending && $0.role != CourseRole.student.rawValue }
        let students = rows.filter { $0.isPending || $0.role == CourseRole.student.rawValue }
        return (staff, students)
    }

    // MARK: - GET /instructor/students-data

    /// Feed backing the Students-tab auto-refresh.  Returns the same rows the
    /// page rendered with, so last-seen times and newly enrolled / removed
    /// students stay current without a manual reload.  Empty when no course is
    /// active (the table simply clears).
    ///
    /// Two representations, one query:
    ///   * `?fragment=rows` renders `StudentRows` — the SAME view the page
    ///     renders, so the poll cannot drift from the page (it used to
    ///     rebuild every row as a JS string, including a whole register-student
    ///     popover, and the two copies diverged by construction);
    ///   * anything else keeps the JSON array, unchanged, for other consumers.
    @Sendable
    func studentsData(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        let wantsFragment = req.query[String.self, at: "fragment"] == "rows"

        guard let activeCourseUUID = courseState.activeCourseUUID else {
            return wantsFragment
                ? Response.emptyPollFragment(for: req)
                : try await [EnrolledStudentRow]().encodeResponse(for: req)
        }
        let roster = try await loadEnrolledStudentRows(
            req: req,
            activeCourseUUID: activeCourseUUID,
            activeCourseKey: courseState.active?.urlKey ?? "",
            fmt: waterlooDateTimeFormatter()
        )
        guard wantsFragment else {
            return try await roster.rows.encodeResponse(for: req)
        }

        let canManageRoster =
            user.isAdmin || (courseState.active?.role ?? .student) >= .instructor
        let courseIsArchived = try await APICourse.find(activeCourseUUID, on: req.db)?.isArchived ?? false
        let csrfToken = PageRequestContext(request: req).csrfToken
        let html = StudentRows(
            students: Self.splitRoster(roster.rows).students,
            rosterReadOnly: courseIsArchived || !canManageRoster,
            csrfToken: csrfToken
        ).render()
        return Response.pollFragment(html: html, csrfToken: csrfToken, for: req)
    }
}

extension InstructorDashboardRoutes {
    /// "@username is now Hazy Cache." after "Give new handle", read from the
    /// database rather than from the query string, so a crafted link cannot
    /// put words in the banner.  The Students table has no handle column, so
    /// this is where staff see what the new handle is.
    static func handleChangedFlash(
        userIDString: String, courseID: UUID, on db: any Database
    ) async throws -> String? {
        guard let userID = UUID(uuidString: userIDString),
            let handle = try await APICourseEnrollment.query(on: db)
                .filter(\.$course.$id == courseID)
                .filter(\.$userID == userID)
                .first()?.avatarHandle,
            let user = try await APIUser.find(userID, on: db)
        else { return nil }
        return "@\(user.username) now has the class handle \(handle)."
    }
}

extension InstructorDashboardRoutes {
    /// True when the roster check reads the LMS membership instead of the
    /// Valence classlist. The Students tab's decision, asked here and by
    /// `InstructorLMSRoutes.studentsLearnCheck`.
    static func rosterCheckUsesLTI(course: APICourse, valenceConfigured: Bool) -> Bool {
        guard course.ltiMembershipsURL != nil, course.ltiPlatformID != nil else { return false }
        return course.usesLTIGrades || !valenceConfigured || (course.brightspaceOrgUnitID ?? "").isEmpty
    }
}
