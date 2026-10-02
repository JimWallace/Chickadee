// Tests/APITests/GitHub/GitHubTokenEvictionTests.swift
//
// A cached installation token outlives its installation: GitHub answers 401
// once the App is removed or re-made, and the cache would serve the old token
// for up to an hour, which the student read as "GitHub did not respond"
// (#1768). The access layer now drops a refused token and resolves once more.

import Core
import Fluent
import Foundation
import NIOConcurrencyHelpers
import Testing
import VaporTesting
import _CryptoExtras

@testable import APIServer

@Suite(.serialized) final class GitHubTokenEvictionTests {

    static let accountID: Int64 = 9_001
    static let privateKeyPEM: String = {
        (try? _RSA.Signing.PrivateKey(keySize: .bits2048).pemRepresentation) ?? ""
    }()

    let app: Application
    let directory: URL
    /// The tokens the fake GitHub issued, in order.
    let issued = NIOLockedValueBox<[String]>([])
    /// The tokens each repository list call was made with, in order.
    let calls = NIOLockedValueBox<[String]>([])

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-evict")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-github-evict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.githubAppSecretsFilePath = directory.appendingPathComponent(".github-app-secrets").path
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A fake GitHub that refuses every token named in `refused` and issues
    /// `fresh-0`, `fresh-1`, ... on each token request.
    private func useGitHub(refusing refused: Set<String>) {
        let issued = issued
        let calls = calls
        app.githubRepoClient = GitHubRepoClient(
            findInstallation: { _, _ in GitHubInstallation(id: 5, accountID: Self.accountID) },
            createInstallationToken: { _, _ in
                let token = issued.withLockedValue { tokens in
                    let token = "fresh-\(tokens.count)"
                    tokens.append(token)
                    return token
                }
                return GitHubInstallationToken(token: token, expiresAt: Date().addingTimeInterval(3_600))
            },
            repositories: { token in
                calls.withLockedValue { $0.append(token) }
                if refused.contains(token) { throw GitHubSubmitError.tokenRejected }
                return []
            },
            repository: { _, _ in nil },
            branches: { _, _ in [] },
            commit: { _, _, _ in nil },
            tarball: { _, _, _, _ in Data() })
    }

    /// The App, its secrets and a linked student, with `stale` already cached
    /// for the student's account.
    private func linkedStudent(cachedToken stale: String) async throws -> UUID {
        try await APIGitHubApp(
            conversion: GitHubManifestConversion(
                id: 42, slug: "chickadee-courses", name: "Chickadee", clientID: "Iv1.client",
                clientSecret: "secret", webhookSecret: nil, pem: Self.privateKeyPEM,
                htmlURL: "https://github.com/apps/chickadee-courses", owner: nil)
        ).save(on: app.db)
        try GitHubAppSecrets(privateKeyPEM: Self.privateKeyPEM, clientSecret: "secret", webhookSecret: nil)
            .write(path: app.githubAppSecretsFilePath)
        let student = try await makeTestStudent(on: app, username: "gh_evict_student")
        let studentID = try student.requireID()
        try await APIGitHubAccountLink(userID: studentID, githubUserID: Self.accountID, githubLogin: "octo-student")
            .save(on: app.db)
        await app.githubInstallationTokens.store(
            GitHubInstallationToken(token: stale, expiresAt: Date().addingTimeInterval(3_600)),
            forAccount: Self.accountID)
        return studentID
    }

    @Test func aRefusedTokenIsDroppedAndTheCallRunsAgainWithAFreshOne() async throws {
        useGitHub(refusing: ["stale"])
        try await withApp(app) { _ in
            let studentID = try await linkedStudent(cachedToken: "stale")
            let req = Request(application: app, on: app.eventLoopGroup.any())
            let access = try await GitHubSubmissionAccess.resolve(userID: studentID, req: req)
            #expect(access.token == "stale")

            let repositories = try await access.ownedRepositories(req: req)
            #expect(repositories.isEmpty)
            #expect(calls.withLockedValue { $0 } == ["stale", "fresh-0"])
            #expect(issued.withLockedValue { $0 } == ["fresh-0"])
            #expect(await app.githubInstallationTokens.token(forAccount: Self.accountID) == "fresh-0")
        }
    }

    @Test func aSecondRefusalMeansTheAppIsNotInstalled() async throws {
        useGitHub(refusing: ["stale", "fresh-0"])
        try await withApp(app) { _ in
            let studentID = try await linkedStudent(cachedToken: "stale")
            let req = Request(application: app, on: app.eventLoopGroup.any())
            let access = try await GitHubSubmissionAccess.resolve(userID: studentID, req: req)

            await #expect(throws: GitHubSubmitError.notInstalled) {
                try await access.ownedRepositories(req: req)
            }
            #expect(calls.withLockedValue { $0 } == ["stale", "fresh-0"])
            // Neither refused token is kept for the next request.
            #expect(await app.githubInstallationTokens.token(forAccount: Self.accountID) == nil)
        }
    }
}
