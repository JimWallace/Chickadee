// Tests/APITests/GitHub/GitHubSubmissionIntakeTests.swift
//
// The GitHub submit door goes through `SubmissionIntake` (#2768), like the
// other six doors in `SubmissionIntakeDoorTests`: a commit submission records
// the queued job's diagnostics and awards Pathfinder. GitHub is faked; the
// tarball is a real one.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class GitHubSubmissionIntakeTests {
    static let githubUserID: Int64 = 9_101
    static let sha = "4567abc" + String(repeating: "e", count: 33)
    static let owned = GitHubRepository(
        id: 300, fullName: "octo-intake/lab1", ownerID: githubUserID, defaultBranch: "main", isPrivate: true)
    static let manifest = """
        {"schemaVersion":1,"githubSubmission":true,"submissionMode":"uploadOnly","testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
        """

    let app: Application
    let directory: URL

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-intake")
        directory = try GitHubTestApp.useSecretsDirectory(on: app, prefix: "chickadee-github-intake")
        app.githubRepoClient = GitHubRepoClient(
            findInstallation: { _, login in
                login == "octo-intake" ? GitHubInstallation(id: 6, accountID: Self.githubUserID) : nil
            },
            createInstallationToken: { _, _ in
                GitHubInstallationToken(token: "installation-token", expiresAt: Date().addingTimeInterval(3_600))
            },
            repositories: { _ in [Self.owned] },
            repository: { _, id in id == Self.owned.id ? Self.owned : nil },
            branches: { _, _ in ["main"] },
            commit: { _, _, ref in ref == "main" ? GitHubCommit(sha: Self.sha, message: "Lab 1") : nil },
            tarball: { _, _, _, _ in try await GitHubTarballFixture.make(files: ["main.py": "print(1)\n"]) })
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func aCommitSubmissionRunsTheSharedEffects() async throws {
        try await withApp(app) { app in
            try await GitHubTestApp.register(on: app)
            let cookie = try await loginUser(
                username: "gh_intake", password: "testpassword", role: "user", on: app)
            let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gh_intake").first())
            try await wrEnrollUser(user, on: app)
            try await wrInsertSetup(id: "gh_intake_setup", manifest: Self.manifest, on: app)
            try await wrInsertAssignment(testSetupID: "gh_intake_setup", title: "Lab 1", isOpen: true, on: app)
            try await APIGitHubAccountLink(
                userID: try user.requireID(), githubUserID: Self.githubUserID, githubLogin: "octo-intake"
            ).save(on: app.db)

            let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/testsetups/gh_intake_setup/github",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: bound)
                    try req.content.encode(
                        ["repositoryID": String(Self.owned.id), "sha": Self.sha, "branch": "main", "_csrf": token],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })

            let row = try #require(try await APISubmission.query(on: app.db).first())
            let subID = try row.requireID()
            #expect(row.userID == user.id)
            #expect(row.status == SubmissionStatus.pending.rawValue)
            #expect(row.zipPath == app.submissionsDirectory + "\(subID).zip")
            #expect(row.sourceCommit == Self.sha)
            #expect(try await APISubmissionDiagnostics.find(subID, on: app.db) != nil)
            let pathfinder = try await APIClassAchievement.query(on: app.db)
                .filter(\.$testSetupID == "gh_intake_setup")
                .filter(\.$achievementID == "pathfinder")
                .first()
            #expect(pathfinder?.userID == user.id)
        }
    }
}
