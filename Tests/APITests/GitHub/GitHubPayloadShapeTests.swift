// Tests/APITests/GitHub/GitHubPayloadShapeTests.swift
//
// What Chickadee keeps from GitHub's payloads (#1775). Each payload carries
// personal data the server does not need — names, email addresses, the
// pusher — and docs/github-submissions.md ("What reaches GitHub") promises it
// is not stored. A decoded struct grew a field without any test noticing
// before this suite: adding `email` to `GitHubUser` would have compiled,
// decoded and passed. The documented payloads are in `GitHubPayloadFixtures`.

import ChickadeeTestSupport
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct GitHubUserShapeTests {
    /// Adding a field here is a decision about personal data, so it must
    /// change this test too.
    @Test func theDecodedUserHoldsTheIDAndLoginOnly() throws {
        let user = try JSONDecoder().decode(GitHubUser.self, from: Data(GitHubPayloadFixtures.user.utf8))
        #expect(user == GitHubUser(id: 9_001, login: "octocat"))
        #expect(Mirror(reflecting: user).children.map(\.label) == ["id", "login"])
    }
}

@Suite(.serialized) final class GitHubPushPayloadTests {
    static let secret = "hook-secret"
    static let repoID: Int64 = 400

    let app: Application
    let directory: URL

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-push-payload")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-github-push-payload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.githubAppSecretsFilePath = directory.appendingPathComponent(".github-app-secrets").path
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// GitHub's full push delivery stores the head commit and the time of the
    /// push on the course repository it names, and nothing else: the row's
    /// other columns are as they were, and no submission is made.
    @Test func aDocumentedPushStoresTheHeadCommitAndNothingElse() async throws {
        try await withApp(app) { app in
            try await APIGitHubApp(
                conversion: GitHubManifestConversion(
                    id: 42, slug: "chickadee-courses", name: "Chickadee", clientID: "Iv1.client",
                    clientSecret: "client-secret", webhookSecret: Self.secret, pem: "pem",
                    htmlURL: "https://github.com/apps/chickadee-courses", owner: nil)
            ).save(on: app.db)
            try GitHubAppSecrets(privateKeyPEM: "pem", clientSecret: "client-secret", webhookSecret: Self.secret)
                .write(path: app.githubAppSecretsFilePath)
            try await wrInsertSetup(id: "gh_setup", on: app)
            try await wrInsertAssignment(testSetupID: "gh_setup", title: "Lab 1", isOpen: true, on: app)
            _ = try await loginUser(username: "gh_student", password: "testpassword", role: "user", on: app)
            let student = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
            try await APIGitHubCourseRepository(
                testSetupID: "gh_setup", userID: try student.requireID(), repoID: Self.repoID,
                repoFullName: "cs101-org/lab-1-octo-student", invited: true
            ).save(on: app.db)
            let submissionsBefore = try await APISubmission.query(on: app.db).count()

            let body = Data(GitHubPayloadFixtures.push(repositoryID: Self.repoID).utf8)
            try await app.asyncTest(
                .POST, "/github/webhook",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.headers.add(name: "X-GitHub-Event", value: "push")
                    req.headers.add(
                        name: "X-Hub-Signature-256",
                        value: GitHubWebhookSignature.header(body: body, secret: Self.secret))
                    req.body = ByteBuffer(data: body)
                },
                afterResponse: { res in #expect(res.status == .noContent) })

            let row = try #require(try await APIGitHubCourseRepository.query(on: app.db).first())
            #expect(row.lastPushSHA == GitHubPayloadFixtures.sha)
            #expect(row.lastPushedAt != nil)
            #expect(row.repoFullName == "cs101-org/lab-1-octo-student")
            #expect(row.repoID == Self.repoID)
            #expect(row.invited)
            #expect(try await APISubmission.query(on: app.db).count() == submissionsBefore)
        }
    }
}
