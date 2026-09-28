// APIServer/Routes/Web/InstructorDashboardRoutes+GitHubSubmission.swift
//
//   POST /instructor/:assignmentID/github-submission
//
// Turns GitHub commit submission on or off for one assignment
// (docs/github-submissions.md slice 3), and with it the commit statuses of
// slice 6, which need submission on. Its own endpoint, like the other
// Student Options, so a mid-term change does not close or re-validate the
// assignment.

import Vapor

extension InstructorDashboardRoutes {
    @Sendable
    func saveGitHubSubmissionSetting(req: Request) async throws -> Response {
        let assignment = try await loadAssignmentForWrite(req, atLeast: .instructor)
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db) else {
            throw Abort(.notFound)
        }
        struct ToggleBody: Content {
            // A checkbox is absent from the body when it is not checked.
            var enabled: String?
            var statusChecks: String?
        }
        let body = try? req.content.decode(ToggleBody.self)
        let enabled = body?.enabled != nil
        let statusChecks = enabled && body?.statusChecks != nil
        try await setManifestGitHubSubmission(setup: setup, enabled: enabled, on: req.db)
        try await setManifestGitHubStatusChecks(setup: setup, enabled: statusChecks, on: req.db)
        await AuditLogger.record(
            action: .githubSubmissionToggled,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: [
                "assignment": assignment.publicID, "enabled": String(enabled),
                "status_checks": String(statusChecks),
            ],
            on: req
        )
        return req.redirect(to: "/instructor/\(assignment.publicID)/edit?notice=GitHub+setting+saved")
    }
}
