// APIServer/LTI/LTIPlatformForm.swift
//
// The admin form that registers or edits an LTI 1.3 platform
// (docs/lti-1-3.md "Platform registration"). Validation is a pure function so
// each rule has its own test without a running app.

import Foundation
import Vapor

struct LTIPlatformForm: Content, Sendable, Equatable {
    var displayName: String
    var issuer: String
    var clientID: String
    /// One deployment ID per line, as typed.
    var deploymentIDs: String
    var authLoginURL: String
    var accessTokenURL: String
    var jwksURL: String
    /// Optional; blank = the access token URL is the audience.
    var tokenAudience: String?
    /// The checkbox: present and true when ticked, absent otherwise.
    var trustUsername: Bool?

    /// A form that passed every rule, trimmed and split.
    struct Validated: Sendable, Equatable {
        let displayName: String
        let issuer: String
        let clientID: String
        let deploymentIDs: [String]
        let authLoginURL: String
        let accessTokenURL: String
        let jwksURL: String
        /// Nil when the field was blank.
        let tokenAudience: String?
        let trustUsername: Bool
    }

    static let empty = LTIPlatformForm(
        displayName: "", issuer: "", clientID: "", deploymentIDs: "",
        authLoginURL: "", accessTokenURL: "", jwksURL: "")

    /// The form pre-filled from a stored registration, for the edit disclosure.
    init(platform: APILTIPlatform) {
        self.init(
            displayName: platform.displayName,
            issuer: platform.issuer,
            clientID: platform.clientID,
            deploymentIDs: platform.deploymentIDs.joined(separator: "\n"),
            authLoginURL: platform.authLoginURL,
            accessTokenURL: platform.accessTokenURL,
            jwksURL: platform.jwksURL,
            tokenAudience: platform.tokenAudience,
            trustUsername: platform.trustUsername ?? false)
    }

    init(
        displayName: String, issuer: String, clientID: String, deploymentIDs: String,
        authLoginURL: String, accessTokenURL: String, jwksURL: String, tokenAudience: String? = nil,
        trustUsername: Bool? = nil
    ) {
        self.displayName = displayName
        self.issuer = issuer
        self.clientID = clientID
        self.deploymentIDs = deploymentIDs
        self.authLoginURL = authLoginURL
        self.accessTokenURL = accessTokenURL
        self.jwksURL = jwksURL
        self.tokenAudience = tokenAudience
        self.trustUsername = trustUsername
    }

    func validated() throws(LTIPlatformFormError) -> Validated {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .missingDisplayName }
        let issuer = try Self.secureURL(issuer, field: .issuer)
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw .missingClientID }
        let deployments =
            deploymentIDs
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !deployments.isEmpty else { throw .missingDeploymentID }
        var seen = Set<String>()
        let uniqueDeployments = deployments.filter { seen.insert($0).inserted }
        return Validated(
            displayName: name,
            issuer: issuer,
            clientID: clientID,
            deploymentIDs: uniqueDeployments,
            authLoginURL: try Self.secureURL(authLoginURL, field: .authLoginURL),
            accessTokenURL: try Self.secureURL(accessTokenURL, field: .accessTokenURL),
            jwksURL: try Self.secureURL(jwksURL, field: .jwksURL),
            tokenAudience: Self.optionalText(tokenAudience),
            trustUsername: trustUsername ?? false)
    }

    /// The trimmed text, or nil when it is blank. The token audience is an
    /// identifier the platform compares, not a URL Chickadee calls, so it is
    /// not held to the URL rules.
    static func optionalText(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// An absolute `https` URL. Plain `http` is accepted only for a loopback
    /// host, so a local test platform works and a production one cannot be
    /// registered over a channel that exposes launch tokens.
    static func secureURL(
        _ raw: String, field: LTIPlatformFormError.URLField
    ) throws(LTIPlatformFormError) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            let host = url.host, !host.isEmpty
        else { throw .invalidURL(field) }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        guard scheme == "https" || (scheme == "http" && loopback) else { throw .insecureURL(field) }
        return trimmed
    }
}
