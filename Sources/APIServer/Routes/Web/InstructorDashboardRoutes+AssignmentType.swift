// APIServer/Routes/Web/InstructorDashboardRoutes+AssignmentType.swift
//
// The declared assignment type: Assignment, Lab or Class activity
// (docs/assignment-types.md).
//
//   POST /instructor/:assignmentID/assignment-type

import Core
import Fluent
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - POST /instructor/:assignmentID/assignment-type

    /// Saves the declared type. A dedicated lightweight endpoint, like the
    /// Student Options: the main Save closes and re-validates, and the type is
    /// a column, not test content. No manifest change, no regrade. An unknown
    /// value is refused with an error banner.
    @Sendable
    func saveAssignmentType(req: Request) async throws -> Response {
        let assignment = try await loadAssignmentForWrite(req, atLeast: CourseRoleFloor.assignmentLifecycle)
        struct TypeBody: Content {
            var assignmentType: String?
        }
        let raw = (try? await req.decodeContent(TypeBody.self))?.assignmentType ?? ""
        guard let type = AssignmentType(rawValue: raw) else {
            return req.redirect(to: "/instructor/\(assignment.publicID)/edit?error=Unknown+assignment+type")
        }
        assignment.assignmentType = type
        try await assignment.save(on: req.db)
        return req.redirect(to: "/instructor/\(assignment.publicID)/edit?notice=Assignment+type+saved")
    }
}
