// Tests/APITests/GitHub/GitHubOutboundBodyShapeTests.swift
//
// The exact top-level keys of every JSON body Chickadee sends to GitHub
// (#2212). docs/github-submissions.md "What reaches GitHub" says what each
// body carries and that none sends a name, an email address or a grade; a
// test that decodes the sent body back into its struct, or checks only the
// keys it expects, still passes when a new field is added. These compare the
// whole key set of the bytes sent.
//
// ADDING A KEY TO ANY BODY HERE IS A CHANGE TO THE PRIVACY TABLE: update the
// table in docs/github-submissions.md in the same change, then this list.
//
// Pinned elsewhere, as exact bodies: the collaborator permission and the
// archive (`GitHubRepoClientLiveTests`), the code exchange form and the
// revoke (`GitHubOAuthClientLiveTests`).

import Foundation
import NIOConcurrencyHelpers
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class GitHubOutboundBodyShapeTests {
    static let api = "https://api.github.com"

    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-github-outbound")
    }

    private func scripted(
        _ answers: ScriptedGitHubClient.Script
    ) -> (
        GitHubRepoClient, NIOLockedValueBox<[ScriptedGitHubClient.Sent]>
    ) {
        let github = app.useScriptedGitHub()
        github.script.withLockedValue { $0 = answers }
        return (.live(app: app), github.sent)
    }

    private static func keys(of body: String?) throws -> Set<String> {
        let data = Data(try #require(body).utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    @Test func generateSendsOwnerNameAndPrivateOnly() async throws {
        try await withApp(app) { _ throws in
            let (client, sent) = scripted([
                "POST \(Self.api)/repos/cs101-org/lab-1-template/generate": .json(
                    GitHubRepoClientLiveTests.repositoryJSON(id: 300, fullName: "cs101-org/lab-1-octo"),
                    status: .created)
            ])
            _ = try await client.generate("t", "cs101-org/lab-1-template", "cs101-org", "lab-1-octo")
            #expect(try Self.keys(of: sent.withLockedValue { $0 }.first?.body) == ["owner", "name", "private"])
        }
    }

    @Test func aCommitStatusSendsStateDescriptionContextAndLinkOnly() async throws {
        try await withApp(app) { _ throws in
            let (client, sent) = scripted([
                "POST \(Self.api)/repos/cs101-org/lab-1-octo/statuses/\(GitHubPayloadFixtures.sha)": .init(
                    status: .created)
            ])
            let status = GitHubCommitStatus(
                state: .success, description: "2/2 public tests passed", context: "chickadee/lab-1",
                targetURL: "https://courses.example.edu/submissions/sub_1")
            try await client.createStatus("t", "cs101-org/lab-1-octo", GitHubPayloadFixtures.sha, status)
            #expect(
                try Self.keys(of: sent.withLockedValue { $0 }.first?.body)
                    == ["state", "description", "context", "target_url"])
        }
    }

    /// The manifest is posted from the admin's browser, so its bytes are the
    /// encoded manifest itself. The webhook block appears only with push
    /// events.
    @Test func theAppManifestSendsOnlyItsDocumentedFields() async throws {
        try await withApp(app) { _ throws in
            let base = URL(string: "https://courses.example.edu/")
            let plain = try #require(GitHubAppManifest(publicBaseURL: base, organization: nil))
            let documented: Set<String> = [
                "name", "url", "redirect_url", "callback_urls", "setup_url", "public", "default_permissions",
                "default_events",
            ]
            #expect(try Self.keys(of: plain.json()) == documented)

            let withPush = try #require(GitHubAppManifest(publicBaseURL: base, organization: nil, pushEvents: true))
            #expect(try Self.keys(of: withPush.json()) == documented.union(["hook_attributes"]))
        }
    }
}
