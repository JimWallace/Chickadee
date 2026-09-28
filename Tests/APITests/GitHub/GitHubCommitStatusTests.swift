// Tests/APITests/GitHub/GitHubCommitStatusTests.swift
//
// Commit statuses (docs/github-submissions.md slice 6): the status counts
// public-tier tests only, whatever the release and secret tiers did; a build
// failure is a failure; a status is posted only for an opted-in assignment's
// GitHub submission, and only to a private repository; the setting is saved
// only beside GitHub submission; the flag stays off the runner's manifest; and
// the App asks for the permission only when the admin opts in.

import ChickadeeTestSupport
import Core
import CryptoExtras
import Fluent
import Foundation
import NIOConcurrencyHelpers
import Testing
import VaporTesting

@testable import APIServer

@Suite struct GitHubCommitStatusRuleTests {
    private func collection(_ outcomes: [TestOutcome], build: BuildStatus = .passed) -> TestOutcomeCollection {
        TestOutcomeCollection(
            submissionID: "sub_1", testSetupID: "setup", attemptNumber: 1, buildStatus: build, compilerOutput: nil,
            outcomes: outcomes, totalTests: outcomes.count, passCount: 0, failCount: 0, errorCount: 0,
            timeoutCount: 0, executionTimeMs: 1, runnerVersion: "test", timestamp: Date())
    }

    @Test func countsPublicTestsOnly() {
        let status = GitHubCommitStatusPoster.status(
            for: collection([
                wrMakeOutcome(name: "a"), wrMakeOutcome(name: "b"),
                wrMakeOutcome(name: "r", tier: .release, status: .fail),
                wrMakeOutcome(name: "s", tier: .secret, status: .fail),
            ]),
            context: "chickadee/lab-1", targetURL: nil)
        #expect(status.state == .success)
        #expect(status.description == "2/2 public tests passed")
        #expect(status.context == "chickadee/lab-1")
    }

    @Test func aFailedPublicTestIsAFailure() {
        let status = GitHubCommitStatusPoster.status(
            for: collection([wrMakeOutcome(name: "a"), wrMakeOutcome(name: "b", status: .fail)]),
            context: "c", targetURL: nil)
        #expect(status.state == .failure)
        #expect(status.description == "1/2 public tests passed")
    }

    @Test func aBuildFailureAndNoPublicTests() {
        let failed = GitHubCommitStatusPoster.status(for: collection([], build: .failed), context: "c", targetURL: nil)
        #expect(failed.state == .failure)
        #expect(failed.description == "Build failed")
        let none = GitHubCommitStatusPoster.status(
            for: collection([wrMakeOutcome(name: "s", tier: .secret)]), context: "c", targetURL: nil)
        #expect(none.state == .success)
        #expect(none.description == "No public tests")
    }

    @Test func theFlagIsServerSideAndOptIn() throws {
        let decoded = try JSONDecoder().decode(
            TestProperties.self,
            from: Data(#"{"schemaVersion":1,"githubSubmission":true,"githubStatusChecks":true}"#.utf8))
        #expect(decoded.githubStatusChecks)
        #expect(!decoded.runnerSanitized().githubStatusChecks)
        let rebuilt = try makeWorkerManifestJSON(preserving: decoded, testSuites: [], language: nil)
        #expect(rebuilt.contains("githubStatusChecks"))
        let plain = try JSONDecoder().decode(TestProperties.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        let encoded = try #require(String(data: try JSONEncoder().encode(plain), encoding: .utf8))
        #expect(!encoded.contains("githubStatusChecks"))
    }

    @Test func theStatusesPermissionIsOptIn() throws {
        let base = URL(string: "https://courses.example.edu")
        let plain = try #require(GitHubAppManifest(publicBaseURL: base, organization: nil))
        #expect(plain.body.defaultPermissions["statuses"] == nil)
        let withStatuses = try #require(GitHubAppManifest(publicBaseURL: base, organization: nil, commitStatuses: true))
        #expect(withStatuses.body.defaultPermissions["statuses"] == "write")
        #expect(withStatuses.body.defaultPermissions["contents"] == "read")
    }
}

@Suite(.serialized, .timeLimit(.minutes(5))) final class GitHubCommitStatusPostingTests {
    static let sha = "0123abc" + String(repeating: "d", count: 33)
    static let manifest = """
        {"schemaVersion":1,"githubSubmission":true,"githubStatusChecks":true,"submissionMode":"uploadOnly"}
        """
    static let privateKeyPEM: String = {
        (try? _RSA.Signing.PrivateKey(keySize: .bits2048).pemRepresentation) ?? ""
    }()

    let app: Application
    let directory: URL
    let posted = NIOLockedValueBox<[String]>([])

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-status")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-github-status-\(UUID().uuidString)")
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

    private func useGitHub(repositoryIsPrivate: Bool) {
        let posted = posted
        let repository = GitHubRepository(
            id: 100, fullName: "octo-student/lab1", ownerID: 9_001, defaultBranch: "main",
            isPrivate: repositoryIsPrivate)
        app.githubRepoClient = GitHubRepoClient(
            findInstallation: { _, _ in GitHubInstallation(id: 5, accountID: 9_001) },
            createInstallationToken: { _, _ in
                GitHubInstallationToken(token: "t", expiresAt: Date().addingTimeInterval(3_600))
            },
            repositories: { _ in [repository] },
            repository: { _, id in id == repository.id ? repository : nil },
            branches: { _, _ in [] },
            commit: { _, _, _ in nil },
            tarball: { _, _, _, _ in Data() },
            createStatus: { _, fullName, sha, status in
                posted.withLockedValue {
                    $0.append(
                        "\(fullName)@\(sha): \(status.state.rawValue) \(status.description) \(status.context) \(status.targetURL ?? "")"
                    )
                }
            })
    }

    /// A graded GitHub submission by a linked student, on `manifest`.
    private func submission(
        manifest: String = manifest, source: SubmissionSource = .github
    ) async throws
        -> APISubmission
    {
        try await APIGitHubApp(
            conversion: GitHubManifestConversion(
                id: 42, slug: "chickadee-courses", name: "Chickadee", clientID: "Iv1.client",
                clientSecret: "secret", webhookSecret: nil, pem: Self.privateKeyPEM,
                htmlURL: "https://github.com/apps/chickadee-courses", owner: nil)
        ).save(on: app.db)
        try GitHubAppSecrets(privateKeyPEM: Self.privateKeyPEM, clientSecret: "secret", webhookSecret: nil)
            .write(path: app.githubAppSecretsFilePath)
        try await wrInsertSetup(id: "gh_setup", manifest: manifest, on: app)
        try await wrInsertAssignment(testSetupID: "gh_setup", title: "Lab 1", isOpen: true, on: app)
        _ = try await loginUser(username: "gh_student", password: "testpassword", role: "user", on: app)
        let student = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
        try await APIGitHubAccountLink(
            userID: try student.requireID(), githubUserID: 9_001, githubLogin: "octo-student"
        )
        .save(on: app.db)
        let row = APISubmission(
            id: "sub_gh", testSetupID: "gh_setup", zipPath: "/tmp/none.zip", attemptNumber: 1,
            userID: try student.requireID())
        row.sourceKind = source.rawValue
        row.sourceRepoID = 100
        row.sourceCommit = Self.sha
        try await row.save(on: app.db)
        return row
    }

    private func post(_ submission: APISubmission) async {
        let req = Request(application: app, on: app.eventLoopGroup.any())
        let collection = TestOutcomeCollection(
            submissionID: "sub_gh", testSetupID: "gh_setup", attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil,
            outcomes: [wrMakeOutcome(name: "a"), wrMakeOutcome(name: "s", tier: .secret, status: .fail)],
            totalTests: 2, passCount: 1, failCount: 1, errorCount: 0, timeoutCount: 0, executionTimeMs: 1,
            runnerVersion: "test", timestamp: Date())
        await GitHubCommitStatusPoster.postIfEnabled(submission: submission, collection: collection, req: req)
    }

    @Test func anOptedInSubmissionPostsToAPrivateRepository() async throws {
        useGitHub(repositoryIsPrivate: true)
        try await withApp(app) { _ in
            await post(try await submission())
            #expect(
                posted.withLockedValue { $0 } == [
                    "octo-student/lab1@\(Self.sha): success 1/1 public tests passed chickadee/lab-1 https://courses.example.edu/submissions/sub_gh"
                ])
        }
    }

    @Test func aPublicRepositoryGetsNoStatus() async throws {
        useGitHub(repositoryIsPrivate: false)
        try await withApp(app) { _ in
            await post(try await submission())
            #expect(posted.withLockedValue { $0 }.isEmpty)
        }
    }

    @Test func anAssignmentThatHasNotOptedInGetsNoStatus() async throws {
        useGitHub(repositoryIsPrivate: true)
        try await withApp(app) { _ in
            await post(try await submission(manifest: #"{"schemaVersion":1,"githubSubmission":true}"#))
            #expect(posted.withLockedValue { $0 }.isEmpty)
        }
    }

    @Test func anUploadGetsNoStatus() async throws {
        useGitHub(repositoryIsPrivate: true)
        try await withApp(app) { _ in
            await post(try await submission(source: .upload))
            #expect(posted.withLockedValue { $0 }.isEmpty)
        }
    }

    @Test func theSettingSavesStatusChecksOnlyBesideSubmission() async throws {
        try await withApp(app) { app in
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            try await wrInsertSetup(id: "gh_toggle", manifest: #"{"schemaVersion":1}"#, on: app)
            let assignment = try await wrInsertAssignment(testSetupID: "gh_toggle", title: "Lab", isOpen: true, on: app)
            let path = "/instructor/\(assignment.publicID)/github-submission"
            for form in [["enabled": "on", "statusChecks": "on"], ["statusChecks": "on"]] {
                let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
                try await app.asyncTest(
                    .POST, path,
                    beforeRequest: { req in
                        req.headers.add(name: .cookie, value: bound)
                        try req.content.encode(form.merging(["_csrf": token]) { $1 }, as: .urlEncodedForm)
                    },
                    afterResponse: { res in #expect(res.status == .seeOther) })
                let manifest = try #require(try await APITestSetup.find("gh_toggle", on: app.db)?.decodedManifest())
                let expected = form["enabled"] != nil
                #expect(manifest.githubSubmission == expected)
                #expect(manifest.githubStatusChecks == expected, "status checks never outlive submission")
            }
        }
    }
}
