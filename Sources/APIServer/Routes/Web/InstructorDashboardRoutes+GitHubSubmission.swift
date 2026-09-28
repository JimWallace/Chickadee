// APIServer/Routes/Web/InstructorDashboardRoutes+GitHubSubmission.swift
//
//   POST /instructor/:assignmentID/github-submission
//
// Turns GitHub commit submission on or off for one assignment
// (docs/github-submissions.md slice 3). Its own endpoint, like the other
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
        }
        let enabled = ((try? req.content.decode(ToggleBody.self))?.enabled) != nil
        try await setManifestGitHubSubmission(setup: setup, enabled: enabled, on: req.db)
        await AuditLogger.record(
            action: .githubSubmissionToggled,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: ["assignment": assignment.publicID, "enabled": String(enabled)],
            on: req
        )
        return req.redirect(to: "/instructor/\(assignment.publicID)/edit?notice=GitHub+setting+saved")
    }
}
