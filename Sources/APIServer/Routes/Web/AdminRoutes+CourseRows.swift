// APIServer/Routes/Web/AdminRoutes+CourseRows.swift
//
// The rows of the admin course page, built here so `courseDetail` is loads
// plus render (#2111). The shape `AccountRoutes+Rows.swift` uses for the
// account page.

import Core
import Fluent
import Foundation
import Vapor

extension AdminRoutes {
    /// The course's own row, with its three counts loaded in parallel. `id` is
    /// the path segment as the request spelled it, which the page's links echo.
    static func courseDetailRow(
        for course: APICourse, id: String, courseID: UUID, brightspaceSyncEnabled: Bool, on db: Database
    ) async throws -> AdminCourseRow {
        async let enrollmentCountFetch = enrolledStudentCount(forCourse: courseID, on: db)
        async let assignmentCountFetch = APIAssignment.query(on: db)
            .filter(\.$courseID == courseID)
            .count()
        async let submissionCountFetch = SubmissionRetentionService.submissionCountsByCourse(
            courseIDs: [courseID], on: db)
        return AdminCourseRow(
            id: id,
            code: course.code,
            name: course.name,
            isArchived: course.isArchived,
            enrollmentMode: course.enrollmentMode.rawValue,
            enrollmentCount: try await enrollmentCountFetch,
            assignmentCount: try await assignmentCountFetch,
            submissionCount: (try await submissionCountFetch)[courseID] ?? 0,
            createdAt: course.createdAt.map { iso8601String($0) } ?? "—",
            brightspaceOrgUnitID: course.brightspaceOrgUnitID,
            brightspaceOrgUnitName: course.brightspaceOrgUnitName,
            brightspaceSyncEnabled: brightspaceSyncEnabled
        ).withTerm(course.term)
    }

    /// The roster: every enrolled person, by username, with their per-course
    /// role and their own seeded bird. `mcp` service accounts are enrolled to
    /// scope an agent's access (admin MCP tab), so they are not listed.
    static func enrolledUserRows(
        for enrollments: [APICourseEnrollment], courseID: UUID, on db: Database
    ) async throws -> [AdminCourseEnrolledUserRow] {
        let enrolledUserIDs = enrollments.map { $0.userID }
        guard !enrolledUserIDs.isEmpty else { return [] }
        // Per-course role (from the enrollment row), not the global user role —
        // this is what the staff selector reads/writes (#417 Slice B).
        let roleByUserID = Dictionary(
            enrollments.map { ($0.userID, $0.role) }, uniquingKeysWith: { first, _ in first })
        let users = try await APIUser.query(on: db)
            .filter(\.$id ~~ enrolledUserIDs)
            .filter(\.$role != UserRole.mcp.rawValue)
            .sort(\.$username)
            .all()
        var rows: [AdminCourseEnrolledUserRow] = []
        for user in users {
            guard let uid = user.id else { continue }
            let role = roleByUserID[uid] ?? .student
            var row = AdminCourseEnrolledUserRow(
                id: uid.uuidString,
                username: user.username,
                displayName: user.displayName,
                role: role.rawValue
            )
            // Each person's own seeded bird, as on the admin users list. The
            // staff ring follows this course's role.
            row.avatar = try await AvatarStore.rosterAvatar(for: user, isStaff: role >= .ta, on: db)
            row.hasAvatar = true
            row.roleSelect = RoleSelectCell(
                userID: row.id,
                action: "/admin/courses/\(courseID.uuidString)/role/\(row.id)",
                personName: user.username,
                role: row.role)
            rows.append(row)
        }
        return rows
    }

    /// The course's assignments, by due date.
    static func assignmentRows(
        forCourse courseID: UUID, on db: Database
    ) async throws
        -> [AdminCourseAssignmentRow]
    {
        let assignments = try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseID)
            .sort(\.$dueAt)
            .all()
        let df = waterlooDateTimeFormatter()
        return assignments.map { a in
            AdminCourseAssignmentRow(
                id: a.publicID,
                title: a.title,
                dueAt: a.dueAt.map { df.string(from: $0) },
                isOpen: a.isOpen,
                visibility: a.visibility.rawValue
            )
        }
    }
}
