// APIServer/Routes/Web/InstructorDashboardRoutes+SecretReveal.swift
//
// The per-assignment secret-reveal token toggle (Student Options).
//
//   POST /instructor/:assignmentID/secret-reveal

import Core
import Fluent
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - POST /instructor/:assignmentID/secret-reveal

    /// Saves the per-assignment secret-reveal toggle. A dedicated lightweight
    /// endpoint rather than a field on the main Save form: `saveEditedAssignment`
    /// closes the assignment and re-enqueues validation on every save, which
    /// would make a mid-semester toggle flip needlessly destructive. Display
    /// policy only — no manifest change, no regrade, no close.
    @Sendable
    func saveSecretRevealSetting(req: Request) async throws -> Response {
        let assignment = try await loadAssignmentForWrite(req, atLeast: .instructor)
        struct ToggleBody: Content {
            // Checkbox: "on" when checked, absent from the body when not —
            // decode as optional and treat absence as false, so unchecking
            // actually turns the toggle off.
            var enabled: String?
        }
        let enabled = ((try? req.content.decode(ToggleBody.self))?.enabled) != nil
        try await AssignmentAuthoringService.updateMetadata(
            assignment, secretRevealEnabled: enabled, on: req.db)
        await AuditLogger.record(
            action: .secretRevealToggled,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: ["assignment": assignment.publicID, "enabled": String(enabled)],
            on: req
        )
        return req.redirect(
            to: "/instructor/\(assignment.publicID)/edit?notice=Secret+reveal+token+setting+saved")
    }
}
