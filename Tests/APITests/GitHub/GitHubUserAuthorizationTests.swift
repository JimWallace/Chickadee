// Tests/APITests/GitHub/GitHubUserAuthorizationTests.swift
//
// The account-link authorization request (docs/github-submissions.md slice 2):
// the PKCE challenge, the redirect URI, and the authorize URL.

import Foundation
import Testing

@testable import APIServer

@Suite struct GitHubUserAuthorizationTests {
    @Test func challengeIsTheS256OfTheVerifier() {
        // Expected value computed independently with Python's hashlib.
        let authorization = GitHubUserAuthorization(
            state: "s", codeVerifier: "dBjftJeZ4CVP-mJ92K9ZTDgHlp1jKNPpUDkg7ynTWvw")
        #expect(authorization.codeChallenge == "VwYUwhyWuPKN2uQ1_HKpnNwR6bWaWRJHLyqc8dlKcls")
    }

    @Test func eachRequestHasFreshSecrets() {
        let first = GitHubUserAuthorization.make()
        let second = GitHubUserAuthorization.make()
        #expect(first.state != second.state)
        #expect(first.codeVerifier != second.codeVerifier)
        #expect(first.state != first.codeVerifier)
    }

    @Test func redirectURIIsTheSliceOneCallbackOnTheBaseURL() {
        let uri = GitHubUserAuthorization.redirectURI(publicBaseURL: URL(string: "https://courses.example.edu/"))
        #expect(uri == "https://courses.example.edu/github/link/callback")
        #expect(uri?.hasSuffix(GitHubAppManifest.userCallbackPath) == true)
    }

    @Test func noRedirectURIWithoutABaseURL() {
        #expect(GitHubUserAuthorization.redirectURI(publicBaseURL: nil) == nil)
    }

    @Test func authorizeURLCarriesTheClientStateAndChallenge() throws {
        let authorization = GitHubUserAuthorization(state: "the-state", codeVerifier: "the-verifier")
        let url = authorization.authorizeURL(
            clientID: "Iv1.client", redirectURI: "https://courses.example.edu/github/link/callback")
        let components = try #require(URLComponents(string: url))
        #expect(components.host == "github.com")
        #expect(components.path == "/login/oauth/authorize")
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["client_id"] == "Iv1.client")
        #expect(items["redirect_uri"] == "https://courses.example.edu/github/link/callback")
        #expect(items["state"] == "the-state")
        #expect(items["code_challenge"] == authorization.codeChallenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["allow_signup"] == "false")
        #expect(!url.contains("the-verifier"))
    }
}
