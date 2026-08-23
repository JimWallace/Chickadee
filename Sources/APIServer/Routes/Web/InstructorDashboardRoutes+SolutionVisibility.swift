// APIServer/Routes/Web/InstructorDashboardRoutes+SolutionVisibility.swift
//
// The per-assignment solution-reveal policy toggle (Student Options).
//
//   POST /instructor/:assignmentID/solution-visibility

import Core
import Fluent
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - POST /instructor/:assignmentID/solution-visibility

    /// Saves the per-assignment solution-reveal policy (`SolutionVisibility`).
    /// A dedicated lightweight endpoint for the same reason as the
    /// secret-reveal toggle: the main Save closes and re-validates, which a
    /// mid-semester policy flip must not do.  Display policy only — no
    /// manifest change, no regrade, no close.
    ///
    /// Enabling is refused while the assignment has no solution on file (fail
    /// loudly while authoring — the student-facing routes only fail soft):
    /// with nothing to reveal, the policy would silently promise students a
    /// page that 404s.
    @Sendable
    func saveSolutionVisibilitySetting(req: Request) async throws -> Response {
        let assignment = try await loadAssignmentForWrite(req, atLeast: .instructor)
        struct ToggleBody: Content {
            // Checkbox: "on" when checked, absent from the body when not —
            // decode as optional and treat absence as false, so unchecking
            // actually turns the policy off.
            var afterDue: String?
        }
        let afterDue = ((try? req.content.decode(ToggleBody.self))?.afterDue) != nil
        if afterDue {
            let hasSolution = try await assignmentHasSolution(
                assignment: assignment, db: req.db,
                testSetupsDirectory: req.application.testSetupsDirectory)
            guard hasSolution else {
                return req.redirect(
                    to: "/instructor/\(assignment.publicID)/edit"
                        + "?error=Upload+or+create+a+solution+before+enabling+the+solution+reveal")
            }
        }
        try await AssignmentAuthoringService.updateMetadata(
            assignment, solutionVisibility: afterDue ? .afterDue : .hidden, on: req.db)
        await AuditLogger.record(
            action: .solutionVisibilityChanged,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: [
                "assignment": assignment.publicID,
                "visibility": assignment.solutionVisibility.rawValue,
            ],
            on: req
        )
        return req.redirect(
            to: "/instructor/\(assignment.publicID)/edit?notice=Solution+visibility+saved")
    }
}
