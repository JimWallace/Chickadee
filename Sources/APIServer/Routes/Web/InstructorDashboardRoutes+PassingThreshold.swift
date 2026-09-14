// APIServer/Routes/Web/InstructorDashboardRoutes+PassingThreshold.swift
//
// The per-assignment advisory passing threshold (Student Options).
//
//   POST /instructor/:assignmentID/passing-threshold

import Core
import Fluent
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - POST /instructor/:assignmentID/passing-threshold

    /// Saves the advisory passing threshold. A dedicated lightweight endpoint
    /// for the same reason as the other Student Options toggles: the main
    /// Save closes and re-validates, which a display setting must not do.
    /// Display policy only — no manifest change, no regrade, no grade change.
    ///
    /// An empty field clears the threshold. A value outside 1...100 is
    /// refused with an error banner rather than clamped, so a typo cannot
    /// silently become a different threshold.
    @Sendable
    func savePassingThresholdSetting(req: Request) async throws -> Response {
        let assignment = try await loadAssignmentForWrite(req, atLeast: .instructor)
        struct ThresholdBody: Content {
            var passingThresholdPercent: String?
        }
        let raw = ((try? req.content.decode(ThresholdBody.self))?.passingThresholdPercent ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let update: PassingThresholdUpdate
        if raw.isEmpty {
            update = .clear
        } else if let percent = Int(raw), PassingThresholdUpdate.validRange.contains(percent) {
            update = .set(percent)
        } else {
            return req.redirect(
                to: "/instructor/\(assignment.publicID)/edit"
                    + "?error=Passing+threshold+must+be+a+whole+number+from+1+to+100")
        }
        try await AssignmentAuthoringService.updateMetadata(
            assignment, passingThreshold: update, on: req.db)
        await AuditLogger.record(
            action: .passingThresholdChanged,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: [
                "assignment": assignment.publicID,
                "threshold": assignment.passingThresholdPercent.map(String.init) ?? "none",
            ],
            on: req
        )
        return req.redirect(
            to: "/instructor/\(assignment.publicID)/edit?notice=Passing+threshold+saved")
    }
}
