// Tests/APITests/GitHub/GitHubCommitStatusCourseRepositoryTests.swift
//
// A commit status in course-repository mode (#1775). The repository belongs
// to the course organization, not the student, so the status must be posted
// with the organization's installation token. `GitHubCommitStatusTests` builds
// no template or organization, so before this suite the choice in
// `GitHubCommitStatusPoster.access` ran only in production.

import ChickadeeTestSupport
import Core
import CryptoExtras
import Fluent
import Foundation
import NIOConcurrencyHelpers
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class GitHubCommitStatusCourseRepositoryTests {
    static let sha = "0123abc" + String(repeating: "d", count: 33)
    static let manifest = """
        {"schemaVersion":1,"githubSubmission":true,"githubStatusChecks":true,"submissionMode":"uploadOnly"}
        """
    static let privateKeyPEM: String = {
        (try? _RSA.Signing.PrivateKey(keySize: .bits2048).pemRepresentation) ?? ""
    }()
    static let orgID: Int64 = 7_000
    static let orgInstallationID: Int64 = 55
    static let studentGitHubID: Int64 = 9_001
    static let courseRepository = GitHubRepository(
        id: 300, fullName: "cs101-org/lab-1-octo-student", ownerID: orgID, defaultBranch: "main", isPrivate: true)

    let app: Application
    let directory: URL
    /// Each GitHub call the poster made, in order.
    let calls = NIOLockedValueBox<[String]>([])

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-status-course")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-github-status-course-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.githubAppSecretsFilePath = directory.appendingPathComponent(".github-app-secrets").path
        app.securityConfiguration = AppSecurityConfiguration(
            publicBaseURL: URL(string: "https://courses.example.edu"), enforceHTTPS: false,
            trustForwardedProto: true, sessionCookieSecure: false,
            sessionIdleTimeoutSeconds: 30 * 60, sessionIdleWarningSeconds: 120)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A GitHub where the organization's token can read the course repository
    /// and the student's installation does not exist.
    private func useGitHub() {
        let calls = calls
        let repository = Self.courseRepository
        app.githubRepoClient = GitHubRepoClient(
            findInstallation: { _, login in
                calls.withLockedValue { $0.append("findInstallation \(login)") }
                return nil
            },
            createInstallationToken: { _, installationID in
                calls.withLockedValue { $0.append("token \(installationID)") }
                return GitHubInstallationToken(
                    token: "token-\(installationID)", expiresAt: Date().addingTimeInterval(3_600))
            },
            repositories: { _ in [] },
            repository: { token, id in
                calls.withLockedValue { $0.append("repository \(id) with \(token)") }
                return id == repository.id ? repository : nil
            },
            branches: { _, _ in [] },
            commit: { _, _, _ in nil },
            tarball: { _, _, _, _ in Data() },
            createStatus: { token, fullName, sha, status in
                calls.withLockedValue {
                    $0.append("status \(fullName)@\(sha) with \(token): \(status.state.rawValue) \(status.description)")
                }
            })
    }

    /// An opted-in assignment with a template, the course organization bound,
    /// and a graded GitHub submission from the student's course repository.
    private func submission() async throws -> APISubmission {
        try await APIGitHubApp(
            conversion: GitHubManifestConversion(
                id: 42, slug: "chickadee-courses", name: "Chickadee", clientID: "Iv1.client",
                clientSecret: "secret", webhookSecret: nil, pem: Self.privateKeyPEM,
                htmlURL: "https://github.com/apps/chickadee-courses", owner: nil)
        ).save(on: app.db)
        try GitHubAppSecrets(privateKeyPEM: Self.privateKeyPEM, clientSecret: "secret", webhookSecret: nil)
            .write(path: app.githubAppSecretsFilePath)
        try await wrInsertSetup(id: "gh_setup", manifest: Self.manifest, on: app)
        try await wrInsertAssignment(testSetupID: "gh_setup", title: "Lab 1", isOpen: true, on: app)
        try await APIGitHubCourseOrganization(
            courseID: try await wrMakeCourse(on: app).requireID(), installationID: Self.orgInstallationID,
            orgID: Self.orgID, orgLogin: "cs101-org"
        ).save(on: app.db)
        try await APIGitHubAssignmentTemplate(
            testSetupID: "gh_setup", templateRepoID: 200, templateFullName: "cs101-org/lab-1-template"
        ).save(on: app.db)
        _ = try await loginUser(username: "gh_student", password: "testpassword", role: "user", on: app)
        let student = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
        try await APIGitHubAccountLink(
            userID: try student.requireID(), githubUserID: Self.studentGitHubID, githubLogin: "octo-student"
        ).save(on: app.db)
        try await APIGitHubCourseRepository(
            testSetupID: "gh_setup", userID: try student.requireID(), repoID: Self.courseRepository.id,
            repoFullName: Self.courseRepository.fullName, invited: true
        ).save(on: app.db)
        let row = APISubmission(
            id: "sub_gh", testSetupID: "gh_setup", zipPath: "/tmp/none.zip", attemptNumber: 1,
            userID: try student.requireID())
        row.sourceKind = SubmissionSource.github.rawValue
        row.sourceRepoID = Self.courseRepository.id
        row.sourceCommit = Self.sha
        try await row.save(on: app.db)
        return row
    }

    /// The status goes to the course repository with the organization's
    /// token. The student's own installation is never looked up: a student
    /// in course-repository mode need not have installed the App at all.
    @Test func theStatusIsPostedWithTheOrganizationsToken() async throws {
        useGitHub()
        try await withApp(app) { app in
            let row = try await submission()
            let req = Request(application: app, on: app.eventLoopGroup.any())
            let collection = TestOutcomeCollection(
                submissionID: "sub_gh", testSetupID: "gh_setup", attemptNumber: 1, buildStatus: .passed,
                compilerOutput: nil, outcomes: [wrMakeOutcome(name: "a")], totalTests: 1, passCount: 1,
                failCount: 0, errorCount: 0, timeoutCount: 0, executionTimeMs: 1, runnerVersion: "test",
                timestamp: Date())
            await GitHubCommitStatusPoster.postIfEnabled(submission: row, collection: collection, req: req)

            let token = "token-\(Self.orgInstallationID)"
            #expect(
                calls.withLockedValue { $0 } == [
                    "token \(Self.orgInstallationID)",
                    "repository \(Self.courseRepository.id) with \(token)",
                    "status \(Self.courseRepository.fullName)@\(Self.sha) with \(token): success 1/1 public tests passed",
                ])
        }
    }
}
