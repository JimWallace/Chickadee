// Tests/APITests/Auth/LoginLockoutRouteTests.swift
//
// The brute-force protection of the public auth routes, end to end through
// the HTTP layer. `LoginRateLimitTests` checks `LoginAttemptService` alone;
// this suite checks what a client sees: the per-IP 429 of
// `LoginRateLimitMiddleware`, the per-username lockout redirect of
// `AuthRoutes.login`, and the reset of each when its window passes.
//
// The handlers read `Date()`, so a test controls the clock through the data:
// it seeds `login_attempts` rows with an `occurredAt` inside or outside the
// window. No test sleeps.
//
// The suite also holds the small refusals of `AuthRoutes` that no other suite
// reaches: the signed-in visits to the login and register forms, the short
// username, and the post-logout return address that the IdP end-session
// redirect carries.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class LoginLockoutRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-login-lockout")
    }

    /// The default configuration. `makeTestApp` sets none, so the middleware
    /// and the handler both use it.
    private var configuration: LoginRateLimitConfiguration { app.loginRateLimitConfiguration }

    /// POSTs the login form with a valid CSRF token. Returns the status, the
    /// redirect target and the body.
    private func postLogin(
        username: String, password: String, headers: HTTPHeaders = [:]
    ) async throws -> (status: HTTPStatus, location: String?, body: String) {
        let (token, cookie) = try await csrfFields(for: "/login", on: app)
        var status: HTTPStatus = .internalServerError
        var location: String?
        var body = ""
        try await app.asyncTest(
            .POST, "/login",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                for (name, value) in headers { req.headers.add(name: name, value: value) }
                try req.content.encode(
                    ["username": username, "password": password, "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                status = res.status
                location = res.headers.first(name: .location)
                body = res.body.string
            })
        return (status, location, body)
    }

    /// A bare POST with no form and no CSRF token. The rate limit sits in
    /// front of the CSRF check, so it is enough to count against the limit.
    private func barePost(_ path: String, headers: HTTPHeaders = [:]) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                for (name, value) in headers { req.headers.add(name: name, value: value) }
            },
            afterResponse: { res in status = res.status })
        return status
    }

    private func seed(scope: String, key: String, count: Int, at date: Date) async throws {
        for _ in 0..<count {
            try await LoginAttempt(scope: scope, attemptKey: key, occurredAt: date).create(on: app.db)
        }
    }

    private func attemptCount(scope: String, key: String) async throws -> Int {
        try await LoginAttempt.query(on: app.db)
            .filter(\.$scope == scope)
            .filter(\.$attemptKey == key)
            .count()
    }

    private func makeAccount(_ username: String, password: String) async throws -> APIUser {
        let user = APIUser(username: username, passwordHash: try testPasswordHash(password), role: "user")
        try await user.save(on: app.db)
        return user
    }

    // MARK: - Per-username lockout

    @Test func repeatedWrongPasswordsLockTheAccountAgainstTheRightPassword() async throws {
        try await withApp(app) { _ in
            let user = try await makeAccount("lock_target", password: "correct-horse")
            for _ in 0..<configuration.lockoutThreshold {
                let wrong = try await postLogin(username: "lock_target", password: "wrong-guess")
                #expect(wrong.location == "/login?error=invalid")
            }

            let refused = try await postLogin(username: "lock_target", password: "correct-horse")

            #expect(refused.status == .seeOther)
            #expect(refused.location == "/login?error=locked")
            let reloaded = try #require(try await APIUser.find(try user.requireID(), on: app.db))
            #expect(reloaded.lastLoginAt == nil, "a locked account must not sign in")
            let locked = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.loginLocked.rawValue)
                .count()
            #expect(locked == 1)
        }
    }

    @Test func theLockoutKeyIgnoresTheCaseOfTheUsername() async throws {
        try await withApp(app) { _ in
            _ = try await makeAccount("case_target", password: "correct-horse")
            try await seed(
                scope: LoginAttempt.Scope.userFailure, key: "case_target",
                count: configuration.lockoutThreshold, at: Date().addingTimeInterval(-30))

            let refused = try await postLogin(username: "CASE_Target", password: "correct-horse")

            #expect(refused.location == "/login?error=locked")
        }
    }

    @Test func aWrongPasswordIsRecordedUnderTheLowercasedUsername() async throws {
        try await withApp(app) { _ in
            _ = try await makeAccount("MixedCaseUser", password: "correct-horse")

            let wrong = try await postLogin(username: "MixedCaseUser", password: "nope-nope")

            #expect(wrong.location == "/login?error=invalid")
            #expect(try await attemptCount(scope: LoginAttempt.Scope.userFailure, key: "mixedcaseuser") == 1)
            #expect(try await attemptCount(scope: LoginAttempt.Scope.userFailure, key: "MixedCaseUser") == 0)
        }
    }

    @Test func failuresOlderThanTheWindowNoLongerLockAndASignInClearsThem() async throws {
        try await withApp(app) { _ in
            _ = try await makeAccount("expired_target", password: "correct-horse")
            let outside = Date().addingTimeInterval(-(configuration.lockoutWindowSeconds + 60))
            try await seed(
                scope: LoginAttempt.Scope.userFailure, key: "expired_target",
                count: configuration.lockoutThreshold, at: outside)

            let signedIn = try await postLogin(username: "expired_target", password: "correct-horse")

            #expect(signedIn.status == .seeOther)
            #expect(signedIn.location == "/")
            #expect(try await attemptCount(scope: LoginAttempt.Scope.userFailure, key: "expired_target") == 0)
        }
    }

    @Test func failuresInsideTheWindowStillLock() async throws {
        try await withApp(app) { _ in
            _ = try await makeAccount("inside_target", password: "correct-horse")
            let inside = Date().addingTimeInterval(-(configuration.lockoutWindowSeconds - 60))
            try await seed(
                scope: LoginAttempt.Scope.userFailure, key: "inside_target",
                count: configuration.lockoutThreshold, at: inside)

            let refused = try await postLogin(username: "inside_target", password: "correct-horse")

            #expect(refused.location == "/login?error=locked")
            #expect(
                try await attemptCount(scope: LoginAttempt.Scope.userFailure, key: "inside_target")
                    == configuration.lockoutThreshold,
                "a refused attempt must not clear the failures")
        }
    }

    @Test func aSignInBelowTheThresholdClearsTheEarlierFailures() async throws {
        try await withApp(app) { _ in
            _ = try await makeAccount("recover_target", password: "correct-horse")
            try await seed(
                scope: LoginAttempt.Scope.userFailure, key: "recover_target",
                count: configuration.lockoutThreshold - 1, at: Date().addingTimeInterval(-30))

            let signedIn = try await postLogin(username: "recover_target", password: "correct-horse")

            #expect(signedIn.location == "/")
            #expect(try await attemptCount(scope: LoginAttempt.Scope.userFailure, key: "recover_target") == 0)
        }
    }

    // MARK: - Per-IP rate limit

    @Test func thePostAfterThePerMinuteCapIsRefusedWith429() async throws {
        try await withApp(app) { _ in
            for _ in 0..<configuration.perMinute {
                #expect(try await barePost("/login") != .tooManyRequests)
            }

            var status: HTTPStatus = .ok
            var retryAfter: String?
            var body = ""
            try await app.asyncTest(
                .POST, "/login",
                afterResponse: { res in
                    status = res.status
                    retryAfter = res.headers.first(name: "Retry-After")
                    body = res.body.string
                })

            #expect(status == .tooManyRequests)
            #expect(retryAfter == "60")
            #expect(body.contains("rate_limited"))
        }
    }

    @Test func loginAndRegisterShareOneCounterButOtherRoutesAreNotLimited() async throws {
        try await withApp(app) { _ in
            try await seed(
                scope: LoginAttempt.Scope.ip, key: "unknown",
                count: configuration.perMinute, at: Date().addingTimeInterval(-5))

            #expect(try await barePost("/register") == .tooManyRequests)
            // A GET of the form and a POST to another route do not count.
            var formStatus: HTTPStatus = .internalServerError
            try await app.asyncTest(.GET, "/login", afterResponse: { res in formStatus = res.status })
            #expect(formStatus == .ok)
            #expect(try await barePost("/logout") != .tooManyRequests)
        }
    }

    @Test func theCapResetsOnceTheEarlierRequestsLeaveTheMinute() async throws {
        try await withApp(app) { _ in
            try await seed(
                scope: LoginAttempt.Scope.ip, key: "unknown",
                count: configuration.perMinute, at: Date().addingTimeInterval(-61))

            #expect(try await barePost("/login") != .tooManyRequests)
            // The stale rows are pruned on the write; only this request is left.
            #expect(try await attemptCount(scope: LoginAttempt.Scope.ip, key: "unknown") == 1)
        }
    }

    @Test func theLimitKeysOnTheLastForwardedForEntry() async throws {
        try await withApp(app) { _ in
            #expect(configuration.trustForwardedFor)
            try await seed(
                scope: LoginAttempt.Scope.ip, key: "203.0.113.9",
                count: configuration.perMinute, at: Date().addingTimeInterval(-5))

            // The proxy appends the peer it saw, so the last entry is the client.
            let blocked = try await barePost(
                "/login", headers: ["X-Forwarded-For": "198.51.100.1, 203.0.113.9"])
            // A client-chosen first entry cannot dodge the limit, and a
            // different peer is not limited.
            let otherPeer = try await barePost(
                "/login", headers: ["X-Forwarded-For": "203.0.113.9, 198.51.100.7"])

            #expect(blocked == .tooManyRequests)
            #expect(otherPeer != .tooManyRequests)
        }
    }

    @Test func clientIPAddressFallsBackWhenTheHeaderIsUntrustedOrBlank() async throws {
        try await withApp(app) { _ in
            func request(forwardedFor: String) -> Request {
                Request(
                    application: app, method: .POST, url: "/login",
                    headers: ["X-Forwarded-For": forwardedFor], on: app.eventLoopGroup.next())
            }

            #expect(clientIPAddress(from: request(forwardedFor: "192.0.2.4"), trustForwardedFor: false) == "unknown")
            #expect(clientIPAddress(from: request(forwardedFor: "192.0.2.4,  "), trustForwardedFor: true) == "unknown")
            #expect(
                clientIPAddress(from: request(forwardedFor: "192.0.2.4,  192.0.2.5 "), trustForwardedFor: true)
                    == "192.0.2.5")
        }
    }

    // MARK: - Stale-row sweep

    @Test func purgeStaleDeletesOnlyRowsOutsideEveryWindow() async throws {
        try await withApp(app) { _ in
            let now = Date()
            try await seed(scope: LoginAttempt.Scope.ip, key: "old", count: 2, at: now.addingTimeInterval(-7200))
            try await seed(scope: LoginAttempt.Scope.ip, key: "new", count: 1, at: now.addingTimeInterval(-60))

            // A long lockout window keeps the two-hour-old rows.
            await LoginAttemptService.purgeStale(db: app.db, lockoutWindowSeconds: 10_800, logger: app.logger)
            #expect(try await attemptCount(scope: LoginAttempt.Scope.ip, key: "old") == 2)

            // The floor is one hour, so a short window removes them.
            await LoginAttemptService.purgeStale(db: app.db, lockoutWindowSeconds: 900, logger: app.logger)
            #expect(try await attemptCount(scope: LoginAttempt.Scope.ip, key: "old") == 0)
            #expect(try await attemptCount(scope: LoginAttempt.Scope.ip, key: "new") == 1)
        }
    }

    /// The periodic monitor sweeps with the app's own lockout window (the
    /// default 15 minutes, so the one-hour floor applies).
    @Test func theReaperMonitorSweepDeletesRowsOutsideTheWindow() async throws {
        try await withApp(app) { app in
            let now = Date()
            try await seed(
                scope: LoginAttempt.Scope.ip, key: "monitor_old", count: 2, at: now.addingTimeInterval(-7200))
            try await seed(scope: LoginAttempt.Scope.ip, key: "monitor_new", count: 1, at: now.addingTimeInterval(-60))

            let monitor = app.loginAttemptReaperMonitor
            #expect(monitor.name == "Login-attempt reaper")
            await monitor.sweepOnce(application: app)

            #expect(try await attemptCount(scope: LoginAttempt.Scope.ip, key: "monitor_old") == 0)
            #expect(try await attemptCount(scope: LoginAttempt.Scope.ip, key: "monitor_new") == 1)
        }
    }

    // MARK: - Small refusals of the auth routes

    @Test func aSignedInVisitToTheLoginOrRegisterFormGoesHome() async throws {
        try await withApp(app) { _ in
            // Production runs the session authenticator on every request
            // (`bootstrapAppMiddleware`); the test app does not, so add it.
            app.middleware.use(UserSessionAuthenticator())
            let cookie = try await loginUser(
                username: "already_in", password: "correct-horse", role: "user", on: app)
            for path in ["/login", "/register"] {
                var location: String?
                try await app.asyncTest(
                    .GET, path,
                    beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                    afterResponse: { res in location = res.headers.first(name: .location) })
                #expect(location == "/", "GET \(path) while signed in")
            }
        }
    }

    @Test func aShortUsernameIsRefusedAndNoAccountIsMade() async throws {
        try await withApp(app) { _ in
            let (token, cookie) = try await csrfFields(for: "/register", on: app)
            var location: String?
            try await app.asyncTest(
                .POST, "/register",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(
                        ["username": "ab", "password": "long-enough-pw", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in location = res.headers.first(name: .location) })

            #expect(location == "/register?error=username_short")
            #expect(try await APIUser.query(on: app.db).count() == 0)
        }
    }

    @Test func logoutCarriesTheReturnAddressToTheIdPEndSession() async throws {
        try await withApp(app) { _ in
            let base = app.securityConfiguration
            app.securityConfiguration = AppSecurityConfiguration(
                publicBaseURL: URL(string: "https://courses.example.edu/"),
                enforceHTTPS: base.enforceHTTPS,
                trustForwardedProto: base.trustForwardedProto,
                sessionCookieSecure: base.sessionCookieSecure,
                sessionIdleTimeoutSeconds: base.sessionIdleTimeoutSeconds,
                sessionIdleWarningSeconds: base.sessionIdleWarningSeconds)
            // No revocation endpoint, so the logout makes no network call.
            app.oidcConfig = OIDCConfiguration(
                clientID: "id",
                clientSecret: "secret",
                redirectURI: "https://courses.example.edu/auth/sso/callback",
                discovery: OIDCDiscovery(
                    issuer: "https://idp.example.com",
                    authorizationEndpoint: "https://idp.example.com/oauth/authorize",
                    tokenEndpoint: "https://idp.example.com/oauth/token",
                    jwksURI: "https://idp.example.com/oauth/jwks",
                    revocationEndpoint: nil,
                    endSessionEndpoint: "https://idp.example.com/oauth/logout"
                ),
                claimConfig: OIDCClaimConfig()
            )

            var location: String?
            try await app.asyncTest(
                .POST, "/logout?reason=timeout",
                afterResponse: { res in location = res.headers.first(name: .location) })

            let target = try #require(location)
            let components = try #require(URLComponents(string: target))
            #expect(components.host == "idp.example.com")
            #expect(components.path == "/oauth/logout")
            let returnTo = components.queryItems?.first { $0.name == "post_logout_redirect_uri" }?.value
            #expect(returnTo == "https://courses.example.edu/login?error=timeout")
            #expect(components.queryItems?.contains { $0.name == "id_token_hint" } == false)
        }
    }
}
