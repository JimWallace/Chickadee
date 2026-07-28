// APIServer/MCP/OAuth/MCPOAuthRoutes+Authorize.swift
//
// The human-facing half of the OAuth flow: GET /oauth/authorize (validate the
// client/redirect/PKCE, render the consent screen) and POST /oauth/authorize
// (burn the single-use consent token, mint the PKCE code, redirect back to the
// client).  Includes the consent form/context types and the redirect helpers
// these two handlers share.
//
// Split out of MCPOAuthRoutes.swift along its MARK seams (#1122, following the
// v0.4.37 large-source splits).  No logic change.

import Core
import Fluent
import Foundation
import Vapor

extension MCPOAuthRoutes {
    // MARK: - GET /oauth/authorize

    @Sendable
    func authorizeForm(req: Request) async throws -> Response {
        let query = try AuthorizeQuery(req)

        // The client + redirect_uri must validate before we trust the redirect
        // target for any error response (open-redirect guard).
        guard
            let client = try await MCPOAuthClient.query(on: req.db)
                .filter(\.$clientID == query.clientID).first()
        else {
            throw Abort(.badRequest, reason: "Unknown client_id.")
        }
        guard client.redirectURIs.contains(query.redirectURI) else {
            throw Abort(.badRequest, reason: "redirect_uri is not registered for this client.")
        }

        // The Authorize button POSTs here and the server 303s to the client's
        // (now-validated) redirect_uri. Browsers enforce `form-action` across
        // that redirect, so the default `form-action 'self'` would silently
        // block the hop to the connector — add the redirect origin. Likewise a
        // connector may drive this in a popup expecting a `window.opener`
        // handshake, which the default COOP `same-origin` severs; relax it.
        SecurityHeadersMiddleware.allowFormAction(
            SecurityHeadersMiddleware.cspOrigin(of: query.redirectURI), on: req)
        SecurityHeadersMiddleware.setOpenerPolicy("same-origin-allow-popups", on: req)

        // Which resource is being authorized (content authoring vs admin
        // diagnostics) — picks the scope ceiling, role gate, audience, signing
        // authority, and the RFC 9207 `iss` self-identification on every
        // redirect below. Resolved before the first redirecting guard so error
        // responses carry `iss` too, as the RFC requires.
        let surface = resolveSurface(req: req, resource: query.resource, scope: query.scope)
        guard query.responseType == "code" else {
            return redirect(
                query.redirectURI, error: "unsupported_response_type", state: query.state,
                issuer: surface.issuer)
        }
        guard !query.codeChallenge.isEmpty, query.codeChallengeMethod == "S256" else {
            return redirect(
                query.redirectURI, error: "invalid_request", state: query.state,
                issuer: surface.issuer)
        }
        let scopes = resolveScopes(query.scope, ceiling: surface.scopeCeiling)
        guard !scopes.isEmpty else {
            return redirect(
                query.redirectURI, error: "invalid_scope", state: query.state,
                issuer: surface.issuer)
        }

        guard let user = req.auth.get(APIUser.self) else {
            // Stash the full authorize request and send the human to log in;
            // postLoginRedirect brings them back here.
            req.session.data[Self.returnToSessionKey] = req.url.string
            return req.redirect(to: "/login")
        }

        let firstTimeApproval = try await Self.isFirstApproval(
            req, userID: user.id, clientID: client.clientID)

        // Mint a single-use consent token only for a human permitted on THIS
        // surface (instructor+ for content, admin for diagnostics). The token
        // (not a cookie) carries identity + CSRF protection to the POST, so the
        // submit works even when Safari/ITP drops the session cookie on the
        // cross-site hop. Non-permitted users get the not-permitted view and no
        // actionable token.
        let userPermitted = try await surface.permits(user, db: req.db)
        var requestToken: String?
        if let userID = user.id, userPermitted {
            let token = Self.randomToken()
            try await MCPConsentRequest(
                tokenHash: sha256HexDigest(token),
                userID: userID,
                clientID: client.clientID,
                redirectURI: query.redirectURI,
                scope: scopes.sorted().joined(separator: " "),
                state: query.state,
                codeChallenge: query.codeChallenge,
                codeChallengeMethod: query.codeChallengeMethod,
                expiresAt: Date().addingTimeInterval(Self.consentRequestTTLSeconds)
            ).save(on: req.db)
            requestToken = token
        }

        let ordered = Self.scopeDisplayOrder.filter { scopes.contains($0) }
        let context = ConsentContext(
            currentUser: req.currentUserContext,
            clientName: client.name,
            scopeLabels: ordered.map(Self.scopeLabel),
            redirectHost: URLComponents(string: query.redirectURI)?.host ?? query.redirectURI,
            firstTimeApproval: firstTimeApproval,
            notPermitted: !userPermitted,
            permittedRoleLabel: surface.permittedRoleLabel,
            purposeLabel: surface.purposeLabel,
            requestToken: requestToken)
        return try await renderConsent(req, context: context)
    }

    /// How long a rendered consent screen stays submittable.
    static let consentRequestTTLSeconds: TimeInterval = 600

    /// True when the user holds no existing non-revoked grant for this client —
    /// drives the "you have not approved this app before" consent warning.
    private static func isFirstApproval(
        _ req: Request, userID: UUID?, clientID: String
    ) async throws -> Bool {
        guard let userID else { return true }
        let prior = try await MCPGrant.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$clientID == clientID)
            .filter(\.$revoked == false)
            .first()
        return prior == nil
    }

    // MARK: - POST /oauth/authorize

    @Sendable
    func authorizeSubmit(req: Request) async throws -> Response {
        // Identity + CSRF ride on the single-use consent token, not the session
        // cookie — so this works in the cross-site connector context where the
        // cookie is dropped. Look the token up by hash, then burn it.
        let form = try req.content.decode(ConsentForm.self)
        let tokenHash = sha256HexDigest(form.requestToken)
        guard
            let record = try await MCPConsentRequest.query(on: req.db)
                .filter(\.$tokenHash == tokenHash).first(),
            record.expiresAt > Date()
        else {
            throw Abort(
                .badRequest,
                reason: "This authorization request has expired or already been used. "
                    + "Restart the connection to try again.")
        }
        // Single-use: atomically burn the consent token before any further work
        // and only proceed if this submit won the burn — a concurrent replay
        // loses the conditional UPDATE and is rejected.
        guard
            try await Self.burnConsumable(
                on: req.db, table: MCPConsentRequest.schema, hashColumn: "token_hash", hash: tokenHash)
        else {
            throw Abort(
                .badRequest,
                reason: "This authorization request has expired or already been used. "
                    + "Restart the connection to try again.")
        }

        // Re-validate the client/redirect from the frozen record (defense in
        // depth — the record is server-authored, but a stale client edit could
        // have dropped the redirect URI between GET and POST).
        guard
            let client = try await MCPOAuthClient.query(on: req.db)
                .filter(\.$clientID == record.clientID).first(),
            client.redirectURIs.contains(record.redirectURI)
        else {
            throw Abort(.badRequest, reason: "Invalid client or redirect_uri.")
        }
        let state = record.state
        // The surface is fixed by the frozen consent record's scope (its
        // namespace identifies content vs admin), so the role re-check uses the
        // right gate and every redirect self-identifies with the right RFC 9207
        // `iss`.
        let surface = surfaceForScope(record.scope, req: req)
        guard form.decision == "authorize" else {
            return redirect(
                record.redirectURI, error: "access_denied", state: state, issuer: surface.issuer)
        }
        // Re-check the role from the bound user at submit time: a downgrade
        // between rendering the consent screen and submitting it must stop here.
        guard
            let user = try await APIUser.find(record.userID, on: req.db),
            try await surface.permits(user, db: req.db)
        else {
            throw Abort(.forbidden, reason: "Only \(surface.permittedRoleLabel) may authorize agents.")
        }
        let scopes = resolveScopes(record.scope, ceiling: surface.scopeCeiling)
        guard !scopes.isEmpty, !record.codeChallenge.isEmpty, record.codeChallengeMethod == "S256" else {
            return redirect(
                record.redirectURI, error: "invalid_request", state: state, issuer: surface.issuer)
        }

        let code = Self.randomToken()
        let authCode = MCPAuthorizationCode(
            codeHash: sha256HexDigest(code),
            clientID: client.clientID,
            userID: record.userID,
            redirectURI: record.redirectURI,
            codeChallenge: record.codeChallenge,
            codeChallengeMethod: record.codeChallengeMethod,
            scope: scopes.sorted().joined(separator: " "),
            expiresAt: Date().addingTimeInterval(60))
        try await authCode.save(on: req.db)
        // The human consenting to an agent is the single most security-sensitive
        // event in the MCP flow — record it (the headline "I authorized MCP and
        // saw nothing in the audit log" gap).
        await AuditLogger.record(
            action: .mcpConsentGranted,
            targetType: .user,
            targetID: record.userID.uuidString,
            metadata: [
                "username": user.username,
                "client_id": client.clientID,
                "client_name": client.name,
                "scope": authCode.scope,
                "redirect_host": URLComponents(string: record.redirectURI)?.host ?? record.redirectURI,
            ],
            actorOverride: user,
            on: req
        )
        return redirect(record.redirectURI, code: code, state: state, issuer: surface.issuer)
    }

    // MARK: - Consent-flow helpers

    private func renderConsent(_ req: Request, context: ConsentContext) async throws -> Response {
        let view = try await req.view.render("oauth-consent", context)
        let response = try await view.encodeResponse(for: req)
        // The consent page embeds the single-use consent token; keep it out of
        // any shared/proxy cache.
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    /// Keeps only requested scope strings that the target surface advertises for
    /// the current mode (the ceiling), dropping anything else.  An empty/absent
    /// request defaults to the full ceiling.  Scope strings are kept untyped so
    /// the same flow serves both the content (`content:*`) and admin
    /// (`diagnostics:*`) vocabularies.
    private func resolveScopes(_ scope: String?, ceiling: Set<String>) -> Set<String> {
        guard let scope, !scope.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ceiling
        }
        let requested = Set(scope.split(separator: " ").map(String.init))
        return requested.intersection(ceiling)
    }

    /// Display order for the consent screen's scope list.
    static let scopeDisplayOrder: [String] = [
        ContentScope.read.rawValue, ContentScope.write.rawValue, DiagnosticScope.read.rawValue,
    ]

    private static func scopeLabel(_ scope: String) -> String {
        switch scope {
        case ContentScope.read.rawValue: return "Read course content (assignments, etc.)"
        case ContentScope.write.rawValue: return "Create and edit course content"
        case DiagnosticScope.read.rawValue: return "Read server diagnostics and operational status"
        default: return scope
        }
    }

    /// 303 redirect carrying `code` + `state` + `iss` query items (empty ones
    /// dropped). `iss` is the RFC 9207 issuer-identification parameter
    /// (SEP-2468 in the MCP 2026-07-28 revision): the authorization server
    /// self-identifies on every authorization response so a client can detect
    /// mix-up attacks. The value is the resolved surface's issuer — the same
    /// identifier the minted access token's `iss` claim will carry.
    private func redirect(_ uri: String, code: String, state: String, issuer: String) -> Response {
        redirect(uri, items: [("code", code), ("state", state), ("iss", issuer)])
    }

    /// 303 redirect carrying `error` + `state` + `iss` query items — RFC 9207
    /// requires `iss` on error responses too.
    private func redirect(_ uri: String, error: String, state: String, issuer: String) -> Response {
        redirect(uri, items: [("error", error), ("state", state), ("iss", issuer)])
    }

    private func redirect(_ uri: String, items: [(String, String)]) -> Response {
        var components = URLComponents(string: uri)
        var queryItems = components?.queryItems ?? []
        for (name, value) in items where !value.isEmpty {
            queryItems.append(URLQueryItem(name: name, value: value))
        }
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        let target = components?.url?.absoluteString ?? uri
        let response = Response(status: .seeOther)
        response.headers.replaceOrAdd(name: .location, value: target)
        return response
    }
}

// MARK: - Consent form / view context

private struct ConsentForm: Content {
    /// The single-use consent token from the rendered form; everything else
    /// (client, redirect, scope, PKCE, the consenting user) is frozen in the
    /// server-side `MCPConsentRequest` keyed by this token.
    var requestToken: String
    var decision: String

    enum CodingKeys: String, CodingKey {
        case requestToken = "request_token"
        case decision
    }
}

private struct ConsentContext: Encodable {
    let currentUser: CurrentUserContext?
    let clientName: String
    let scopeLabels: [String]
    /// Host portion of the redirect URI, shown prominently so the human can spot
    /// an unexpected destination (DCR client names are self-asserted).
    let redirectHost: String
    /// True when the user has never approved this client — drives a warning.
    let firstTimeApproval: Bool
    let notPermitted: Bool
    /// Role label for the not-permitted message ("instructors and admins" for the
    /// content surface, "admins" for admin diagnostics).
    let permittedRoleLabel: String
    /// What the agent would be authorized to do, for the not-permitted message
    /// ("author course content" vs "read server diagnostics").
    let purposeLabel: String
    /// Single-use consent token embedded in the form; nil for the not-permitted
    /// view (no submittable form is shown).
    let requestToken: String?
}
