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

        if let activeCourseUUID = courseState.activeCourseUUID {
            let roster = try await loadEnrolledStudentRows(
                req: req,
                activeCourseUUID: activeCourseUUID,
                activeCourseCode: courseState.active?.code ?? "",
                fmt: fmt,
                isoFormatter: isoFormatter
            )
            enrolledStudents = roster.rows
            enrolledStudentCount = roster.count
            if let course = try await APICourse.find(activeCourseUUID, on: req.db) {
                courseEnrollmentMode = course.enrollmentMode.rawValue
                courseIsArchived = course.isArchived
            }
        }

        let ctx = InstructorStudentsContext(
            currentUser: userContext,
            activeInstructorTab: "students",
            enrolledStudents: enrolledStudents,
            hasEnrolledStudents: !enrolledStudents.isEmpty,
            enrolledStudentCount: enrolledStudentCount,
            courseEnrollmentMode: courseEnrollmentMode,
            courseIsArchived: courseIsArchived
        )
        return try await req.view.render("instructor-students", ctx).encodeResponse(for: req)
    }

    // MARK: - GET /instructor/students-data

    /// JSON feed backing the Students-tab auto-refresh.  Returns the same
    /// rows the page rendered with, so last-seen times and newly enrolled /
    /// removed students stay current without a manual reload.  Returns an
    /// empty array when no course is active (the table simply clears).
    @Sendable
    func studentsData(req: Request) async throws -> [EnrolledStudentRow] {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let activeCourseUUID = courseState.activeCourseUUID else { return [] }
        let roster = try await loadEnrolledStudentRows(
            req: req,
            activeCourseUUID: activeCourseUUID,
            activeCourseCode: courseState.active?.code ?? "",
            fmt: waterlooDateTimeFormatter(),
            isoFormatter: ISO8601DateFormatter()
        )
        return roster.rows
    }
}
