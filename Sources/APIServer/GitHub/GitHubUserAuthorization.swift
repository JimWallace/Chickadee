// APIServer/GitHub/GitHubUserAuthorization.swift
//
// The GitHub App user-authorization request that links an account
// (docs/github-submissions.md "Linking an account"): the authorize URL, with
// a single-use `state` and a PKCE S256 challenge. The callback URL is the one
// the slice-1 manifest already registered (`GitHubAppManifest.userCallbackPath`).

import Crypto
import Foundation

struct GitHubUserAuthorization: Sendable, Equatable {
    /// The single-use value the callback must return.
    let state: String
    /// The PKCE verifier. It stays in the session; only its hash leaves.
    let codeVerifier: String

    /// A fresh request with random `state` and verifier.
    static func make() -> GitHubUserAuthorization {
        GitHubUserAuthorization(
            state: LTILaunchSecrets.randomToken(), codeVerifier: LTILaunchSecrets.randomToken())
    }

    /// The S256 challenge for `codeVerifier` (RFC 7636 §4.2).
    var codeChallenge: String {
        Data(SHA256.hash(data: Data(codeVerifier.utf8))).base64URLEncodedString()
    }

    /// The callback URL for a base URL such as `PUBLIC_BASE_URL`, or nil when
    /// there is no base URL: GitHub needs an absolute redirect.
    static func redirectURI(publicBaseURL: URL?) -> String? {
        guard var text = publicBaseURL?.absoluteString, !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        return text + GitHubAppManifest.userCallbackPath
    }

    /// The github.com page that asks the user to authorize the App.
    func authorizeURL(clientID: String, redirectURI: String) -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/login/oauth/authorize"
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            // Never offer to create a GitHub account inside the flow: a
            // student decides that on GitHub, not as a side effect of a link.
            URLQueryItem(name: "allow_signup", value: "false"),
        ]
        return components.string ?? "https://github.com/login/oauth/authorize"
    }
}
