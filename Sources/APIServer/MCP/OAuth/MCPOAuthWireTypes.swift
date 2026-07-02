// APIServer/MCP/OAuth/MCPOAuthWireTypes.swift
//
// Wire DTOs for the OAuth 2.1 endpoints: the parsed /oauth/authorize query and
// the token / registration / revocation request and response bodies (snake_case
// on the wire per RFC 6749/7591/7009).  The consent form/context types stay
// with their handlers in MCPOAuthRoutes+Authorize.swift.
//
// Split out of MCPOAuthRoutes.swift along its MARK seams (#1122, following the
// v0.4.37 large-source splits).  No logic change (the types went from
// file-private to internal so the handler extensions can see them).

import Vapor

/// Parsed `/oauth/authorize` query parameters.
struct AuthorizeQuery {
    let responseType: String
    let clientID: String
    let redirectURI: String
    let scope: String?
    let state: String
    let codeChallenge: String
    let codeChallengeMethod: String
    /// RFC 8707 resource indicator: which resource the client wants a token for
    /// (content `…/mcp` vs admin `…/admin-mcp`).  Optional — when absent the
    /// requested scope's namespace decides.
    let resource: String?

    init(_ req: Request) throws {
        guard
            let clientID = req.query[String.self, at: "client_id"],
            let redirectURI = req.query[String.self, at: "redirect_uri"]
        else {
            throw Abort(.badRequest, reason: "Missing client_id or redirect_uri.")
        }
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.responseType = req.query[String.self, at: "response_type"] ?? ""
        self.scope = req.query[String.self, at: "scope"]
        self.state = req.query[String.self, at: "state"] ?? ""
        self.codeChallenge = req.query[String.self, at: "code_challenge"] ?? ""
        self.codeChallengeMethod = req.query[String.self, at: "code_challenge_method"] ?? ""
        self.resource = req.query[String.self, at: "resource"]
    }
}

struct RegistrationRequest: Content {
    var clientName: String?
    var redirectURIs: [String]
    var grantTypes: [String]?
    var responseTypes: [String]?
    var tokenEndpointAuthMethod: String?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case clientName = "client_name"
        case redirectURIs = "redirect_uris"
        case grantTypes = "grant_types"
        case responseTypes = "response_types"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
        case scope
    }
}

struct RegistrationResponse: Content {
    let clientID: String
    let clientIDIssuedAt: Int
    let clientName: String
    let redirectURIs: [String]
    let grantTypes: [String]
    let responseTypes: [String]
    let tokenEndpointAuthMethod: String
    let scope: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientIDIssuedAt = "client_id_issued_at"
        case clientName = "client_name"
        case redirectURIs = "redirect_uris"
        case grantTypes = "grant_types"
        case responseTypes = "response_types"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
        case scope
    }
}

struct RevokeForm: Content {
    var token: String?
    var tokenTypeHint: String?

    enum CodingKeys: String, CodingKey {
        case token
        case tokenTypeHint = "token_type_hint"
    }
}

struct TokenForm: Content {
    var grantType: String
    var code: String?
    var redirectURI: String?
    var clientID: String?
    var codeVerifier: String?
    var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case grantType = "grant_type"
        case code
        case redirectURI = "redirect_uri"
        case clientID = "client_id"
        case codeVerifier = "code_verifier"
        case refreshToken = "refresh_token"
    }
}

struct TokenResponse: Content {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String
    let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}
