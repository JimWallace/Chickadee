// Tests/APITests/GitHub/GitHubRepoClientLiveTests.swift
//
// The live repository client's request builders and status rules (#1775).
// Every other suite installs a fake `GitHubRepoClient`, so until this suite
// the URLs, the path escaping, the 404-and-422-to-nil rules, the rate-limit
// rule and the `.created` checks ran only in production. Vapor's client is
// replaced with `ScriptedGitHubClient`, so nothing here reaches the network.
//
// Not covered: `tarball`, which downloads through AsyncHTTPClient's shared
// client rather than Vapor's, so a scripted Vapor client cannot answer it.
// `GitHubTarballTests` covers what is done with the bytes.

import Foundation
import NIOConcurrencyHelpers
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class GitHubRepoClientLiveTests {
    static let api = "https://api.github.com"

    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-repo-live")
    }

    /// A repository as GitHub documents it, with fields the client ignores.
    static func repositoryJSON(
        id: Int64 = 100, fullName: String = "octo-student/lab1", ownerID: Int64 = 9_001,
        isPrivate: Bool = true, isTemplate: Bool = false
    ) -> String {
        """
        {"id":\(id),"node_id":"R_kgDOA","name":"lab1","full_name":"\(fullName)","private":\(isPrivate),
         "owner":{"login":"octo-student","id":\(ownerID),"type":"User","site_admin":false},
         "html_url":"https://github.com/\(fullName)","description":"Lab 1","fork":false,
         "default_branch":"main","is_template":\(isTemplate),"visibility":"private","archived":false,
         "permissions":{"admin":false,"push":true,"pull":true},"pushed_at":"2026-09-30T12:00:00Z"}
        """
    }

    private func scripted(
        _ answers: ScriptedGitHubClient.Script
    ) -> (
        GitHubRepoClient, NIOLockedValueBox<[ScriptedGitHubClient.Sent]>,
        NIOLockedValueBox<ScriptedGitHubClient.Script>
    ) {
        let github = app.useScriptedGitHub()
        github.script.withLockedValue { $0 = answers }
        return (.live(app: app), github.sent, github.script)
    }

    // MARK: - The student's installation (slice 3)

    @Test func findInstallationSendsTheAppJWTAndReadsTheAccount() async throws {
        try await withApp(app) { _ throws in
            let url = "GET \(Self.api)/users/octo-student/installation"
            let (client, sent, script) = scripted([
                url: .json(#"{"id":5,"app_id":42,"account":{"login":"octo-student","id":9001,"type":"User"}}"#)
            ])
            #expect(
                try await client.findInstallation("app-jwt", "octo-student")
                    == GitHubInstallation(id: 5, accountID: 9_001))
            let request = try #require(sent.withLockedValue { $0 }.first)
            #expect(request.headers.bearerAuthorization?.token == "app-jwt")
            #expect(request.headers.first(name: .accept) == "application/vnd.github+json")

            script.withLockedValue { $0[url] = .init(status: .notFound) }
            #expect(try await client.findInstallation("app-jwt", "octo-student") == nil)
        }
    }

    @Test func anInstallationTokenIsReadOnlyFromA201() async throws {
        try await withApp(app) { _ throws in
            let url = "POST \(Self.api)/app/installations/5/access_tokens"
            let (client, _, script) = scripted([
                url: .json(
                    #"{"token":"ghs_abc","expires_at":"2026-10-03T12:00:00Z","permissions":{"contents":"read"}}"#,
                    status: .created)
            ])
            let token = try await client.createInstallationToken("app-jwt", 5)
            #expect(token.token == "ghs_abc")
            #expect(token.expiresAt == ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z"))

            script.withLockedValue { $0[url] = .init(status: .notFound) }
            await #expect(throws: GitHubSubmitError.notInstalled) {
                _ = try await client.createInstallationToken("app-jwt", 5)
            }
            script.withLockedValue { $0[url] = .json(#"{"token":"ghs_abc","expires_at":"2026-10-03T12:00:00Z"}"#) }
            await #expect(throws: GitHubSubmitError.githubFailed) {
                _ = try await client.createInstallationToken("app-jwt", 5)
            }
        }
    }

    @Test func theGrantedRepositoriesAndOneByID() async throws {
        try await withApp(app) { _ throws in
            let list = "GET \(Self.api)/installation/repositories?per_page=100"
            let one = "GET \(Self.api)/repositories/100"
            let (client, _, script) = scripted([
                list: .json(
                    #"{"total_count":2,"repositories":[\#(Self.repositoryJSON()),"#
                        + #"\#(Self.repositoryJSON(id: 101, fullName: "octo-student/public", isPrivate: false))]}"#),
                one: .json(Self.repositoryJSON()),
            ])
            #expect(
                try await client.repositories("t") == [
                    GitHubRepository(
                        id: 100, fullName: "octo-student/lab1", ownerID: 9_001, defaultBranch: "main",
                        isPrivate: true),
                    GitHubRepository(
                        id: 101, fullName: "octo-student/public", ownerID: 9_001, defaultBranch: "main",
                        isPrivate: false),
                ])
            #expect(try await client.repository("t", 100)?.fullName == "octo-student/lab1")
            script.withLockedValue { $0[one] = .init(status: .notFound) }
            #expect(try await client.repository("t", 100) == nil)
        }
    }

    /// `owner/name` stays two segments and each is escaped; a branch name
    /// such as `feature/x` stays one segment.
    @Test func pathsAreEscapedOneSegmentAtATime() async throws {
        try await withApp(app) { _ throws in
            let (client, sent, _) = scripted([
                "GET \(Self.api)/repos/octo%20student/lab%231/branches?per_page=100": .json(
                    #"[{"name":"main","protected":false},{"name":"feature/x","protected":false}]"#),
                "GET \(Self.api)/repos/octo%20student/lab%231/commits/feature%2Fx": .json(
                    GitHubPayloadFixtures.commit),
            ])
            #expect(try await client.branches("t", "octo student/lab#1") == ["main", "feature/x"])
            #expect(try await client.commit("t", "octo student/lab#1", "feature/x")?.sha == GitHubPayloadFixtures.sha)
            #expect(sent.withLockedValue { $0 }.count == 2)
        }
    }

    /// GitHub's commit carries the author's and committer's names and email
    /// addresses. The client keeps the SHA and the message, and nothing else.
    @Test func aCommitKeepsTheSHAAndMessageOnly() async throws {
        try await withApp(app) { _ throws in
            let (client, _, _) = scripted([
                "GET \(Self.api)/repos/octo-student/lab1/commits/main": .json(GitHubPayloadFixtures.commit)
            ])
            let commit = try #require(try await client.commit("t", "octo-student/lab1", "main"))
            #expect(commit == GitHubCommit(sha: GitHubPayloadFixtures.sha, message: "Fix all the bugs"))
            #expect(Mirror(reflecting: commit).children.map(\.label) == ["sha", "message"])
        }
    }

    /// A ref GitHub does not know is 404, and a malformed one is 422; both
    /// mean "no such commit", not "GitHub failed".
    @Test(arguments: [HTTPResponseStatus.notFound, .unprocessableEntity])
    func aMissingRefIsNil(status: HTTPResponseStatus) async throws {
        try await withApp(app) { _ throws in
            let (client, _, _) = scripted([
                "GET \(Self.api)/repos/octo-student/lab1/commits/nope": .init(status: status)
            ])
            #expect(try await client.commit("t", "octo-student/lab1", "nope") == nil)
        }
    }

    /// A 401 means the installation is gone or re-made; the access layer
    /// drops the cached token and tries once more (#1768).
    @Test func aRejectedTokenThrowsTokenRejected() async throws {
        try await withApp(app) { _ throws in
            let (client, _, _) = scripted([
                "GET \(Self.api)/installation/repositories?per_page=100": .init(status: .unauthorized),
                "PATCH \(Self.api)/repos/cs101-org/lab-1": .init(status: .unauthorized),
            ])
            await #expect(throws: GitHubSubmitError.tokenRejected) { _ = try await client.repositories("t") }
            await #expect(throws: GitHubSubmitError.tokenRejected) { try await client.archive("t", "cs101-org/lab-1") }
        }
    }

    // MARK: - Course repositories (slice 4)

    @Test func templatesAreTheGrantedTemplateRepositories() async throws {
        try await withApp(app) { _ throws in
            let (client, _, _) = scripted([
                "GET \(Self.api)/installation/repositories?per_page=100": .json(
                    #"{"total_count":2,"repositories":["#
                        + Self.repositoryJSON(id: 1, fullName: "cs101-org/lab-1-template", isTemplate: true) + ","
                        + Self.repositoryJSON(id: 2, fullName: "cs101-org/notes") + "]}")
            ])
            #expect(try await client.templates("t").map(\.fullName) == ["cs101-org/lab-1-template"])
        }
    }

    @Test func generateAsksForAPrivateRepositoryAndReadsA201() async throws {
        try await withApp(app) { _ throws in
            let url = "POST \(Self.api)/repos/cs101-org/lab-1-template/generate"
            let (client, sent, _) = scripted([
                url: .json(Self.repositoryJSON(id: 300, fullName: "cs101-org/lab-1-octo"), status: .created)
            ])
            let made = try await client.generate("t", "cs101-org/lab-1-template", "cs101-org", "lab-1-octo")
            #expect(made.id == 300)
            #expect(made.isPrivate)
            let body = try #require(sent.withLockedValue { $0 }.first?.body)
            let sentJSON = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            #expect(sentJSON?["owner"] as? String == "cs101-org")
            #expect(sentJSON?["name"] as? String == "lab-1-octo")
            #expect(sentJSON?["private"] as? Bool == true)
        }
    }

    /// 422 is a taken name; 429, or 403 with no quota left, is the rate
    /// limit; any other refusal is a GitHub failure.
    @Test func generateMapsEachRefusal() async throws {
        try await withApp(app) { _ throws in
            let url = "POST \(Self.api)/repos/cs101-org/lab-1-template/generate"
            let (client, _, script) = scripted([:])
            let cases: [(ScriptedGitHubClient.Answer, GitHubSubmitError)] = [
                (.init(status: .unprocessableEntity), .repositoryNameTaken),
                (.init(status: .tooManyRequests), .rateLimited),
                (.init(status: .forbidden, headers: [("x-ratelimit-remaining", "0")]), .rateLimited),
                (.init(status: .forbidden, headers: [("x-ratelimit-remaining", "12")]), .githubFailed),
                (.init(status: .ok, body: Self.repositoryJSON()), .githubFailed),
            ]
            for (answer, expected) in cases {
                script.withLockedValue { $0[url] = answer }
                await #expect(throws: expected) {
                    _ = try await client.generate("t", "cs101-org/lab-1-template", "cs101-org", "lab-1-octo")
                }
            }
        }
    }

    @Test func userLoginReadsTheCurrentLoginOrNil() async throws {
        try await withApp(app) { _ throws in
            let url = "GET \(Self.api)/user/9001"
            let (client, _, script) = scripted([url: .json(GitHubPayloadFixtures.user)])
            #expect(try await client.userLogin("t", 9_001) == "octocat")
            script.withLockedValue { $0[url] = .init(status: .notFound) }
            #expect(try await client.userLogin("t", 9_001) == nil)
        }
    }

    /// A new invitation is 201 and an existing collaborator is 204; both are
    /// success. Anything else is not.
    @Test func addCollaboratorInvitesWithPushAccess() async throws {
        try await withApp(app) { _ throws in
            let url = "PUT \(Self.api)/repos/cs101-org/lab-1-octo/collaborators/octo-student"
            let (client, sent, script) = scripted([url: .init(status: .created)])
            try await client.addCollaborator("t", "cs101-org/lab-1-octo", "octo-student")
            #expect(sent.withLockedValue { $0 }.first?.body == #"{"permission":"push"}"#)
            script.withLockedValue { $0[url] = .init(status: .noContent) }
            try await client.addCollaborator("t", "cs101-org/lab-1-octo", "octo-student")
            script.withLockedValue { $0[url] = .init(status: .ok) }
            await #expect(throws: GitHubSubmitError.githubFailed) {
                try await client.addCollaborator("t", "cs101-org/lab-1-octo", "octo-student")
            }
            script.withLockedValue { $0[url] = .init(status: .tooManyRequests) }
            await #expect(throws: GitHubSubmitError.rateLimited) {
                try await client.addCollaborator("t", "cs101-org/lab-1-octo", "octo-student")
            }
        }
    }

    /// An unreadable setting is nil, never a guess.
    @Test func privateForksAllowedReadsTheOrganizationSetting() async throws {
        try await withApp(app) { _ throws in
            let url = "GET \(Self.api)/orgs/cs101-org"
            let (client, _, script) = scripted([
                url: .json(#"{"login":"cs101-org","id":7000,"members_can_fork_private_repositories":false}"#)
            ])
            #expect(try await client.privateForksAllowed("t", "cs101-org") == false)
            script.withLockedValue { $0[url] = .json(#"{"login":"cs101-org","id":7000}"#) }
            #expect(try await client.privateForksAllowed("t", "cs101-org") == nil)
            script.withLockedValue { $0[url] = .init(status: .forbidden) }
            #expect(try await client.privateForksAllowed("t", "cs101-org") == nil)
        }
    }

    @Test func archiveSendsArchivedTrueAndNeedsA200() async throws {
        try await withApp(app) { _ throws in
            let url = "PATCH \(Self.api)/repos/cs101-org/lab-1-octo"
            let (client, sent, script) = scripted([url: .json(Self.repositoryJSON())])
            try await client.archive("t", "cs101-org/lab-1-octo")
            #expect(sent.withLockedValue { $0 }.first?.body == #"{"archived":true}"#)
            script.withLockedValue { $0[url] = .init(status: .forbidden) }
            await #expect(throws: GitHubSubmitError.githubFailed) {
                try await client.archive("t", "cs101-org/lab-1-octo")
            }
        }
    }

    // MARK: - Commit statuses (slice 6)

    @Test func createStatusPostsTheStatusAndNeedsA201() async throws {
        try await withApp(app) { _ throws in
            let url = "POST \(Self.api)/repos/cs101-org/lab-1-octo/statuses/\(GitHubPayloadFixtures.sha)"
            let (client, sent, script) = scripted([url: .init(status: .created)])
            let status = GitHubCommitStatus(
                state: .success, description: "2/2 public tests passed", context: "chickadee/lab-1",
                targetURL: "https://courses.example.edu/submissions/sub_1")
            try await client.createStatus("t", "cs101-org/lab-1-octo", GitHubPayloadFixtures.sha, status)
            let body = try #require(sent.withLockedValue { $0 }.first?.body)
            #expect(try JSONDecoder().decode(GitHubCommitStatus.self, from: Data(body.utf8)) == status)
            #expect(body.contains(#""target_url""#))
            script.withLockedValue { $0[url] = .init(status: .unprocessableEntity) }
            await #expect(throws: GitHubSubmitError.githubFailed) {
                try await client.createStatus("t", "cs101-org/lab-1-octo", GitHubPayloadFixtures.sha, status)
            }
        }
    }
}
