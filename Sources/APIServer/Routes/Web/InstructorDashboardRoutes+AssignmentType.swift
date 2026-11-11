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
    /// value, or a type whose rules the content breaks
    /// (`AssignmentTypeChange`), is refused with an error banner. A change is
    /// recorded in the audit log.
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
        do {
            try await AssignmentTypeChange.apply(type, to: assignment, via: "web", on: req.db, audit: req)
        } catch let error as AssignmentTypeChangeError {
            return req.redirect(to: "/instructor/\(assignment.publicID)/edit?error=\(urlEncode(error.message))")
        }
        return req.redirect(to: "/instructor/\(assignment.publicID)/edit?notice=Assignment+type+saved")
    }
}
