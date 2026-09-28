// APIServer/GitHub/GitHubCourseAccess.swift
//
// What the server needs to act in a course's GitHub organization
// (docs/github-submissions.md slice 4): the binding and an installation token
// for the App's installation on the organization. Used to list template
// repositories, make and archive course repositories, and read a student's
// course repository when they submit.

import Fluent
import Foundation
import Vapor

struct GitHubCourseAccess: Sendable {
    let organization: APIGitHubCourseOrganization
    let token: String
    let client: GitHubRepoClient

    /// Throws `GitHubSubmitError.unavailable` when no App is registered or
    /// the course has no organization bound.
    static func resolve(courseID: UUID, req: Request) async throws -> GitHubCourseAccess {
        guard
            let app = try await APIGitHubApp.query(on: req.db).first(),
            let secrets = try? GitHubAppSecrets.load(path: req.application.githubAppSecretsFilePath),
            let organization = try await APIGitHubCourseOrganization.query(on: req.db)
                .filter(\.$courseID == courseID).first()
        else { throw GitHubSubmitError.unavailable }
        let installationID = organization.installationID
        let token = try await GitHubSubmissionAccess.installationToken(
            accountID: organization.orgID, app: app, secrets: secrets, req: req
        ) { _ in installationID }
        return GitHubCourseAccess(organization: organization, token: token, client: req.application.githubRepoClient)
    }

    func templates(req: Request) async throws -> [GitHubRepository] {
        try await GitHubSubmissionAccess.calling(req) {
            try await client.templates(token)
                .sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
        }
    }

    /// Nil when the setting cannot be read.
    func privateForksAllowed(req: Request) async -> Bool? {
        try? await client.privateForksAllowed(token, organization.orgLogin)
    }

    /// Makes the student's private repository from the template, then invites
    /// the student. The row is saved before the invitation, so a failed
    /// invitation can be sent again without making a second repository.
    func makeRepository(
        template: APIGitHubAssignmentTemplate, name: String, testSetupID: String, userID: UUID,
        login: String, req: Request
    ) async throws -> APIGitHubCourseRepository {
        let made = try await GitHubSubmissionAccess.calling(req) {
            try await client.generate(token, template.templateFullName, organization.orgLogin, name)
        }
        let row = APIGitHubCourseRepository(
            testSetupID: testSetupID, userID: userID, repoID: made.id, repoFullName: made.fullName,
            invited: false)
        try await row.save(on: req.db)
        try await invite(row, login: login, req: req)
        return row
    }

    /// Invites the student with write access, and records that it worked.
    func invite(_ row: APIGitHubCourseRepository, login: String, req: Request) async throws {
        try await GitHubSubmissionAccess.calling(req) {
            try await client.addCollaborator(token, row.repoFullName, login)
        }
        row.invited = true
        try await row.save(on: req.db)
    }

    func archive(_ row: APIGitHubCourseRepository, req: Request) async throws {
        try await GitHubSubmissionAccess.calling(req) { try await client.archive(token, row.repoFullName) }
        row.archivedAt = Date()
        try await row.save(on: req.db)
    }
}

/// The name of a course repository: `{assignment-slug}-{github-login}`, as
/// GitHub allows it (letters, digits, `.`, `-`, `_`; at most 100 characters).
enum GitHubCourseRepositoryName {
    static let maxLength = 100

    static func make(assignmentSlug: String, login: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        let clean = { (text: String) in String(text.map { allowed.contains($0) ? $0 : "-" }) }
        let suffix = "-" + clean(login)
        let prefix = String(clean(assignmentSlug).prefix(maxLength - suffix.count))
        let name = (prefix.isEmpty ? "assignment" : prefix) + suffix
        // A name made only of dots is reserved on GitHub.
        return name.allSatisfy { $0 == "." } ? "repository" + suffix : name
    }
}
