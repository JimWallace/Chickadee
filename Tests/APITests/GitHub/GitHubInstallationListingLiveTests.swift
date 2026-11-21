// Tests/APITests/GitHub/GitHubInstallationListingLiveTests.swift
//
// The live `installationByAccountID` call (#1776), which pages through the
// App's installations to find the one on an account. `GitHubRepoClientLiveTests`
// covers the other live calls; this suite covers the paging rules: a match on
// any page, a short page that ends the search, the page limit, and the error
// mapping of a refused or failed page. Vapor's client is replaced with
// `ScriptedGitHubClient`, so nothing here reaches the network.

import Foundation
import NIOConcurrencyHelpers
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class GitHubInstallationListingLiveTests {
    static let api = "https://api.github.com"

    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-installation-listing")
    }

    private static func pageKey(_ page: Int) -> String {
        "GET \(api)/app/installations?per_page=100&page=\(page)"
    }

    /// One listed installation as GitHub documents it, with fields the client
    /// ignores.
    private static func installationJSON(id: Int64, accountID: Int64, login: String, type: String = "User") -> String {
        """
        {"id":\(id),"app_id":42,"target_type":"\(type)",
         "account":{"login":"\(login)","id":\(accountID),"type":"\(type)","site_admin":false}}
        """
    }

    /// A full page of 100 installations, none of them on `accountID`.
    private static func fullPage(startingAt first: Int64) -> String {
        let entries = (0..<100).map { offset in
            installationJSON(
                id: first + Int64(offset), accountID: 50_000 + first + Int64(offset), login: "acct\(offset)")
        }
        return "[" + entries.joined(separator: ",") + "]"
    }

    private func scripted(
        _ answers: ScriptedGitHubClient.Script
    ) -> (GitHubRepoClient, NIOLockedValueBox<[ScriptedGitHubClient.Sent]>) {
        let github = app.useScriptedGitHub()
        github.script.withLockedValue { $0 = answers }
        return (.live(app: app), github.sent)
    }

    @Test func aMatchOnTheFirstPageIsReadAsTheApp() async throws {
        try await withApp(app) { _ throws in
            let page =
                "[" + Self.installationJSON(id: 7, accountID: 9_001, login: "uw-hlth", type: "Organization") + "]"
            let (client, sent) = scripted([Self.pageKey(1): .json(page)])

            let found = try await client.installationByAccountID("app-jwt", 9_001)
            #expect(
                found
                    == GitHubUserInstallation(
                        installationID: 7, accountID: 9_001, accountLogin: "uw-hlth", accountType: "Organization"))
            let requests = sent.withLockedValue { $0 }
            #expect(requests.count == 1)
            #expect(requests.first?.headers.bearerAuthorization?.token == "app-jwt")
        }
    }

    @Test func aShortPageWithoutAMatchEndsTheSearch() async throws {
        try await withApp(app) { _ throws in
            let page = "[" + Self.installationJSON(id: 7, accountID: 1, login: "someone-else") + "]"
            // Page 2 is scripted so that a second request would find a match.
            let (client, sent) = scripted([
                Self.pageKey(1): .json(page),
                Self.pageKey(2): .json("[" + Self.installationJSON(id: 8, accountID: 9_001, login: "x") + "]"),
            ])

            #expect(try await client.installationByAccountID("app-jwt", 9_001) == nil)
            #expect(
                sent.withLockedValue { $0.map(\.url) } == [Self.pageKey(1).replacingOccurrences(of: "GET ", with: "")])
        }
    }

    @Test func aFullPageLeadsToTheNextPage() async throws {
        try await withApp(app) { _ throws in
            let (client, sent) = scripted([
                Self.pageKey(1): .json(Self.fullPage(startingAt: 1)),
                Self.pageKey(2): .json("[" + Self.installationJSON(id: 500, accountID: 9_001, login: "octo") + "]"),
            ])

            let found = try await client.installationByAccountID("app-jwt", 9_001)
            #expect(found?.installationID == 500)
            #expect(found?.accountType == "User")
            #expect(sent.withLockedValue { $0.count } == 2)
        }
    }

    @Test func theSearchStopsAtThePageLimit() async throws {
        try await withApp(app) { _ throws in
            var script = ScriptedGitHubClient.Script()
            for page in 1...(GitHubRepoClient.installationListPages + 1) {
                script[Self.pageKey(page)] = .json(Self.fullPage(startingAt: Int64(page * 1_000)))
            }
            let (client, sent) = scripted(script)

            #expect(try await client.installationByAccountID("app-jwt", 9_001) == nil)
            #expect(sent.withLockedValue { $0.count } == GitHubRepoClient.installationListPages)
        }
    }

    @Test func aRejectedAppJWTThrowsTokenRejected() async throws {
        try await withApp(app) { _ throws in
            let (client, _) = scripted([Self.pageKey(1): .init(status: .unauthorized)])
            await #expect(throws: GitHubSubmitError.tokenRejected) {
                _ = try await client.installationByAccountID("app-jwt", 9_001)
            }
        }
    }

    @Test(arguments: [HTTPResponseStatus.notFound, .internalServerError, .forbidden])
    func aFailedPageThrowsGitHubFailed(status: HTTPResponseStatus) async throws {
        try await withApp(app) { _ throws in
            let (client, _) = scripted([
                Self.pageKey(1): .json(Self.fullPage(startingAt: 1)),
                Self.pageKey(2): .init(status: status),
            ])
            await #expect(throws: GitHubSubmitError.githubFailed) {
                _ = try await client.installationByAccountID("app-jwt", 9_001)
            }
        }
    }
}
