// Tests/APITests/GitHub/GitHubAppManifestTests.swift
//
// The GitHub App manifest (docs/github-submissions.md slice 1): the URLs GitHub
// is told to return to, the minimum permissions, no webhook, and the creation
// URL for an account or an organization.

import Foundation
import Testing

@testable import APIServer

@Suite struct GitHubAppManifestTests {
    private static let base = URL(string: "https://courses.example.edu/")

    private func manifest(organization: String? = nil) throws -> GitHubAppManifest {
        try #require(
            GitHubAppManifest(
                publicBaseURL: Self.base, organization: organization.flatMap(GitHubOrganizationName.init)))
    }

    @Test func noManifestWithoutAPublicBaseURL() {
        #expect(GitHubAppManifest(publicBaseURL: nil, organization: nil) == nil)
    }

    @Test func urlsAreAbsoluteAndDropTheTrailingSlash() throws {
        let body = try manifest().body
        #expect(body.url == "https://courses.example.edu")
        #expect(body.redirectURL == "https://courses.example.edu/admin/github/callback")
        #expect(body.callbackURLs == ["https://courses.example.edu/github/link/callback"])
        #expect(body.setupURL == "https://courses.example.edu/github/installed")
    }

    @Test func nameCarriesTheHostSoTwoDeploymentsDoNotCollide() throws {
        #expect(try manifest().body.name == "Chickadee (courses.example.edu)")
    }

    @Test func permissionsAreReadOnlyContentsAndMetadata() throws {
        let body = try manifest().body
        #expect(body.defaultPermissions == ["contents": "read", "metadata": "read"])
        #expect(body.public)
    }

    @Test func manifestHasNoWebhook() throws {
        let json = try manifest().json()
        #expect(!json.contains("hook_attributes"))
        #expect(json.contains(#""default_events":[]"#))
    }

    @Test func jsonUsesGitHubKeyNamesAndIsStable() throws {
        let json = try manifest().json()
        #expect(json.contains(#""redirect_url":"https://courses.example.edu/admin/github/callback""#))
        #expect(json.contains(#""default_permissions":{"contents":"read","metadata":"read"}"#))
        #expect(try manifest().json() == json)
    }

    @Test func creationURLForTheAdminsOwnAccount() throws {
        let url = try manifest().creationURL(state: "abc-123")
        #expect(url == "https://github.com/settings/apps/new?state=abc-123")
    }

    @Test func creationURLForAnOrganization() throws {
        let url = try manifest(organization: "uwaterloo-cs").creationURL(state: "abc")
        #expect(url == "https://github.com/organizations/uwaterloo-cs/settings/apps/new?state=abc")
    }

    @Test(arguments: ["uwaterloo", "cs-136", "A1", String(repeating: "a", count: 39)])
    func validOrganizationNames(_ name: String) {
        #expect(GitHubOrganizationName(name)?.value == name)
    }

    @Test(arguments: [
        "", "-lead", "trail-", "two--hyphens", "has space", "slash/path", "dot.name",
        String(repeating: "a", count: 40), "é",
    ])
    func invalidOrganizationNames(_ name: String) {
        #expect(GitHubOrganizationName(name) == nil)
    }

    @Test func organizationNameIgnoresSurroundingWhitespace() {
        #expect(GitHubOrganizationName("  uwaterloo \n")?.value == "uwaterloo")
    }

    @Test(arguments: ["abc123", "a-b_c", String(repeating: "x", count: 200)])
    func wellFormedCodes(_ code: String) {
        #expect(GitHubManifestCode.isWellFormed(code))
    }

    @Test(arguments: ["", "../app", "a/b", "a?b", "a b", String(repeating: "x", count: 201)])
    func malformedCodes(_ code: String) {
        #expect(!GitHubManifestCode.isWellFormed(code))
    }

    @Test func conversionDecodesGitHubsResponse() throws {
        let json = """
            {"id": 42, "slug": "chickadee-courses", "node_id": "X", "name": "Chickadee (courses)",
             "owner": {"login": "uwaterloo-cs", "id": 7},
             "client_id": "Iv1.abc", "client_secret": "secret", "webhook_secret": null,
             "pem": "-----BEGIN RSA PRIVATE KEY-----\\nkey\\n-----END RSA PRIVATE KEY-----\\n",
             "html_url": "https://github.com/apps/chickadee-courses"}
            """
        let conversion = try JSONDecoder().decode(GitHubManifestConversion.self, from: Data(json.utf8))
        #expect(conversion.id == 42)
        #expect(conversion.owner?.login == "uwaterloo-cs")
        #expect(conversion.webhookSecret == nil)
        #expect(conversion.secrets.clientSecret == "secret")
        #expect(conversion.secrets.privateKeyPEM.hasPrefix("-----BEGIN RSA PRIVATE KEY-----"))
    }
}
