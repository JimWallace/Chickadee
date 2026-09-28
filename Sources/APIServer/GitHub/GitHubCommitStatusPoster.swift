// APIServer/GitHub/GitHubCommitStatusPoster.swift
//
// Commit statuses (docs/github-submissions.md slice 6). After a GitHub
// submission is graded, and only when the assignment opts in, Chickadee posts
// one status on the commit: the count of PUBLIC-tier tests passed. Release and
// secret tests are never counted, and the grade is never sent.
//
// A status is posted only to a private repository. A student-owned repository
// can be public, and a result must not become public because an assignment
// opted in; a skipped status is logged and changes nothing else.
//
// Best effort: every failure is logged and swallowed, so a GitHub outage never
// fails the worker's result report.

import Core
import Fluent
import Foundation
import Vapor

enum GitHubCommitStatusPoster {
    /// The status for a collection: success when every public test passed.
    static func status(
        for collection: TestOutcomeCollection, context: String, targetURL: String?
    ) -> GitHubCommitStatus {
        guard collection.buildStatus != .failed else {
            return GitHubCommitStatus(
                state: .failure, description: "Build failed", context: context, targetURL: targetURL)
        }
        let publicOutcomes = collection.outcomes.filter { $0.tier == .pub }
        let passed = publicOutcomes.filter { $0.status == .pass }.count
        let description =
            publicOutcomes.isEmpty
            ? "No public tests"
            : "\(passed)/\(publicOutcomes.count) public tests passed"
        return GitHubCommitStatus(
            state: passed == publicOutcomes.count ? .success : .failure,
            description: description, context: context, targetURL: targetURL)
    }

    /// `chickadee/{assignment-slug}`, so two assignments on one commit keep
    /// two statuses.
    static func context(assignmentSlug: String?) -> String {
        "chickadee/" + (assignmentSlug ?? "assignment")
    }

    /// Posts the status when the submission, the assignment and the
    /// repository all allow it.
    static func postIfEnabled(submission: APISubmission, collection: TestOutcomeCollection, req: Request) async {
        guard submission.kind == APISubmission.Kind.student,
            submission.sourceKind == SubmissionSource.github.rawValue,
            let sha = submission.sourceCommit, let repositoryID = submission.sourceRepoID,
            let userID = submission.userID
        else { return }
        do {
            guard let setup = try await APITestSetup.find(submission.testSetupID, on: req.db),
                let manifest = setup.decodedManifest(), manifest.githubSubmission, manifest.githubStatusChecks
            else { return }
            let access = try await access(userID: userID, setup: setup, req: req)
            let repository = try await access.ownedRepository(id: repositoryID, req: req)
            guard repository.isPrivate else {
                req.logger.info(
                    "GitHub status skipped: repository is not private",
                    metadata: ["repository_id": "\(repositoryID)"])
                return
            }
            let assignment = try await assignmentByTestSetupID(submission.testSetupID, on: req.db)
            let status = status(
                for: collection, context: context(assignmentSlug: assignment?.slug),
                targetURL: targetURL(submissionID: try submission.requireID(), req: req))
            try await access.client.createStatus(access.token, repository.fullName, sha, status)
        } catch {
            req.logger.warning("GitHub status not posted", metadata: ["error": "\(error)"])
        }
    }

    /// The course organization's access when the assignment uses course
    /// repositories, else the student's own installation.
    private static func access(
        userID: UUID, setup: APITestSetup, req: Request
    ) async throws -> GitHubSubmissionAccess {
        let setupID = try setup.requireID()
        if try await APIGitHubAssignmentTemplate.query(on: req.db).filter(\.$testSetupID == setupID).first() != nil {
            return try await GitHubSubmissionAccess.resolveCourseRepository(
                userID: userID, testSetupID: setupID, courseID: setup.courseID, req: req)
        }
        return try await GitHubSubmissionAccess.resolve(userID: userID, req: req)
    }

    /// The results page, which only the student and course staff can open.
    private static func targetURL(submissionID: String, req: Request) -> String? {
        guard var base = req.application.securityConfiguration.publicBaseURL?.absoluteString else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/submissions/\(submissionID)"
    }
}
