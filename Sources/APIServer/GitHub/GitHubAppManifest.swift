// APIServer/GitHub/GitHubAppManifest.swift
//
// The manifest that creates Chickadee's GitHub App (docs/github-submissions.md
// "App credentials"). An admin posts it to GitHub, confirms the App there, and
// GitHub redirects back with a code that Chickadee exchanges for the App's
// credentials. Nobody copies a key or a secret by hand, so none of them needs
// an environment variable.
//
// The permissions are the slice-3 minimum: read a repository's contents and
// metadata. Slice 4 (course repositories) asks for more; an admin then accepts
// the new permissions on GitHub.

import Foundation

struct GitHubAppManifest: Sendable, Equatable {
    /// Where GitHub redirects the admin with the code to exchange.
    static let callbackPath = "/admin/github/callback"
    /// Where GitHub returns a student who links an account (slice 2).
    static let userCallbackPath = "/github/link/callback"
    /// Where GitHub returns a student who installs the App (slice 3).
    static let setupPath = "/github/installed"

    /// `PUBLIC_BASE_URL` without a trailing slash.
    let base: String
    /// The organization that owns the App, or nil for the admin's own account.
    let organization: GitHubOrganizationName?

    /// Nil when `PUBLIC_BASE_URL` is not set: GitHub needs absolute URLs.
    init?(publicBaseURL: URL?, organization: GitHubOrganizationName?) {
        guard var text = publicBaseURL?.absoluteString, !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        base = text
        self.organization = organization
    }

    /// The GitHub page that receives the manifest form, with the `state` that
    /// the callback must return.
    func creationURL(state: String) -> String {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path =
            if let organization {
                "/organizations/\(organization.value)/settings/apps/new"
            } else {
                "/settings/apps/new"
            }
        components.queryItems = [URLQueryItem(name: "state", value: state)]
        return components.string ?? "https://github.com/settings/apps/new"
    }

    /// The manifest as the JSON string that the form posts.
    func json() throws -> String {
        let data = try JSONEncoder.sortedKeys.encode(body)
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    var body: Body {
        Body(
            name: "Chickadee (\(hostLabel))",
            url: base,
            redirectURL: base + Self.callbackPath,
            callbackURLs: [base + Self.userCallbackPath],
            setupURL: base + Self.setupPath,
            // Any account can install the App: a student installs it on the one
            // repository they submit from.
            public: true,
            defaultPermissions: ["contents": "read", "metadata": "read"],
            // No `hook_attributes` and no events: the App has no webhook until
            // slice 5, so GitHub has no Chickadee URL to call.
            defaultEvents: [])
    }

    /// The host of the base URL, so two deployments make Apps with two names.
    /// GitHub App names are unique across GitHub.
    private var hostLabel: String {
        URL(string: base)?.host ?? base
    }

    struct Body: Encodable, Equatable {
        let name: String
        let url: String
        let redirectURL: String
        let callbackURLs: [String]
        let setupURL: String
        let `public`: Bool
        let defaultPermissions: [String: String]
        let defaultEvents: [String]

        enum CodingKeys: String, CodingKey {
            case name, url, `public`
            case redirectURL = "redirect_url"
            case callbackURLs = "callback_urls"
            case setupURL = "setup_url"
            case defaultPermissions = "default_permissions"
            case defaultEvents = "default_events"
        }
    }
}

extension JSONEncoder {
    /// Sorted keys, so the same manifest always posts the same bytes.
    fileprivate static var sortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
