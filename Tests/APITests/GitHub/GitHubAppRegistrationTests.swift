// Tests/APITests/GitHub/GitHubAppRegistrationTests.swift
//
// The App row and its secrets file are read together (#1771): a missing or
// corrupt file is reported as what it is, not as "no App", and the admin
// page names it.

import ChickadeeTestSupport
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class GitHubAppRegistrationTests {
    let app: Application
    let directory: URL
    var secretsPath: String { directory.appendingPathComponent(".github-app-secrets").path }

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-registration")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-github-registration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.githubAppSecretsFilePath = secretsPath
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func registerRow() async throws {
        try await APIGitHubApp(
            conversion: GitHubManifestConversion(
                id: 42, slug: "chickadee-courses", name: "Chickadee", clientID: "Iv1.client",
                clientSecret: "client-secret", webhookSecret: "hook", pem: "pem",
                htmlURL: "https://github.com/apps/chickadee-courses", owner: nil)
        ).save(on: app.db)
    }

    private func writeSecrets() throws {
        try GitHubAppSecrets(privateKeyPEM: "pem", clientSecret: "client-secret", webhookSecret: "hook")
            .write(path: secretsPath)
    }

    private func state() async throws -> GitHubAppRegistration.State {
        try await GitHubAppRegistration.state(req: Request(application: app, on: app.eventLoopGroup.next()))
    }

    private func resolved() async throws -> Bool {
        try await GitHubAppRegistration.resolve(req: Request(application: app, on: app.eventLoopGroup.next())) != nil
    }

    @Test func noRowIsNoApp() async throws {
        try await withApp(app) { _ in
            try writeSecrets()
            guard case .none = try await state() else { throw IssueRecorded("expected .none") }
            #expect(try await resolved() == false)
        }
    }

    @Test func aRowWithItsFileIsRegistered() async throws {
        try await withApp(app) { _ in
            try await registerRow()
            try writeSecrets()
            guard case .registered(_, let secrets) = try await state() else {
                throw IssueRecorded("expected .registered")
            }
            #expect(secrets.webhookSecret == "hook")
            #expect(try await resolved())
        }
    }

    @Test func aMissingFileIsReportedWithItsPath() async throws {
        try await withApp(app) { _ in
            try await registerRow()
            let state = try await state()
            #expect(state.problem == .missing(path: secretsPath))
            #expect(state.app != nil)
            #expect(try await resolved() == false)
        }
    }

    @Test func aCorruptFileIsReportedAsUnreadable() async throws {
        try await withApp(app) { _ in
            try await registerRow()
            try Data("not json".utf8).write(to: URL(fileURLWithPath: secretsPath))
            let state = try await state()
            guard case .unreadable(let path, _)? = state.problem else { throw IssueRecorded("expected .unreadable") }
            #expect(path == secretsPath)
            #expect(try await resolved() == false)
        }
    }

    @Test func theAdminPageNamesAMissingFile() async throws {
        try await withApp(app) { app in
            try await registerRow()
            let cookie = try await loginUser(username: "gh_reg_admin", password: "testpassword", role: "admin", on: app)
            try await app.asyncTest(
                .GET, "/admin/github",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("Secrets file missing."))
                    #expect(res.body.string.contains("<code>\(secretsPath)</code>"))
                    #expect(res.body.string.contains("tier-danger\">Unavailable"))
                })
        }
    }

    @Test func theWebhookRefusesDeliveriesWithoutTheFile() async throws {
        try await withApp(app) { app in
            try await registerRow()
            try await app.asyncTest(
                .POST, "/github/webhook",
                beforeRequest: { req in
                    req.headers.add(name: "X-GitHub-Event", value: "push")
                    req.headers.add(name: "X-Hub-Signature-256", value: "sha256=00")
                },
                afterResponse: { res in #expect(res.status == .notFound) })
        }
    }
}
