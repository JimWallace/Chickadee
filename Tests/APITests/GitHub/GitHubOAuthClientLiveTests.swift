// Tests/APITests/GitHub/GitHubOAuthClientLiveTests.swift
//
// The live account-linking client's request builders and status rules
// (#1775): the code exchange's form body, the user read, the revoke's body
// and Basic authorization, and the installation and membership reads. Vapor's
// client is replaced with `ScriptedGitHubClient`, so nothing here reaches the
// network.

import Foundation
import NIOConcurrencyHelpers
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class GitHubOAuthClientLiveTests {
    static let api = "https://api.github.com"
    static let tokenURL = "POST https://github.com/login/oauth/access_token"

    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-oauth-live")
    }

    static let exchange = GitHubCodeExchange(
        clientID: "Iv1.client", clientSecret: "client-secret", code: "code123", codeVerifier: "verifier456",
        redirectURI: "https://courses.example.edu/github/callback")

    private func scripted(
        _ answers: ScriptedGitHubClient.Script
    ) -> (
        GitHubOAuthClient, NIOLockedValueBox<[ScriptedGitHubClient.Sent]>,
        NIOLockedValueBox<ScriptedGitHubClient.Script>
    ) {
        let github = app.useScriptedGitHub()
        github.script.withLockedValue { $0 = answers }
        return (.live(app: app), github.sent, github.script)
    }

    /// The exchange sends the PKCE verifier and the redirect URI as a form,
    /// and reads the token from a JSON answer.
    @Test func theCodeExchangeSendsAFormAndReadsTheToken() async throws {
        try await withApp(app) { _ throws in
            let (client, sent, _) = scripted([
                Self.tokenURL: .json(#"{"access_token":"gho_abc","token_type":"bearer","scope":""}"#)
            ])
            #expect(try await client.exchangeCode(Self.exchange) == "gho_abc")
            let request = try #require(sent.withLockedValue { $0 }.first)
            #expect(request.headers.contentType == .urlEncodedForm)
            let form = try URLEncodedFormDecoder().decode([String: String].self, from: request.body ?? "")
            #expect(
                form == [
                    "client_id": "Iv1.client", "client_secret": "client-secret", "code": "code123",
                    "code_verifier": "verifier456", "redirect_uri": "https://courses.example.edu/github/callback",
                ])
        }
    }

    /// GitHub answers a bad code with 200 and an `error` field.
    @Test(arguments: [
        #"{"error":"bad_verification_code","error_description":"The code passed is incorrect or expired."}"#,
        #"{"access_token":""}"#,
    ])
    func aRefusedExchangeFails(body: String) async throws {
        try await withApp(app) { _ throws in
            let (client, _, _) = scripted([Self.tokenURL: .json(body)])
            await #expect(throws: GitHubLinkError.exchangeFailed) { _ = try await client.exchangeCode(Self.exchange) }
        }
    }

    @Test func fetchUserKeepsTheIDAndLoginOnly() async throws {
        try await withApp(app) { _ throws in
            let url = "GET \(Self.api)/user"
            let (client, sent, script) = scripted([url: .json(GitHubPayloadFixtures.user)])
            #expect(try await client.fetchUser("gho_abc") == GitHubUser(id: 9_001, login: "octocat"))
            #expect(sent.withLockedValue { $0 }.first?.headers.bearerAuthorization?.token == "gho_abc")
            script.withLockedValue { $0[url] = .init(status: .unauthorized) }
            await #expect(throws: GitHubLinkError.exchangeFailed) { _ = try await client.fetchUser("gho_abc") }
        }
    }

    /// The revoke names the token in the body, authenticates as the App's
    /// OAuth client, and accepts 204 or 200.
    @Test func theRevokeSendsTheTokenUnderBasicAuthorization() async throws {
        try await withApp(app) { _ throws in
            let url = "DELETE \(Self.api)/applications/Iv1.client/token"
            let (client, sent, script) = scripted([url: .init(status: .noContent)])
            try await client.revokeToken("gho_abc", "Iv1.client", "client-secret")
            let request = try #require(sent.withLockedValue { $0 }.first)
            #expect(request.body == #"{"access_token":"gho_abc"}"#)
            #expect(request.headers.basicAuthorization?.username == "Iv1.client")
            #expect(request.headers.basicAuthorization?.password == "client-secret")
            #expect(request.headers.bearerAuthorization == nil)

            script.withLockedValue { $0[url] = .init(status: .ok) }
            try await client.revokeToken("gho_abc", "Iv1.client", "client-secret")
            script.withLockedValue { $0[url] = .init(status: .notFound) }
            await #expect(throws: (any Error).self) {
                try await client.revokeToken("gho_abc", "Iv1.client", "client-secret")
            }
        }
    }

    @Test func userInstallationsMapsEachAccount() async throws {
        try await withApp(app) { _ throws in
            let (client, _, _) = scripted([
                "GET \(Self.api)/user/installations?per_page=100": .json(
                    """
                    {"total_count":2,"installations":[
                     {"id":55,"app_id":42,"target_type":"Organization",
                      "account":{"login":"cs101-org","id":7000,"type":"Organization","site_admin":false}},
                     {"id":5,"app_id":42,"target_type":"User",
                      "account":{"login":"octocat","id":9001,"type":"User","site_admin":false}}]}
                    """)
            ])
            #expect(
                try await client.userInstallations("gho_abc") == [
                    GitHubUserInstallation(
                        installationID: 55, accountID: 7_000, accountLogin: "cs101-org", accountType: "Organization"),
                    GitHubUserInstallation(
                        installationID: 5, accountID: 9_001, accountLogin: "octocat", accountType: "User"),
                ])
        }
    }

    /// Only an active membership has a role. Not a member (404) and not
    /// allowed to see (403) are both nil; any other failure throws.
    @Test func organizationRoleIsTheActiveRoleOrNil() async throws {
        try await withApp(app) { _ throws in
            let url = "GET \(Self.api)/user/memberships/orgs/cs101-org"
            let (client, _, script) = scripted([
                url: .json(#"{"state":"active","role":"admin","organization":{"login":"cs101-org","id":7000}}"#)
            ])
            #expect(try await client.organizationRole("gho_abc", "cs101-org") == "admin")
            script.withLockedValue { $0[url] = .json(#"{"state":"pending","role":"admin"}"#) }
            #expect(try await client.organizationRole("gho_abc", "cs101-org") == nil)
            for status in [HTTPResponseStatus.notFound, .forbidden] {
                script.withLockedValue { $0[url] = .init(status: status) }
                #expect(try await client.organizationRole("gho_abc", "cs101-org") == nil)
            }
            script.withLockedValue { $0[url] = .init(status: .badGateway) }
            await #expect(throws: GitHubLinkError.exchangeFailed) {
                _ = try await client.organizationRole("gho_abc", "cs101-org")
            }
        }
    }
}
