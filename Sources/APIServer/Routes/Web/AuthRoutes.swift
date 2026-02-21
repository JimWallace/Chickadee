// APIServer/Routes/Web/AuthRoutes.swift
//
// Authentication routes — all public (no session required).
//
// Error handling uses Post/Redirect/Get: on validation failure,
// POST handlers redirect back to the form with an ?error= query param.
// This prevents form resubmission on refresh and avoids Leaf rendering
// inside the POST handler (which simplifies testing).
//
//   GET  /login      → login.leaf
//   POST /login      → verify credentials, set session, redirect to /
//   GET  /register   → register.leaf
//   POST /register   → create account (first user becomes admin), redirect to /
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
        return try await req.view.render("login", LoginContext(error: error)).encodeResponse(for: req)
    }

    // MARK: - POST /login

    @Sendable
    func login(req: Request) async throws -> Response {
        let body = try req.content.decode(LoginBody.self)

        guard let user = try await APIUser.query(on: req.db)
            .filter(\.$username == body.username)
            .first()
        else {
            return req.redirect(to: "/login?error=invalid")
        }

        // Run BCrypt on a thread-pool thread — don't block the event loop.
        let verified = try await req.password.async.verify(body.password,
                                                           created: user.passwordHash)
        guard verified else {
            return req.redirect(to: "/login?error=invalid")
        }

        req.auth.login(user)
        req.session.authenticate(user)
        return req.redirect(to: "/")
    }

    // MARK: - GET /register

    @Sendable
    func registerForm(req: Request) async throws -> Response {
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
        return req.redirect(to: "/")
    }

    // MARK: - POST /logout

    @Sendable
    func logout(req: Request) async throws -> Response {
        req.auth.logout(APIUser.self)
        req.session.unauthenticate(APIUser.self)
        return req.redirect(to: "/login")
    }
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
    init(error: String? = nil) { self.error = error }
}

private struct RegisterContext: Encodable {
    var error: String?
    init(error: String? = nil) { self.error = error }
}
