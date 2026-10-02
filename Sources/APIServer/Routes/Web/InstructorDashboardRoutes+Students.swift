// APIServer/Routes/Web/InstructorDashboardRoutes+Students.swift
//
// The Students and BrightSpace tabs of the instructor view.  The Overview
// tab (assignment listing + dashboard metrics) stays on the `list` handler
// in InstructorDashboardRoutes.swift; the enrolled-students roster and the
// grade-export controls were split into their own tabs in the v0.4
// instructor-view rework so each panel can render — and, for the roster,
// self-update — independently.
//
//   GET /instructor/students       → instructor-students.leaf
//   GET /instructor/students-data  → [EnrolledStudentRow] JSON (5s poll)
//   GET /instructor/brightspace    → instructor-brightspace.leaf

import Core
import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - GET /instructor/students

    @Sendable
    func studentsPage(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        let userContext = CurrentUserContext(
            user: user,
            activeCourse: courseState.active,
            enrolledCourses: courseState.all
        )

        // Match `list`: a user with no active course but existing courses
        // belongs on the enrol page, not an empty roster.
        if courseState.active == nil {
            let courseCount = try await APICourse.query(on: req.db).count()
            if courseCount > 0 {
                return req.redirect(to: "/enroll")
            }
        }

        let fmt = waterlooDateTimeFormatter()
        let isoFormatter = ISO8601DateFormatter()

        var enrolledStudents: [EnrolledStudentRow] = []
        var enrolledStudentCount = 0
        var courseEnrollmentMode = CourseEnrollmentMode.open.rawValue
        var courseIsArchived = false
        var brightspaceLinkAvailable = false

        if let activeCourseUUID = courseState.activeCourseUUID {
            let roster = try await loadEnrolledStudentRows(
                req: req,
                activeCourseUUID: activeCourseUUID,
                activeCourseKey: courseState.active?.urlKey ?? "",
                fmt: fmt,
                isoFormatter: isoFormatter
            )
            enrolledStudents = roster.rows
            enrolledStudentCount = roster.count
            if let course = try await APICourse.find(activeCourseUUID, on: req.db) {
                courseEnrollmentMode = course.enrollmentMode.rawValue
                courseIsArchived = course.isArchived
                brightspaceLinkAvailable =
                    (req.application.brightSpaceAppCredentials != nil
                        && !((course.brightspaceOrgUnitID ?? "").isEmpty))
                    || Self.rosterCheckUsesLTI(
                        course: course, valenceConfigured: req.application.brightSpaceAppCredentials != nil)
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
            switch req.query[String.self, at: "staffError"] {
            case "role": return "Choose a staff role (TA or Instructor)."
            case "identifier": return "Enter a valid username or email address."
            default: break
            }
            switch req.query[String.self, at: "handleError"] {
            case "exhausted": return "No unused class handle is left in this course."
            case "notEnrolled": return "That person is not enrolled in this course."
            default: return nil
            }
        }()

        let (staffRows, studentRows) = Self.splitRoster(enrolledStudents)
        let pendingCount = studentRows.filter(\.isPending).count
        let ctx = InstructorStudentsContext(
            currentUser: userContext,
            activeInstructorTab: "students",
            enrolledStudents: studentRows,
            staffRows: staffRows,
            hasStaff: !staffRows.isEmpty,
            hasEnrolledStudents: !studentRows.isEmpty,
            enrolledStudentCount: enrolledStudentCount,
            activeStudentCount: studentRows.count - pendingCount,
            pendingCount: pendingCount,
            showStudentFilter: ListFilterPolicy.showsFilter(rowCount: studentRows.count),
            courseEnrollmentMode: courseEnrollmentMode,
            courseIsArchived: courseIsArchived,
            brightspaceLinkAvailable: brightspaceLinkAvailable,
            canManageRoster: canManageRoster,
            rosterReadOnly: courseIsArchived || !canManageRoster,
            flashSuccess: flashSuccess,
            flashError: flashError
        )
        return try await req.view.render("instructor-students", ctx).encodeResponse(for: req)
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
    ///   * `?fragment=rows` renders `_student-rows.leaf` — the SAME partial the
    ///     page renders, so the poll cannot drift from the page (it used to
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
            fmt: waterlooDateTimeFormatter(),
            isoFormatter: ISO8601DateFormatter()
        )
        guard wantsFragment else {
            return try await roster.rows.encodeResponse(for: req)
        }

        let canManageRoster =
            user.isAdmin || (courseState.active?.role ?? .student) >= .instructor
        let courseIsArchived = try await APICourse.find(activeCourseUUID, on: req.db)?.isArchived ?? false
        let ctx = StudentRowsFragmentContext(
            currentUser: CurrentUserContext(
                user: user,
                activeCourse: courseState.active,
                enrolledCourses: courseState.all
            ),
            enrolledStudents: Self.splitRoster(roster.rows).students,
            rosterReadOnly: courseIsArchived || !canManageRoster
        )
        return try await req.view.render("_student-rows", ctx).encodePollFragment(for: req)
    }
}

extension InstructorDashboardRoutes {
    /// "@username is now Hazy Cache." after "Give new handle", read from the
    /// database rather than from the query string, so a crafted link cannot
    /// put words in the banner.  The Students table has no handle column, so
    /// this is where staff see what the new handle is.
    static func handleChangedFlash(
        userIDString: String, courseID: UUID, on db: Database
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

/// Context for the rows-only fragment of the roster table.  Carries exactly
/// what `_student-rows.leaf` reads — no more, so the fragment cannot start
/// depending on page-level state the poll does not compute.
struct StudentRowsFragmentContext: Encodable {
    let currentUser: CurrentUserContext
    let enrolledStudents: [EnrolledStudentRow]
    let rosterReadOnly: Bool
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
