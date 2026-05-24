// APIServer/Routes/Web/AuthRoutes.swift
//
// Authentication routes — all public (no session required).
//
// Error handling uses Post/Redirect/Get: on validation failure,
// POST handlers redirect back to the form with an ?error= query param.
// This prevents form resubmission on refresh and avoids Leaf rendering
// inside the POST handler (which simplifies testing).
//
//   GET  /login      → login.leaf (local form and/or SSO button by AUTH_MODE)
//   POST /login      → verify local credentials, set session, redirect to / (local/dual only)
//   GET  /register   → register.leaf (local/dual only)
//   POST /register   → create account (first user becomes admin), redirect to / (local/dual only)
//   POST /logout     → clear session, redirect to /login

import Core
import Fluent
import Foundation
import Vapor

struct AuthRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // Tight per-endpoint body limits on the public auth POSTs: login and
        // register only carry two short form fields, so 8 KB is generous and
        // closes the OOM vector that the 10 MB global default leaves open.
        routes.get("login", use: loginForm)
        routes.on(.POST, "login", body: .collect(maxSize: "8kb"), use: login)
        routes.get("register", use: registerForm)
        routes.on(.POST, "register", body: .collect(maxSize: "8kb"), use: register)
        routes.post("logout", use: logout)
    }

    // MARK: - GET /login

    @Sendable
    func loginForm(req: Request) async throws -> Response {
        // If already logged in, skip the form.
        if req.auth.has(APIUser.self) {
            return req.redirect(to: "/")
        }
        let error = req.query[String.self, at: "error"]
        let loggedOut = req.query[String.self, at: "loggedout"] != nil
        let authMode = req.application.authMode

        // In SSO-only mode, start the SSO flow immediately so users do not
        // need to click a button. Keep error states on /login so the message
        // can be shown instead of creating a redirect loop. A just-logged-out
        // user is held on the form too — otherwise logout would bounce them
        // straight back into SSO and silently re-authenticate, defeating the
        // whole point of the button.
        if authMode == .sso, error == nil, !loggedOut {
            return req.redirect(to: "/auth/sso/start")
        }

        return try await req.view.render(
            "login",
            LoginContext(
                error: error,
                loggedOut: loggedOut,
                showLocalLogin: authMode != .sso,
                showRegisterLink: authMode != .sso,
                showSSOLogin: authMode != .local
            )
        ).encodeResponse(for: req)
    }

    // MARK: - POST /login

    @Sendable
    func login(req: Request) async throws -> Response {
        if req.application.authMode == .sso {
            throw Abort(.notFound)
        }

        let body = try req.content.decode(LoginBody.self)
        let rateConfig = req.application.loginRateLimitConfiguration
        let attemptStore = req.application.loginAttemptStore
        let usernameKey = body.username.lowercased()
        let now = Date()

        if rateConfig.enabled {
            let locked = await attemptStore.isLocked(
                username: usernameKey,
                now: now,
                windowSeconds: rateConfig.lockoutWindowSeconds,
                threshold: rateConfig.lockoutThreshold
            )
            if locked {
                req.logger.warning("Login locked for user '\(usernameKey)' (too many failures)")
                await AuditLogger.record(
                    action: .loginLocked,
                    targetType: .auth,
                    metadata: ["username": usernameKey],
                    actorUsernameOverride: usernameKey,
                    on: req
                )
                return req.redirect(to: "/login?error=locked")
            }
        }

        guard
            let user = try await req.application.authProvider.authenticate(
                username: body.username,
                password: body.password,
                on: req
            )
        else {
            if rateConfig.enabled {
                await attemptStore.recordFailure(
                    username: usernameKey,
                    now: now,
                    windowSeconds: rateConfig.lockoutWindowSeconds
                )
            }
            await AuditLogger.record(
                action: .loginFailure,
                targetType: .auth,
                metadata: ["username": usernameKey],
                actorUsernameOverride: usernameKey,
                on: req
            )
            return req.redirect(to: "/login?error=invalid")
        }

        if rateConfig.enabled {
            await attemptStore.clearFailures(username: usernameKey)
        }
        user.lastLoginAt = now
        user.lastSeenAt = now
        try await user.save(on: req.db)

        req.auth.login(user)
        req.session.authenticate(user)
        await AuditLogger.record(
            action: .loginSuccess,
            targetType: .auth,
            targetID: user.id?.uuidString,
            metadata: ["username": user.username],
            actorOverride: user,
            on: req
        )
        // Resolve any pending pre-enrollments for this username (the
        // bulk-enroll path may have queued course enrollments before
        // this user existed).  Errors are swallowed inside the
        // resolver — they cannot block this login.
        await resolvePendingPreEnrollments(for: user, db: req.db, logger: req.logger)
        return try await postLoginRedirect(for: user, req: req)
    }

    // MARK: - GET /register

    @Sendable
    func registerForm(req: Request) async throws -> Response {
        if req.application.authMode == .sso {
            throw Abort(.notFound)
        }
        if req.auth.has(APIUser.self) {
            return req.redirect(to: "/")
        }
        let error = req.query[String.self, at: "error"]
        return try await req.view.render(
            "register",
            RegisterContext(error: error)
        ).encodeResponse(for: req)
    }

    // MARK: - POST /register

    @Sendable
    func register(req: Request) async throws -> Response {
        if req.application.authMode == .sso {
            throw Abort(.notFound)
        }
        let body = try req.content.decode(RegisterBody.self)

        // Basic length validation.
        guard body.username.count >= 3 else {
            return req.redirect(to: "/register?error=username_short")
        }
        guard body.password.count >= 8 else {
            return req.redirect(to: "/register?error=password_short")
        }

        // Username uniqueness check.
        let existing = try await APIUser.query(on: req.db)
            .filter(\.$username == body.username)
            .count()
        guard existing == 0 else {
            return req.redirect(to: "/register?error=taken")
        }

        // First-user bootstrap: if the table is empty, the registrant becomes admin.
        // Note: two truly-simultaneous first registrations could both see count == 0.
        // This is acceptable for a single-server classroom deployment.
        let totalUsers = try await APIUser.query(on: req.db).count()
        let role = totalUsers == 0 ? "admin" : "student"

        let hash = try await req.password.async.hash(body.password)
        let user = APIUser(username: body.username, passwordHash: hash, role: role)
        try await user.save(on: req.db)

        req.auth.login(user)
        req.session.authenticate(user)
        return try await postLoginRedirect(for: user, req: req)
    }

    // MARK: - POST /logout

    @Sendable
    func logout(req: Request) async throws -> Response {
        // The inactivity watchdog (idle-logout.js) posts `?reason=timeout` so the
        // login page can explain why the user was signed out. A manual click on
        // the nav button carries no reason and gets the neutral "signed out"
        // confirmation. Either way the user lands back on /login (never silently
        // re-authenticated) so it's obvious the session ended.
        let isTimeout = req.query[String.self, at: "reason"] == "timeout"
        let returnPath = isTimeout ? "/login?error=timeout" : "/login?loggedout=1"

        // Capture any SSO tokens stashed at login before tearing the session
        // down — they're needed below to revoke at the IdP and to build the
        // end-session redirect.
        let accessToken = req.session.data["oidc_access_token"]
        let refreshToken = req.session.data["oidc_refresh_token"]
        let idToken = req.session.data["oidc_id_token"]

        // Destroy the server-side session, not just the auth marker.
        // `destroy()` deletes the persisted Fluent session row and expires the
        // cookie (Set-Cookie with a past date); `unauthenticate()` alone left
        // a (markerless) row in place and re-issued a live session cookie, so
        // the cookie only really went away when the browser was closed.
        req.auth.logout(APIUser.self)
        req.session.destroy()

        // Mark the next sign-in for forced IdP re-authentication. Duo keeps its
        // own SSO session alive, so without this an explicit logout is silently
        // undone the moment the user hits any protected page (it re-auths with
        // no prompt). `/auth/sso/start` consumes this marker and adds
        // `prompt=login`. Set on whichever redirect we return below.
        let reauthCookie = chickadeeReauthMarkerCookie(
            isSecure: req.application.securityConfiguration.sessionCookieSecure
        )

        let oidcConfig = req.application.oidcConfig

        // Revoke any issued OAuth tokens at the IdP. Runs concurrently and is
        // bounded by a deadline so a slow/hung IdP can't keep the task alive
        // indefinitely; the user-facing redirect still happens immediately.
        if let endpoint = oidcConfig?.discovery.revocationEndpoint,
            let config = oidcConfig
        {
            let app = req.application
            let logger = req.logger
            let tokensToRevoke: [(token: String, hint: String)] = [
                accessToken.map { ($0, "access_token") },
                refreshToken.map { ($0, "refresh_token") },
            ].compactMap { $0 }

            if !tokensToRevoke.isEmpty {
                Task { [tokensToRevoke] in
                    await revokeTokensInParallel(
                        tokens: tokensToRevoke,
                        endpoint: endpoint,
                        config: config,
                        app: app,
                        logger: logger,
                        deadlineSeconds: 5
                    )
                }
            }
        }

        // Redirect to the IdP's end-session endpoint when available.
        // This terminates the IdP SSO session so the user can't silently re-authenticate.
        if let endpoint = oidcConfig?.discovery.endSessionEndpoint {
            var components = URLComponents(string: endpoint)
            var items: [URLQueryItem] = []
            if let hint = idToken {
                items.append(URLQueryItem(name: "id_token_hint", value: hint))
            }
            // post_logout_redirect_uri must be an absolute URL; only set it when we know the base.
            if let base = req.application.securityConfiguration.publicBaseURL?.absoluteString
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            {
                items.append(URLQueryItem(name: "post_logout_redirect_uri", value: base + returnPath))
            }
            if !items.isEmpty {
                components?.queryItems = items
            }
            if let url = components?.url?.absoluteString {
                let response = req.redirect(to: url)
                response.cookies[reauthMarkerCookieName] = reauthCookie
                return response
            }
        }

        let response = req.redirect(to: returnPath)
        response.cookies[reauthMarkerCookieName] = reauthCookie
        return response
    }
}

// MARK: - Token revocation helpers

/// Revokes all supplied tokens concurrently, bounded by `deadlineSeconds`.
/// Per-token failures and the overall deadline are logged; the function
/// always returns normally so callers can fire-and-forget without a leak.
private func revokeTokensInParallel(
    tokens: [(token: String, hint: String)],
    endpoint: String,
    config: OIDCConfiguration,
    app: Application,
    logger: Logger,
    deadlineSeconds: Int
) async {
    await withTaskGroup(of: Bool.self) { group in
        // Outer race: all revocations vs. a deadline timer.
        group.addTask {
            await withTaskGroup(of: Void.self) { revocations in
                for entry in tokens {
                    revocations.addTask {
                        do {
                            try await revokeToken(
                                token: entry.token,
                                tokenTypeHint: entry.hint,
                                endpoint: endpoint,
                                config: config,
                                app: app,
                                logger: logger
                            )
                        } catch {
                            logger.warning("Token revocation failed (non-fatal): \(error)")
                        }
                    }
                }
            }
            return true
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(deadlineSeconds) * 1_000_000_000)
            return false
        }
        if let completedNormally = await group.next(), !completedNormally {
            logger.warning("Token revocation deadline (\(deadlineSeconds)s) reached; cancelling remaining work")
        }
        group.cancelAll()
    }
}

/// Calls the IdP's RFC 7009 revocation endpoint for the given token.
/// Failures are non-fatal — the caller is responsible for logging them.
private func revokeToken(
    token: String,
    tokenTypeHint: String,
    endpoint: String,
    config: OIDCConfiguration,
    app: Application,
    logger: Logger
) async throws {
    let response = try await app.client.post(URI(string: endpoint)) { tokenReq in
        tokenReq.headers.contentType = .urlEncodedForm
        tokenReq.headers.basicAuthorization = BasicAuthorization(
            username: config.clientID,
            password: config.clientSecret
        )
        try tokenReq.content.encode(
            ["token": token, "token_type_hint": tokenTypeHint] as [String: String],
            as: .urlEncodedForm
        )
    }
    if response.status != .ok && response.status != .noContent {
        logger.warning("Token revocation returned HTTP \(response.status.code)")
    }
}

// MARK: - Post-login redirect helper

/// Called after any successful login (local or SSO).
/// - Auto-enrolls the user in every course with enrollmentMode == .auto.
/// - If the user still has no enrollments and open-enrollment courses exist, redirect to /enroll.
/// - Otherwise redirect to /.
func postLoginRedirect(for user: APIUser, req: Request) async throws -> Response {
    // Honor a pending OAuth authorize request the user was bounced to /login
    // from (MCP browser flow).  Only same-origin paths are accepted, so this
    // can't be abused as an open redirect.
    if let returnTo = req.session.data[MCPOAuthRoutes.returnToSessionKey] {
        req.session.data[MCPOAuthRoutes.returnToSessionKey] = nil
        if returnTo.hasPrefix("/"), !returnTo.hasPrefix("//") {
            return req.redirect(to: returnTo)
        }
    }
    guard let userID = user.id else { return req.redirect(to: "/") }

    let allCourses = try await APICourse.query(on: req.db)
        .filter(\.$isArchived == false)
        .all()

    // Auto-enroll in every .auto course the user is not already in.
    let autoCourses = allCourses.filter { $0.enrollmentMode == .auto }
    for course in autoCourses {
        guard let courseID = course.id else { continue }
        let existing = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .count()
        if existing == 0 {
            let enrollment = APICourseEnrollment(userID: userID, courseID: courseID)
            try await enrollment.save(on: req.db)
        }
    }

    let enrollmentCount = try await APICourseEnrollment.query(on: req.db)
        .filter(\.$userID == userID)
        .count()

    if enrollmentCount == 0 {
        let hasOpenCourses = allCourses.contains { $0.enrollmentMode == .open }
        if hasOpenCourses {
            return req.redirect(to: "/enroll")
        }
    }

    return req.redirect(to: "/")
}

// MARK: - Request body types

private struct LoginBody: Content {
    var username: String
    var password: String
}

private struct RegisterBody: Content {
    var username: String
    var password: String
}

// MARK: - View context types

private struct LoginContext: Encodable {
    var error: String?
    var loggedOut: Bool
    var showLocalLogin: Bool
    var showRegisterLink: Bool
    var showSSOLogin: Bool

    init(
        error: String? = nil,
        loggedOut: Bool = false,
        showLocalLogin: Bool,
        showRegisterLink: Bool,
        showSSOLogin: Bool
    ) {
        self.error = error
        self.loggedOut = loggedOut
        self.showLocalLogin = showLocalLogin
        self.showRegisterLink = showRegisterLink
        self.showSSOLogin = showSSOLogin
    }
}

private struct RegisterContext: Encodable {
    var error: String?
    init(error: String? = nil) { self.error = error }
}
