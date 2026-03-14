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

import Vapor
import Fluent

struct AuthRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("login",     use: loginForm)
        routes.post("login",    use: login)
        routes.get("register",  use: registerForm)
        routes.post("register", use: register)
        routes.post("logout",   use: logout)
    }

    // MARK: - GET /login

    @Sendable
    func loginForm(req: Request) async throws -> Response {
        // If already logged in, skip the form.
        if req.auth.has(APIUser.self) {
            return req.redirect(to: "/")
        }
        let error = req.query[String.self, at: "error"]
        let authMode = req.application.authMode

        // In SSO-only mode, start the SSO flow immediately so users do not
        // need to click a button. Keep error states on /login so the message
        // can be shown instead of creating a redirect loop.
        if authMode == .sso, error == nil {
            return req.redirect(to: "/auth/sso/start")
        }

        return try await req.view.render(
            "login",
            LoginContext(
                error: error,
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

        guard let user = try await req.application.authProvider.authenticate(
            username: body.username,
            password: body.password,
            on: req
        ) else {
            return req.redirect(to: "/login?error=invalid")
        }

        user.lastLoginAt = Date()
        try await user.save(on: req.db)

        req.auth.login(user)
        req.session.authenticate(user)
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
        return try await req.view.render("register",
            RegisterContext(error: error)).encodeResponse(for: req)
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
        req.auth.logout(APIUser.self)
        req.session.unauthenticate(APIUser.self)
        return req.redirect(to: "/login")
    }
}

// MARK: - Post-login redirect helper

/// Called after any successful login (local or SSO).
/// - If the user has no enrollments and exactly one active course exists, auto-enroll them silently.
/// - If the user has no enrollments and multiple courses exist, redirect to /enroll.
/// - Otherwise redirect to /.
func postLoginRedirect(for user: APIUser, req: Request) async throws -> Response {
    guard let userID = user.id else { return req.redirect(to: "/") }

    let enrollmentCount = try await APICourseEnrollment.query(on: req.db)
        .filter(\.$userID == userID)
        .count()

    if enrollmentCount == 0 {
        let courses = try await APICourse.query(on: req.db)
            .filter(\.$isArchived == false)
            .all()

        if courses.count == 1, let course = courses.first, let courseID = course.id {
            // Exactly one active course: silently auto-enroll the user.
            let enrollment = APICourseEnrollment(userID: userID, courseID: courseID)
            try? await enrollment.save(on: req.db)
        } else if courses.count > 1 {
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
    var showLocalLogin: Bool
    var showRegisterLink: Bool
    var showSSOLogin: Bool

    init(
        error: String? = nil,
        showLocalLogin: Bool,
        showRegisterLink: Bool,
        showSSOLogin: Bool
    ) {
        self.error = error
        self.showLocalLogin = showLocalLogin
        self.showRegisterLink = showRegisterLink
        self.showSSOLogin = showSSOLogin
    }
}

private struct RegisterContext: Encodable {
    var error: String?
    init(error: String? = nil) { self.error = error }
}
