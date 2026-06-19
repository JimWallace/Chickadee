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

        // Relax `form-action` so the Re-authorize form on THIS page can POST →
        // 303 to the LMS origin. The browser enforces form-action using the CSP
        // of the page that *contains* the form, so it must be set here (when
        // rendering the page), not on the POST response — matching the MCP
        // consent page pattern (MCPOAuthRoutes.authorizeForm).
        if let appCreds {
            SecurityHeadersMiddleware.allowFormAction(lmsOrigin(appCreds.baseURL), on: req)
        }

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

        // CSRF marker. D2L matches `x_target` against the registered Trusted
        // URL strictly (a parent path does NOT cover a sub-path, and a query
        // string breaks the match), so we can't echo a state token back through
        // the callback URL. Instead the callback is bound to an authorize that
        // *this* admin session initiated.
        // (The form-action CSP that lets this POST 303 cross-origin to the LMS
        // is set on the page render in brightspacePage — the browser enforces
        // form-action using the CSP of the page that contains the form, not the
        // POST response, so relaxing it here would be too late.)
        req.session.data["bs_valence_pending"] = "1"

        // `x_target` must equal the registered Trusted URL exactly — no query.
        return req.redirect(to: appCreds.valenceAuthURL(callback: callback))
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

        // CSRF: the callback must follow an authorize that this same admin
        // session started (see brightspaceAuthorize — D2L's strict Trusted-URL
        // match prevents echoing a state token in the callback URL).
        let pending = req.session.data["bs_valence_pending"]
        req.session.data["bs_valence_pending"] = nil
        guard pending == "1" else {
            req.logger.warning("BrightSpace authorize: no pending authorize in session (CSRF or stale)")
            return failRedirect("Authorization didn't originate here — please click Authorize again.")
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

    // MARK: - POST /admin/brightspace/set-credentials

    /// Stores a User ID/Key pasted in by an admin (e.g. harvested from UW's
    /// `d2l-api-cred.fast.uwaterloo.ca` credential service, where the app's
    /// Trusted URL is the central harvester rather than this server's callback,
    /// so the in-browser authorize flow can't run). Verifies the pair against
    /// D2L before persisting, then rebuilds the live client — same effect as a
    /// successful authorize, no env change or restart.
    @Sendable
    func brightspaceSetCredentials(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)

        struct CredentialForm: Content {
            let userID: String
            let userKey: String
        }
        let form = try req.content.decode(CredentialForm.self)
        let userID = form.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let userKey = form.userKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty, !userKey.isEmpty else {
            req.session.data["bs_flash_error"] = "Both User ID and User Key are required."
            return req.redirect(to: "/admin/brightspace")
        }
        guard let appCreds = req.application.brightSpaceAppCredentials else {
            req.session.data["bs_flash_error"] = "BrightSpace is not configured on this server."
            return req.redirect(to: "/admin/brightspace")
        }

        // Verify before persisting so a bad paste fails loudly rather than
        // silently breaking grade sync.
        let config = BrightSpaceSyncConfig(app: appCreds, userID: userID, userKey: userKey)
        let candidate = BrightSpaceAPIClient(config: config)
        let who: BrightSpaceWhoAmI
        do {
            who = try await candidate.whoami(on: req.application)
        } catch {
            req.logger.warning(
                "BrightSpace set-credentials: whoami verification failed: \(error.localizedDescription)")
            req.session.data["bs_flash_error"] =
                "Could not verify those credentials against D2L: \(error.localizedDescription)"
            return req.redirect(to: "/admin/brightspace")
        }

        let identity = who.uniqueName.isEmpty ? who.displayName : "\(who.displayName) (\(who.uniqueName))"
        try await BrightSpaceCredentialStore.save(
            valenceUserID: userID,
            valenceUserKey: userKey,
            identityName: identity,
            capturedByUserID: user.id,
            on: req.db
        )
        req.application.brightSpaceSyncConfig = config
        req.application.brightSpaceClient = candidate
        req.logger.info("BrightSpace credentials set manually by \(user.username) as \(identity)")

        req.session.data["bs_flash_success"] = "BrightSpace credentials saved — connected as \(identity)."
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

    /// `scheme://host[:port]` of the LMS base URL, for the `form-action`
    /// CSP allow-list. Nil when the base URL can't be parsed.
    func lmsOrigin(_ baseURL: String) -> String? {
        guard let url = URL(string: baseURL), let scheme = url.scheme, let host = url.host else {
            return nil
        }
        return "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
    }

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
