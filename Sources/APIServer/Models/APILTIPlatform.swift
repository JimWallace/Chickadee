// APIServer/Models/APILTIPlatform.swift
//
// One LTI 1.3 platform registration (docs/lti-1-3.md "Platform
// registration"). Registrations live in the database, edited by an admin,
// rather than in environment variables. An empty table means LTI is off.
//
// Nothing here is secret: the platform's endpoints and key-set URL are
// public, and the client and deployment IDs are identifiers, not credentials.
// The tool's private key lives in `.lti-tool-key` (LTIToolKeyAuthority).

import Fluent
import Vapor

final class APILTIPlatform: Model, @unchecked Sendable {
    // @unchecked Sendable: only mutated within a request/DB context before save.
    static let schema = "lti_platforms"

    @ID(key: .id)
    var id: UUID?

    /// The platform `iss` value, e.g. `https://learn.uwaterloo.ca`.
    @Field(key: "issuer")
    var issuer: String

    /// The client ID the platform issued to Chickadee.
    @Field(key: "client_id")
    var clientID: String

    /// Accepted deployment IDs, stored newline-delimited (the
    /// `MCPOAuthClient.redirectURIs` shape). Read through `deploymentIDs`.
    @Field(key: "deployment_ids")
    var deploymentIDsRaw: String

    /// The platform OIDC authorization endpoint (third-party login target).
    @Field(key: "auth_login_url")
    var authLoginURL: String

    /// The platform OAuth2 token endpoint (AGS and NRPS client credentials).
    @Field(key: "access_token_url")
    var accessTokenURL: String

    /// The audience of the JWT the tool signs to get an access token. Nil =
    /// the access token URL, which the IMS Security Framework names as the
    /// default. Brightspace needs its "OAuth2 Audience" value here instead.
    @OptionalField(key: "token_audience")
    var tokenAudience: String?

    /// The platform key-set URL that verifies launch `id_token`s.
    @Field(key: "jwks_url")
    var jwksURL: String

    /// Label for the admin UI.
    @Field(key: "display_name")
    var displayName: String

    /// False refuses every launch from this registration.
    @Field(key: "enabled")
    var enabled: Bool

    /// Whether a launch may link to an existing account by the platform's
    /// `username` custom parameter (docs/lti-1-3.md "Identity"). Nil or false
    /// = no: every launched subject gets its own account.
    @OptionalField(key: "trust_username")
    var trustUsername: Bool?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        issuer: String,
        clientID: String,
        deploymentIDs: [String],
        authLoginURL: String,
        accessTokenURL: String,
        jwksURL: String,
        displayName: String,
        enabled: Bool = true
    ) {
        self.id = id
        self.issuer = issuer
        self.clientID = clientID
        self.deploymentIDsRaw = Self.joinDeploymentIDs(deploymentIDs)
        self.authLoginURL = authLoginURL
        self.accessTokenURL = accessTokenURL
        self.jwksURL = jwksURL
        self.displayName = displayName
        self.enabled = enabled
    }

    /// The accepted deployment IDs (blank lines dropped).
    var deploymentIDs: [String] {
        get {
            deploymentIDsRaw
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set { deploymentIDsRaw = Self.joinDeploymentIDs(newValue) }
    }

    /// The facts `LTILaunchValidator` checks a launch against.
    var registration: LTIPlatformRegistration {
        LTIPlatformRegistration(
            issuer: issuer, clientID: clientID, deploymentIDs: Set(deploymentIDs))
    }

    private static func joinDeploymentIDs(_ ids: [String]) -> String {
        ids.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
