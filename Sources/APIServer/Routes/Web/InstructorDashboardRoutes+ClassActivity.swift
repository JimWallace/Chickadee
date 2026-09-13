// APIServer/Routes/Web/InstructorDashboardRoutes+ClassActivity.swift
//
// The per-assignment leaderboard visibility toggle (the Activity section).
//
//   POST /instructor/:assignmentID/activity

import Core
import Fluent
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - POST /instructor/:assignmentID/activity

    /// Publishes or hides the activity's leaderboard. A dedicated lightweight
    /// endpoint for the same reason as the solution-visibility toggle: the
    /// main Save closes and re-validates, which a mid-lab publish must not do.
    /// Display policy only — no regrade, no close. On an assignment with no
    /// activity there is no leaderboard to show, so the request bounces back
    /// to the edit page with an error banner rather than writing anything.
    @Sendable
    func saveActivityLeaderboardSetting(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .instructor)
        guard let current = currentManifestActivity(setup.manifest) else {
            return req.redirect(
                to: "/instructor/\(assignment.publicID)/edit"
                    + "?error=Choose+a+class+activity+kind+and+save+before+publishing+a+leaderboard")
        }
        struct ToggleBody: Content {
            // Checkbox: "on" when checked, absent when not — absence is false.
            var visible: String?
        }
        let visible = ((try? req.content.decode(ToggleBody.self))?.visible) != nil
        try await ActivityAuthoring.setActivity(
            setup: setup,
            to: ClassActivity(kind: current.kind, leaderboardVisibility: visible ? .visible : .hidden),
            on: req.db)
        await AuditLogger.record(
            action: .leaderboardVisibilityChanged,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: [
                "assignment": assignment.publicID,
                "leaderboardVisibility": visible ? "visible" : "hidden",
            ],
            on: req
        )
        return req.redirect(
            to: "/instructor/\(assignment.publicID)/edit?notice=Leaderboard+setting+saved")
    }
}
