// APIServer/Routes/Web/AdminRoutes+BrightSpace.swift
//
// Admin "Authorize BrightSpace" flow — the server-side D2L Valence handshake
// that captures the deployment's service-account user key without an env change
// + restart. This is the in-app counterpart to scripts/brightspace-valence-auth.py.
//
// Single service-account model: the app creds (URL/App ID/App Key) stay env-only;
// this page captures + stores the *user* key (single active row), which takes
// precedence over BRIGHTSPACE_USER_KEY in env. The captured key rebuilds the
// live client so grade sync picks it up within one sweep (≤60 s).
//
//   GET  /admin/brightspace                    → status + authorize button
//   POST /admin/brightspace/authorize          → redirect to D2L (signed Valence URL)
//   GET  /admin/brightspace/valence-callback    → capture x_a/x_b, verify, store, rebuild
//   POST /admin/brightspace/clear              → drop stored key (revert to env/off)
//   POST /admin/brightspace/test               → whoami connection test
//
// The callback is a top-level GET redirect from D2L: SameSite=Lax sends the
// admin session cookie (and SameSite=None on the HTTPS prod host), so it stays
// admin-gated. CSRF for the round-trip rides a `state` token in the session,
// mirroring SSOAuthRoutes.

import Core
import Fluent
import Foundation
import Vapor

extension AdminRoutes {

    // MARK: - GET /admin/brightspace

    @Sendable
    func brightspacePage(req: Request) async throws -> View {
        let appCreds = req.application.brightSpaceAppCredentials
        let authorized = req.application.brightSpaceClient != nil
        let stored = try await BrightSpaceCredentialStore.load(on: req.db)

        let keySource: String
        if stored != nil {
            keySource = "authorized"
        } else if authorized {
            keySource = "env"
        } else {
            keySource = "none"
        }

        // One-shot session flash (set by the action handlers below).
        let flashSuccess = req.session.data["bs_flash_success"]
        let flashError = req.session.data["bs_flash_error"]
        req.session.data["bs_flash_success"] = nil
        req.session.data["bs_flash_error"] = nil

        let capturedAt = stored?.capturedAt.map { waterlooDateTimeFormatter().string(from: $0) }

        let ctx = AdminBrightspaceContext(
            currentUser: req.currentUserContext,
            activeAdminTab: "brightspace",
            configured: appCreds != nil,
            authorized: authorized,
            baseURL: appCreds?.baseURL,
            identityName: stored?.identityName,
            keySource: keySource,
            callbackURL: brightspaceCallbackURL(req),
            publicBaseURLSet: req.application.securityConfiguration.publicBaseURL != nil,
            capturedAt: capturedAt,
            flashSuccess: flashSuccess,
            flashError: flashError
        )
        return try await req.view.render("admin-brightspace", ctx)
    }

    // MARK: - POST /admin/brightspace/authorize

    @Sendable
    func brightspaceAuthorize(req: Request) async throws -> Response {
        guard let appCreds = req.application.brightSpaceAppCredentials else {
            req.session.data["bs_flash_error"] = "BrightSpace is not configured on this server."
            return req.redirect(to: "/admin/brightspace")
        }
        guard let callback = brightspaceCallbackURL(req) else {
            req.session.data["bs_flash_error"] =
                "PUBLIC_BASE_URL is not set, so the redirect callback URL can't be built."
            return req.redirect(to: "/admin/brightspace")
        }

        // CSRF state for the Valence round-trip (validated on the callback).
        var rng = SystemRandomNumberGenerator()
        let stateBytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let state = Data(stateBytes).base64URLEncodedString()
        req.session.data["bs_valence_state"] = state

        let callbackWithState = callback + "?state=" + state
        return req.redirect(to: appCreds.valenceAuthURL(callback: callbackWithState))
    }

    // MARK: - GET /admin/brightspace/valence-callback

    @Sendable
    func brightspaceValenceCallback(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)

        func failRedirect(_ message: String) -> Response {
            req.session.data["bs_flash_error"] = message
            let response = req.redirect(to: "/admin/brightspace")
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return response
        }

        // CSRF: the returned state must match what we stored before redirecting.
        let returnedState = req.query[String.self, at: "state"] ?? ""
        let storedState = req.session.data["bs_valence_state"] ?? ""
        req.session.data["bs_valence_state"] = nil
        guard !returnedState.isEmpty, returnedState == storedState else {
            req.logger.warning("BrightSpace authorize: state mismatch (possible CSRF or stale session)")
            return failRedirect("Authorization failed: state mismatch — please retry.")
        }

        let userID = req.query[String.self, at: "x_a"] ?? ""
        let userKey = req.query[String.self, at: "x_b"] ?? ""
        guard !userID.isEmpty, !userKey.isEmpty else {
            return failRedirect("Authorization failed: D2L did not return a user key.")
        }
        guard let appCreds = req.application.brightSpaceAppCredentials else {
            return failRedirect("BrightSpace is not configured on this server.")
        }

        // Verify the captured pair against D2L before persisting anything.
        let config = BrightSpaceSyncConfig(app: appCreds, userID: userID, userKey: userKey)
        let candidate = BrightSpaceAPIClient(config: config)
        let who: BrightSpaceWhoAmI
        do {
            who = try await candidate.whoami(on: req.application)
        } catch {
            req.logger.warning("BrightSpace authorize: whoami verification failed: \(error.localizedDescription)")
            return failRedirect("Authorization failed: the captured key could not be verified (whoami).")
        }

        let identity = who.uniqueName.isEmpty ? who.displayName : "\(who.displayName) (\(who.uniqueName))"
        try await BrightSpaceCredentialStore.save(
            valenceUserID: userID,
            valenceUserKey: userKey,
            identityName: identity,
            capturedByUserID: user.id,
            on: req.db
        )
        // Rebuild the live client so the sweep uses the new key without a restart.
        req.application.brightSpaceSyncConfig = config
        req.application.brightSpaceClient = candidate
        req.logger.info("BrightSpace authorized by \(user.username) as \(identity)")

        req.session.data["bs_flash_success"] = "BrightSpace authorized as \(identity)."
        let response = req.redirect(to: "/admin/brightspace")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }

    // MARK: - POST /admin/brightspace/clear

    @Sendable
    func brightspaceClearAuthorization(req: Request) async throws -> Response {
        try await BrightSpaceCredentialStore.clear(on: req.db)
        // Fall back to an env-provided user key if one exists; otherwise disable.
        if let envConfig = req.application.appConfig.brightspace {
            req.application.brightSpaceSyncConfig = envConfig
            req.application.brightSpaceClient = BrightSpaceAPIClient(config: envConfig)
            req.session.data["bs_flash_success"] =
                "Authorization cleared — reverted to the BRIGHTSPACE_USER_KEY from env."
        } else {
            req.application.brightSpaceSyncConfig = nil
            req.application.brightSpaceClient = nil
            req.session.data["bs_flash_success"] = "Authorization cleared — grade sync is now disabled."
        }
        return req.redirect(to: "/admin/brightspace")
    }

    // MARK: - POST /admin/brightspace/test

    @Sendable
    func brightspaceTestConnection(req: Request) async throws -> Response {
        guard let client = req.application.brightSpaceClient else {
            req.session.data["bs_flash_error"] = "Not authorized yet — nothing to test."
            return req.redirect(to: "/admin/brightspace")
        }
        do {
            let who = try await client.whoami(on: req.application)
            let label = who.uniqueName.isEmpty ? who.displayName : "\(who.displayName) (\(who.uniqueName))"
            req.session.data["bs_flash_success"] = "Connected as \(label)."
        } catch {
            req.session.data["bs_flash_error"] = "Connection failed: \(error.localizedDescription)"
        }
        return req.redirect(to: "/admin/brightspace")
    }

    // MARK: - Helpers

    /// The absolute Trusted-URL callback D2L redirects back to, derived from
    /// `PUBLIC_BASE_URL`. Nil when the base URL isn't configured.
    func brightspaceCallbackURL(_ req: Request) -> String? {
        guard let base = req.application.securityConfiguration.publicBaseURL?.absoluteString else {
            return nil
        }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return trimmed + "/admin/brightspace/valence-callback"
    }
}

/// Render context for `admin-brightspace.leaf`.
struct AdminBrightspaceContext: Encodable {
    let currentUser: CurrentUserContext?
    let activeAdminTab: String
    let configured: Bool
    let authorized: Bool
    let baseURL: String?
    let identityName: String?
    /// "authorized" (stored key), "env" (BRIGHTSPACE_USER_KEY), or "none".
    let keySource: String
    let callbackURL: String?
    let publicBaseURLSet: Bool
    let capturedAt: String?
    let flashSuccess: String?
    let flashError: String?
}
