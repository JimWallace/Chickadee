// APIServer/Routes/Web/InstructorDashboardRoutes+GitHubSubmission.swift
//
//   POST /instructor/:assignmentID/github-submission
//
// Turns GitHub commit submission on or off for one assignment
// (docs/github-submissions.md slice 3), and with it the commit statuses of
// slice 6 and the starter repository, which need submission on. Its own
// endpoint, like the other Student Options, so a mid-term change does not
// close or re-validate the assignment.

import Core
import Fluent
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
            var starterRepository: String?
        }
        let body = try? await req.decodeContent(ToggleBody.self)
        let enabled = body?.enabled != nil
        let statusChecks = enabled && body?.statusChecks != nil
        let editURL = "/instructor/\(assignment.publicID)/edit"
        let starterText = body?.starterRepository?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let starter = GitHubRepositoryName(starterText)
        if enabled, !starterText.isEmpty, starter == nil {
            return req.redirect(
                to: editURL + "?error=Write+the+starter+repository+as+owner%2Fname+or+as+its+GitHub+URL")
        }
        try await setManifestGitHubSubmission(setup: setup, enabled: enabled, on: req.db)
        try await setManifestGitHubStatusChecks(setup: setup, enabled: statusChecks, on: req.db)
        try await setManifestGitHubStarterRepository(setup: setup, to: enabled ? starter : nil, on: req.db)
        await AuditLogger.record(
            action: .githubSubmissionToggled,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: [
                "assignment": assignment.publicID, "enabled": String(enabled),
                "status_checks": String(statusChecks),
                "starter_repository": (enabled ? starter?.value : nil) ?? "",
            ],
            on: req
        )
        return req.redirect(to: editURL + "?notice=GitHub+setting+saved")
    }
}
