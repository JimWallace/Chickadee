// Tests/APITests/GitHub/GitHubWebhookTests.swift
//
// Webhooks (docs/github-submissions.md slice 5): the route is 404 while no App
// with a webhook secret is registered; a delivery with a missing or wrong
// signature is refused; a signed push records the last push on the course
// repository it names and starts no grading; other events and unknown
// repositories change nothing; the course page shows the last push; and the
// manifest asks for push events only when the admin opts in.

import ChickadeeTestSupport
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class GitHubWebhookTests {
    static let secret = "hook-secret"
    static let sha = "0123abc" + String(repeating: "d", count: 33)
    static let repoID: Int64 = 400

    let app: Application
    let directory: URL

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-webhook")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-github-webhook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.githubAppSecretsFilePath = directory.appendingPathComponent(".github-app-secrets").path
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func registerApp(webhookSecret: String? = secret) async throws {
        try await APIGitHubApp(
            conversion: GitHubManifestConversion(
                id: 42, slug: "chickadee-courses", name: "Chickadee", clientID: "Iv1.client",
                clientSecret: "client-secret", webhookSecret: webhookSecret, pem: "pem",
                htmlURL: "https://github.com/apps/chickadee-courses", owner: nil)
        ).save(on: app.db)
        try GitHubAppSecrets(privateKeyPEM: "pem", clientSecret: "client-secret", webhookSecret: webhookSecret)
            .write(path: app.githubAppSecretsFilePath)
    }

    /// A course repository row for a student on an assignment.
    private func courseRepository() async throws -> APIGitHubCourseRepository {
        try await wrInsertSetup(id: "gh_setup", on: app)
        try await wrInsertAssignment(testSetupID: "gh_setup", title: "Lab 1", isOpen: true, on: app)
        _ = try await loginUser(username: "gh_student", password: "testpassword", role: "user", on: app)
        let student = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_student").first())
        let row = APIGitHubCourseRepository(
            testSetupID: "gh_setup", userID: try student.requireID(), repoID: Self.repoID,
            repoFullName: "cs101-org/lab-1-octo-student", invited: true)
        try await row.save(on: app.db)
        return row
    }

    private static func pushBody(repoID: Int64 = repoID, after: String = sha, deleted: Bool = false) -> Data {
        Data(
            """
            {"ref":"refs/heads/main","after":"\(after)","deleted":\(deleted),
             "repository":{"id":\(repoID),"full_name":"cs101-org/lab-1-octo-student"},
             "pusher":{"name":"octo-student","email":"octo@example.com"},
             "head_commit":{"message":"private text","author":{"email":"octo@example.com"}}}
            """.utf8)
    }

    private func deliver(
        _ body: Data, event: String = "push", signature: String?,
        _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        try await app.asyncTest(
            .POST, "/github/webhook",
            beforeRequest: { req in
                req.headers.contentType = .json
                req.headers.add(name: "X-GitHub-Event", value: event)
                if let signature { req.headers.add(name: "X-Hub-Signature-256", value: signature) }
                req.body = ByteBuffer(data: body)
            },
            afterResponse: check)
    }

    private func signed(_ body: Data) -> String {
        GitHubWebhookSignature.header(body: body, secret: Self.secret)
    }

    // MARK: - The route

    @Test func withNoAppOrNoSecretTheRouteIs404() async throws {
        try await withApp(app) { _ in
            let body = Self.pushBody()
            try await deliver(body, signature: signed(body)) { res in #expect(res.status == .notFound) }
            try await registerApp(webhookSecret: nil)
            try await deliver(body, signature: signed(body)) { res in #expect(res.status == .notFound) }
        }
    }

    @Test func anUnsignedOrWronglySignedDeliveryIsRefused() async throws {
        try await withApp(app) { app in
            try await registerApp()
            _ = try await courseRepository()
            let body = Self.pushBody()
            try await deliver(body, signature: nil) { res in #expect(res.status == .unauthorized) }
            try await deliver(body, signature: GitHubWebhookSignature.header(body: body, secret: "guess")) { res in
                #expect(res.status == .unauthorized)
            }
            #expect(try await APIGitHubCourseRepository.query(on: app.db).first()?.lastPushedAt == nil)
        }
    }

    @Test func aSignedPushRecordsTheLastPushAndGradesNothing() async throws {
        try await withApp(app) { app in
            try await registerApp()
            _ = try await courseRepository()
            let body = Self.pushBody()
            try await deliver(body, signature: signed(body)) { res in #expect(res.status == .noContent) }
            let row = try #require(try await APIGitHubCourseRepository.query(on: app.db).first())
            #expect(row.lastPushedAt != nil)
            #expect(row.lastPushSHA == Self.sha)
            #expect(try await APISubmission.query(on: app.db).count() == 0, "a push never starts grading")
        }
    }

    @Test func otherEventsDeletionsAndUnknownRepositoriesChangeNothing() async throws {
        try await withApp(app) { app in
            try await registerApp()
            _ = try await courseRepository()
            let ping = Data(#"{"zen":"Keep it logically awesome."}"#.utf8)
            try await deliver(ping, event: "ping", signature: signed(ping)) { res in
                #expect(res.status == .noContent)
            }
            let deleted = Self.pushBody(after: String(repeating: "0", count: 40), deleted: true)
            try await deliver(deleted, signature: signed(deleted)) { res in #expect(res.status == .noContent) }
            let other = Self.pushBody(repoID: 999)
            try await deliver(other, signature: signed(other)) { res in #expect(res.status == .noContent) }
            #expect(try await APIGitHubCourseRepository.query(on: app.db).first()?.lastPushedAt == nil)
        }
    }

    @Test func theCoursePageShowsTheLastPush() async throws {
        try await withApp(app) { app in
            try await registerApp()
            let row = try await courseRepository()
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            try await APIGitHubCourseOrganization(
                courseID: try await wrMakeCourse(on: app).requireID(), installationID: 55, orgID: 7_000,
                orgLogin: "cs101-org"
            ).save(on: app.db)
            try await app.asyncTest(
                .GET, "/instructor/github", beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.body.string.contains("cs101-org/lab-1-octo-student"))
                    #expect(res.body.string.contains("Not reported"))
                })
            row.lastPushedAt = Date()
            try await row.save(on: app.db)
            try await app.asyncTest(
                .GET, "/instructor/github", beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(!res.body.string.contains("Not reported")) })
        }
    }
}

@Suite struct GitHubWebhookManifestTests {
    @Test func signatureAcceptsOnlyTheRightMAC() {
        let body = Data("{}".utf8)
        let good = GitHubWebhookSignature.header(body: body, secret: "s")
        #expect(GitHubWebhookSignature.isValid(body: body, header: good, secret: "s"))
        #expect(!GitHubWebhookSignature.isValid(body: body, header: good, secret: "other"))
        #expect(!GitHubWebhookSignature.isValid(body: Data("{ }".utf8), header: good, secret: "s"))
        #expect(!GitHubWebhookSignature.isValid(body: body, header: nil, secret: "s"))
        #expect(!GitHubWebhookSignature.isValid(body: body, header: "sha1=abc", secret: "s"))
        #expect(!GitHubWebhookSignature.isValid(body: body, header: "sha256=zz", secret: "s"))
        #expect(!GitHubWebhookSignature.isValid(body: body, header: good, secret: ""))
    }

    @Test func pushEventsAreOptIn() throws {
        let base = URL(string: "https://courses.example.edu")
        let plain = try #require(GitHubAppManifest(publicBaseURL: base, organization: nil))
        #expect(plain.body.hookAttributes == nil)
        #expect(plain.body.defaultEvents.isEmpty)
        #expect(!(try plain.json()).contains("hook_attributes"))

        let withPush = try #require(GitHubAppManifest(publicBaseURL: base, organization: nil, pushEvents: true))
        #expect(withPush.body.defaultEvents == ["push"])
        #expect(
            withPush.body.hookAttributes
                == GitHubAppManifest.HookAttributes(url: "https://courses.example.edu/github/webhook", active: true))
    }
}
