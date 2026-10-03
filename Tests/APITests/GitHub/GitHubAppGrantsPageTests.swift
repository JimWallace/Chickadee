// Tests/APITests/GitHub/GitHubAppGrantsPageTests.swift
//
// Where the App's granted permissions come from and where they are shown
// (#1776): the two live calls, the admin page (the App's own permissions) and
// the course page (what the organization's installation was granted). GitHub
// is scripted or faked, so nothing here reaches the network.

import ChickadeeTestSupport
import CryptoExtras
import Fluent
import Foundation
import NIOConcurrencyHelpers
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class GitHubAppGrantsPageTests {
    static let api = "https://api.github.com"
    static let installationID: Int64 = 55
    static let privateKeyPEM: String = {
        (try? _RSA.Signing.PrivateKey(keySize: .bits2048).pemRepresentation) ?? ""
    }()

    let app: Application
    let directory: URL
    /// The App JWTs the fake GitHub was asked with, one per call.
    let asked = NIOLockedValueBox<[String]>([])

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-grants")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-github-grants-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.githubAppSecretsFilePath = directory.appendingPathComponent(".github-app-secrets").path
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func registerApp() async throws {
        try await APIGitHubApp(
            conversion: GitHubManifestConversion(
                id: 42, slug: "chickadee-courses", name: "Chickadee", clientID: "Iv1.client",
                clientSecret: "client-secret", webhookSecret: nil, pem: Self.privateKeyPEM,
                htmlURL: "https://github.com/apps/chickadee-courses", owner: nil)
        ).save(on: app.db)
        try GitHubAppSecrets(privateKeyPEM: Self.privateKeyPEM, clientSecret: "client-secret", webhookSecret: nil)
            .write(path: app.githubAppSecretsFilePath)
    }

    /// A GitHub that grants `app` to the App and `installation` to the
    /// organization's installation. Nil makes that read fail.
    private func useGitHub(app appGrants: GitHubAppGrants?, installation: GitHubAppGrants?) {
        let asked = asked
        var client = GitHubRepoClient(
            findInstallation: { _, _ in nil },
            createInstallationToken: { _, id in
                GitHubInstallationToken(token: "installation-\(id)", expiresAt: Date().addingTimeInterval(3_600))
            },
            repositories: { _ in [] },
            repository: { _, _ in nil },
            branches: { _, _ in [] },
            commit: { _, _, _ in nil },
            tarball: { _, _, _, _ in Data() })
        client.appGrants = { jwt in
            asked.withLockedValue { $0.append(jwt) }
            guard let appGrants else { throw GitHubSubmitError.githubFailed }
            return appGrants
        }
        client.installationGrants = { jwt, id in
            asked.withLockedValue { $0.append(jwt) }
            guard let installation, id == Self.installationID else { throw GitHubSubmitError.notInstalled }
            return installation
        }
        app.githubRepoClient = client
    }

    private func page(_ path: String, cookie: String) async throws -> String {
        var body = ""
        try await app.asyncTest(
            .GET, path, beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                body = res.body.string
            })
        return body
    }

    /// An instructor of a course bound to `cs101-org`.
    private func instructorOfBoundCourse() async throws -> String {
        try await APIGitHubCourseOrganization(
            courseID: try await wrMakeCourse(on: app).requireID(), installationID: Self.installationID,
            orgID: 7_000, orgLogin: "cs101-org"
        ).save(on: app.db)
        let cookie = try await wrLoginAsInstructor(on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
        try await wrEnrollUser(user, on: app)
        return cookie
    }

    // MARK: - The live calls

    @Test func theAppIsReadWithTheAppJWT() async throws {
        try await withApp(app) { app throws in
            let github = app.useScriptedGitHub()
            github.script.withLockedValue {
                $0 = [
                    "GET \(Self.api)/app": .json(
                        #"{"id":42,"slug":"chickadee-courses","owner":{"login":"uwaterloo-cs","id":1},"#
                            + #""permissions":{"contents":"read","metadata":"read","statuses":"write"},"#
                            + #""events":["push"],"installations_count":3}"#)
                ]
            }
            let grants = try await GitHubRepoClient.live(app: app).appGrants("app-jwt")
            #expect(
                grants
                    == GitHubAppGrants(
                        permissions: ["contents": "read", "metadata": "read", "statuses": "write"], events: ["push"]))
            let request = try #require(github.sent.withLockedValue { $0 }.first)
            #expect(request.headers.bearerAuthorization?.token == "app-jwt")
        }
    }

    @Test func anInstallationIsReadByIDAndAMissingOneThrows() async throws {
        try await withApp(app) { app throws in
            let url = "GET \(Self.api)/app/installations/55"
            let github = app.useScriptedGitHub()
            github.script.withLockedValue {
                $0 = [
                    url: .json(
                        #"{"id":55,"account":{"login":"cs101-org","id":7000},"#
                            + #""permissions":{"administration":"write","members":"read"},"events":[]}"#)
                ]
            }
            let client = GitHubRepoClient.live(app: app)
            #expect(
                try await client.installationGrants("app-jwt", 55)
                    == GitHubAppGrants(permissions: ["administration": "write", "members": "read"], events: []))

            github.script.withLockedValue { $0[url] = .json(#"{"id":55}"#) }
            #expect(try await client.installationGrants("app-jwt", 55) == GitHubAppGrants(permissions: [:], events: []))

            github.script.withLockedValue { $0[url] = .init(status: .notFound) }
            await #expect(throws: GitHubSubmitError.notInstalled) {
                _ = try await client.installationGrants("app-jwt", 55)
            }
        }
    }

    // MARK: - The admin page

    @Test func theAdminPageShowsWhichOptionsTheAppHas() async throws {
        try await withApp(app) { app in
            try await registerApp()
            useGitHub(
                app: GitHubAppGrants(
                    permissions: ["administration": "write", "members": "read", "statuses": "read"],
                    events: ["push"]),
                installation: nil)
            let cookie = try await loginUser(username: "grants_admin", password: "testpassword", role: "admin", on: app)
            let body = try await page("/admin/github", cookie: cookie)
            #expect(body.contains("<dt>Course repositories</dt>"))
            #expect(body.contains("<dt>Push events</dt>"))
            #expect(body.contains("<dt>Commit statuses</dt>"))
            #expect(body.components(separatedBy: ">Granted<").count - 1 == 2)
            #expect(body.components(separatedBy: ">Not granted<").count - 1 == 1)
            #expect(body.contains("To use an option that is not granted, add it in the App's settings on GitHub."))
            #expect(!body.contains("could not be read from GitHub"))
            #expect(asked.withLockedValue { $0.count } == 1)
        }
    }

    @Test func theAdminPageSaysWhenGitHubDoesNotAnswer() async throws {
        try await withApp(app) { app in
            try await registerApp()
            useGitHub(app: nil, installation: nil)
            let cookie = try await loginUser(username: "grants_admin", password: "testpassword", role: "admin", on: app)
            let body = try await page("/admin/github", cookie: cookie)
            #expect(body.contains("The App's permissions could not be read from GitHub."))
            #expect(!body.contains("<dt>Course repositories</dt>"))
        }
    }

    @Test func theAdminPageDoesNotAskGitHubWithoutTheSecrets() async throws {
        try await withApp(app) { app in
            try await registerApp()
            try FileManager.default.removeItem(atPath: app.githubAppSecretsFilePath)
            useGitHub(app: GitHubAppGrants(permissions: [:], events: []), installation: nil)
            let cookie = try await loginUser(username: "grants_admin", password: "testpassword", role: "admin", on: app)
            let body = try await page("/admin/github", cookie: cookie)
            #expect(!body.contains("<dt>Course repositories</dt>"))
            #expect(!body.contains("could not be read from GitHub"))
            #expect(asked.withLockedValue { $0 }.isEmpty)
        }
    }

    // MARK: - The course page

    @Test func theCoursePageWarnsWhenTheInstallationCannotMakeRepositories() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            useGitHub(
                app: nil,
                installation: GitHubAppGrants(permissions: ["contents": "read", "metadata": "read"], events: []))
            let body = try await page("/instructor/github", cookie: try await instructorOfBoundCourse())
            #expect(body.contains("cannot make course repositories"))
            #expect(body.contains("or an admin must add them to the App."))
            #expect(body.contains("https://github.com/organizations/cs101-org/settings/installations/55"))
            #expect(body.components(separatedBy: ">Not granted<").count - 1 == 3)
        }
    }

    @Test func theCoursePageIsQuietWhenTheInstallationCanMakeRepositories() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            useGitHub(
                app: nil,
                installation: GitHubAppGrants(permissions: ["administration": "write", "members": "read"], events: []))
            let body = try await page("/instructor/github", cookie: try await instructorOfBoundCourse())
            #expect(!body.contains("cannot make course repositories"))
            #expect(body.contains("<dt>Course repositories</dt>"))
            #expect(!body.contains("The permissions of the App on this organization could not be read."))
        }
    }

    @Test func theCoursePageSaysWhenTheInstallationCannotBeRead() async throws {
        try await withApp(app) { _ in
            try await registerApp()
            useGitHub(app: nil, installation: nil)
            let body = try await page("/instructor/github", cookie: try await instructorOfBoundCourse())
            #expect(body.contains("The permissions of the App on this organization could not be read."))
            #expect(!body.contains("cannot make course repositories"))
            #expect(!body.contains("<dt>Course repositories</dt>"))
        }
    }
}
