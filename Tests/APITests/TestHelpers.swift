// Tests/APITests/TestHelpers.swift
//
// Shared helpers for integration tests that involve session auth and CSRF.

import CSRF
import Core
import Crypto
import Fluent
import FluentPostgresDriver
import Foundation
import Leaf
import LeafKit
import SQLKit
import Testing
import VaporTesting

@testable import APIServer

func configureTestDatabase(_ app: Application) async throws {
    // Read env vars while holding the async env lock so we don't see a
    // transient `TEST_DATABASE_BACKEND=postgres` set by a concurrently-
    // running env-mutating test in another suite.
    var settings = try await withAsyncEnvLock {
        try testDatabaseSettingsFromEnvironment()
    }

    // Per-test isolated schema for Postgres so `swift test --parallel` can
    // run XCTestCase subclasses concurrently against one shared database.
    // Each `Application` gets its own schema + `search_path`, so migrations
    // and queries on one app can't trample another.  Replaces the old
    // `DROP SCHEMA public CASCADE; CREATE SCHEMA public` reset.
    if settings.backend == .postgres {
        let schemaName = "test_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))"
        settings = .postgres(
            host: try #require(settings.postgresHost),
            port: try #require(settings.postgresPort),
            database: try #require(settings.postgresDatabase),
            username: try #require(settings.postgresUsername),
            password: try #require(settings.postgresPassword),
            searchPath: [schemaName]
        )
        app.storage[TestPostgresSchemaKey.self] = schemaName
    }

    try configureDatabase(app, settings: settings)

    if let schemaName = app.storage[TestPostgresSchemaKey.self] {
        try await createPostgresTestSchema(app, schemaName: schemaName)
    }

    registerMigrations(on: app)

    // FluentKit logs two info lines per migration ("Starting/Finished prepare").
    // Across the API suite's ~1,100 per-test Applications × 50+ migrations that
    // is >120k log lines that bury real test failures in CI output. Quiet just
    // the migration burst — the test body keeps its normal level (restored
    // below), so nothing that inspects warnings/errors (the query_logs / ring
    // buffer tests) is affected. Override the floor with TEST_LOG_LEVEL (e.g.
    // =info) when debugging migrations.
    let priorLogLevel = app.logger.logLevel
    app.logger.logLevel =
        Environment.get("TEST_LOG_LEVEL").flatMap(Logger.Level.init(rawValue:)) ?? .warning
    try await app.autoMigrate()
    app.logger.logLevel = priorLogLevel
}

struct TestPostgresSchemaKey: StorageKey {
    typealias Value = String
}

/// Quotes an identifier for safe interpolation into raw SQL.  Test schema
/// names are generated from a UUID so they shouldn't contain `"` themselves,
/// but escape anyway — defense in depth, no perf cost.
private func quotedIdentifier(_ raw: String) -> String {
    "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

private func createPostgresTestSchema(_ app: Application, schemaName: String) async throws {
    guard let sql = app.db as? SQLDatabase else { return }
    // CREATE SCHEMA is global and doesn't depend on search_path, so this
    // runs cleanly even though the freshly-configured connection has its
    // search_path pointing at the not-yet-existent schema.
    let quoted = quotedIdentifier(schemaName)
    try await sql.raw("CREATE SCHEMA \(unsafeRaw: quoted)").run()
}

func dropPostgresTestSchema(_ app: Application) async throws {
    guard let schemaName = app.storage[TestPostgresSchemaKey.self] else { return }
    guard let sql = app.db as? SQLDatabase else { return }
    let quoted = quotedIdentifier(schemaName)
    try await sql.raw("DROP SCHEMA IF EXISTS \(unsafeRaw: quoted) CASCADE").run()
}

func testDatabaseSettingsFromEnvironment() throws -> DatabaseSettings {
    let backend =
        Environment.get("TEST_DATABASE_BACKEND")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .flatMap(DatabaseBackend.init(rawValue:))
        ?? .sqlite

    switch backend {
    case .sqlite:
        return .sqliteInMemory()
    case .postgres:
        let host = Environment.get("TEST_DATABASE_HOST")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let database = Environment.get("TEST_DATABASE_NAME")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = Environment.get("TEST_DATABASE_USER")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = Environment.get("TEST_DATABASE_PASSWORD")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Environment.get("TEST_DATABASE_PORT")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : Int($0) }

        guard
            let host, !host.isEmpty,
            let database, !database.isEmpty,
            let username, !username.isEmpty,
            let password, !password.isEmpty,
            let port
        else {
            var missing: [String] = []
            if host?.isEmpty != false { missing.append("TEST_DATABASE_HOST") }
            if port == nil { missing.append("TEST_DATABASE_PORT") }
            if database?.isEmpty != false { missing.append("TEST_DATABASE_NAME") }
            if username?.isEmpty != false { missing.append("TEST_DATABASE_USER") }
            if password?.isEmpty != false { missing.append("TEST_DATABASE_PASSWORD") }

            throw DatabaseConfigurationError.invalidSettings(
                "TEST_DATABASE_BACKEND=postgres requires: \(missing.joined(separator: ", "))"
            )
        }

        return .postgres(
            host: host,
            port: port,
            database: database,
            username: username,
            password: password
        )
    }
}

// MARK: - Course fixture helper

private struct TestCourseIDsKey: StorageKey {
    typealias Value = [String: UUID]
}

extension Application {
    /// Returns the UUID of a test `APICourse` with `code`, creating it on first
    /// call.  Memoized per `Application` in `storage` so repeat callers don't
    /// re-query the database.  Six test classes previously each carried a
    /// private copy of this helper; consolidating here matches the same
    /// drift-avoidance rationale as `makeTestApp` / `registerMigrations`.
    func testCourseID(
        code: String = "TEST101",
        name: String = "Test Course",
        enrollmentMode: CourseEnrollmentMode = .open
    ) async throws -> UUID {
        if let cached = storage[TestCourseIDsKey.self]?[code] {
            return cached
        }
        let course: APICourse
        if let existing = try await APICourse.query(on: db).filter(\.$code == code).first() {
            course = existing
        } else {
            course = APICourse(code: code, name: name, enrollmentMode: enrollmentMode)
            try await course.save(on: db)
        }
        let id = try course.requireID()
        var cache = storage[TestCourseIDsKey.self] ?? [:]
        cache[code] = id
        storage[TestCourseIDsKey.self] = cache
        return id
    }
}

/// Enrols `username` as a per-course instructor in the shared TEST101 course so
/// the per-course `/instructor` gate (Phase 5) admits them. Idempotent.
func enrollAsTestInstructor(
    username: String, on app: Application, courseCode: String = "TEST101"
) async throws {
    let courseID = try await app.testCourseID(code: courseCode)
    guard let user = try await APIUser.query(on: app.db).filter(\.$username == username).first()
    else { return }
    let userID = try user.requireID()
    // Upsert to `.instructor` — a `.auto` course auto-enrolls the user at login
    // and (post role-collapse, #417 Slice G2) seeds a non-admin as a per-course
    // `.student`, so skipping on "already enrolled" could leave them a student
    // and 403 the per-course staff gates.
    if let existing = try await APICourseEnrollment.query(on: app.db)
        .filter(\.$userID == userID).filter(\.$course.$id == courseID).first()
    {
        if existing.role != .instructor {
            existing.role = .instructor
            try await existing.save(on: app.db)
        }
    } else {
        try await APICourseEnrollment(userID: userID, courseID: courseID, role: .instructor)
            .save(on: app.db)
    }
}

/// Demotes every one of `username`'s course enrollments to `.student` — the
/// per-course equivalent of the retired "downgrade the global role" move (#417
/// Slice G2 collapsed the deployment role to user/admin/mcp, so teaching
/// authority lives on the enrollment). After this the user is staff nowhere, so
/// MCP content consent / refresh re-authorization (`isStaffAnywhere`) must fail.
func demoteToStudentEverywhere(username: String, on app: Application) async throws {
    guard let user = try await APIUser.query(on: app.db).filter(\.$username == username).first()
    else { return }
    let userID = try user.requireID()
    for enrollment in try await APICourseEnrollment.query(on: app.db)
        .filter(\.$userID == userID).all()
    {
        enrollment.role = .student
        try await enrollment.save(on: app.db)
    }
}

// MARK: - Async app lifecycle

/// Runs an async test body with a Vapor application and always shuts it down.
func withApp(_ app: Application, _ body: (Application) async throws -> Void) async throws {
    do {
        try await body(app)
        try await app.asyncShutdown()
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
}

/// Creates a `.testing` Vapor Application and runs `setup`, returning the
/// fully-configured app to the caller.  If `setup` throws, the partial
/// Application is `asyncShutdown`-d before the error is rethrown.
///
/// This is the safe replacement for the bare pattern
///
///     let app = try await Application.make(.testing)
///     /* setup that may throw */
///     return app
///
/// which leaks a half-built `Application` on throw.  `Application.deinit`
/// then calls the *synchronous* `shutdown()`, and on a testing app with
/// NIO event loops + FluentKit pools that trips an assertion in
/// `ServeCommand.deinit` → SIGILL on Linux.  That terminates the whole
/// xctest process and kills every other concurrent test.
func makeTestingApplication(
    setup: (Application) async throws -> Void
) async throws -> Application {
    let app = try await Application.make(.testing)
    do {
        try await setup(app)
        return app
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
}

// MARK: - Standard test app

private struct TestDataDirectoryKey: StorageKey {
    typealias Value = String
}

extension Application {
    /// Filesystem directory created by `makeTestApp` for this app's
    /// results/testsetups/submissions trees. Nil if the app wasn't built
    /// via `makeTestApp`.
    var testDataDirectory: String? {
        storage[TestDataDirectoryKey.self]
    }

    /// Shuts the app down and removes the temp directory created by
    /// `makeTestApp`. Use in tearDown for any app obtained from
    /// `makeTestApp`.
    func tearDownTestApp() async throws {
        let dir = storage[TestDataDirectoryKey.self]
        try? await dropPostgresTestSchema(self)
        try await asyncShutdown()
        if let dir {
            try? FileManager.default.removeItem(atPath: dir)
        }
    }
}

/// Builds a `.testing` Vapor application with the standard test wiring:
/// per-app temp directories for results/testsetups/submissions,
/// in-memory sessions, the production migration list, Leaf views, and
/// the full route tree mounted.
///
/// Caller owns the lifecycle — pair with `app.tearDownTestApp()` in
/// tearDown.  For unit tests that need a bare app (single-middleware
/// isolation, custom auth modes, custom database configuration), use
/// `Application.make(.testing)` directly.
func makeTestApp(
    prefix: String = "chickadee-test",
    authMode: AuthMode = .local,
    appConfig: AppConfig? = nil
) async throws -> Application {
    try await makeTestingApplication { app in
        app.authMode = authMode
        // Seed AppConfig so code that reads `app.appConfig.<sub>` (e.g.
        // workerJobRoutes' public-base-URL resolver, OIDC redirect builder) sees
        // sane defaults during integration tests. Callers can pass a custom
        // `appConfig` to exercise specific config branches.
        app.appConfig = appConfig ?? AppConfig.testDefaults(authMode: authMode)

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)/")
            .path
        let dirs = ["results/", "testsetups/", "submissions/", "data-exports/", "content-files/"].map {
            tmpDir + $0
        }
        for dir in dirs {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        app.resultsDirectory = dirs[0]
        app.testSetupsDirectory = dirs[1]
        app.submissionsDirectory = dirs[2]
        app.dataExportsDirectory = dirs[3]
        app.contentFilesDirectory = dirs[4]
        // Seed the worker-secret and local-runner-autostart paths into the
        // per-test temp directory so admin/worker-management tests don't
        // collide with each other or with the dev .worker-secret on disk.
        app.workerSecretFilePath = tmpDir + ".worker-secret"
        app.localRunnerAutoStartFilePath = tmpDir + ".local-runner-autostart"
        app.storage[TestDataDirectoryKey.self] = tmpDir

        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)

        try await configureTestDatabase(app)

        // Assignment content-version capture. Registered here rather than
        // inherited from `bootstrapAppMiddleware` (which the test app does not
        // run) because versioning is part of what the instructor write routes
        // DO, not an ambient production-only concern — a test app that skips it
        // would let a capture regression pass CI unnoticed.
        // `AssignmentVersionCaptureWiringTests` pins the production
        // registration separately.
        app.middleware.use(AssignmentVersionCaptureMiddleware())

        // The browser-grading import check's inventory, loaded here for the same
        // reason the version-capture middleware is registered above: rejecting a
        // script whose imports the grading kernel lacks is part of what the
        // instructor write routes DO, so a test app without it would let a
        // regression through. Silently absent when the vendored kernel bytes are
        // not in the checkout, matching production (`bootstrapAppServices`).
        app.kernelEnvironments = KernelEnvironments.load(
            publicDirectory: app.directory.publicDirectory)

        configureLeaf(app)
        try routes(app)
    }
}

extension Application {
    @discardableResult
    func asyncTest(
        method runnerMethod: Method = .inMemory,
        _ method: HTTPMethod,
        _ path: String,
        headers: HTTPHeaders = [:],
        body: ByteBuffer? = nil,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column,
        afterResponse: (TestingHTTPResponse) throws -> Void
    ) async throws -> TestingApplicationTester {
        try await self.asyncTest(
            method: runnerMethod,
            method,
            path,
            headers: headers,
            body: body,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            beforeRequest: { _ in },
            afterResponse: afterResponse
        )
    }

    @discardableResult
    func asyncTest(
        method runnerMethod: Method = .inMemory,
        _ method: HTTPMethod,
        _ path: String,
        headers: HTTPHeaders = [:],
        body: ByteBuffer? = nil,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column,
        beforeRequest: (inout TestingHTTPRequest) throws -> Void = { _ in },
        afterResponse: (TestingHTTPResponse) throws -> Void = { _ in }
    ) async throws -> TestingApplicationTester {
        let tester = try self.testing(method: runnerMethod)
        return try await tester.test(
            method,
            path,
            headers: headers,
            body: body,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            beforeRequest: { request async throws in
                try beforeRequest(&request)
            },
            afterResponse: { response async throws in
                try afterResponse(response)
            }
        )
    }

    /// Fire a request and return the response directly, without a callback.
    /// Useful for concurrent tests where multiple responses must be collected.
    func asyncSendRequest(
        _ method: HTTPMethod,
        _ path: String,
        headers: HTTPHeaders = [:],
        body: ByteBuffer? = nil,
        beforeRequest: (inout TestingHTTPRequest) throws -> Void = { _ in }
    ) async throws -> TestingHTTPResponse {
        var captured: TestingHTTPResponse?
        try await self.asyncTest(
            method, path,
            headers: headers,
            body: body,
            beforeRequest: beforeRequest,
            afterResponse: { captured = $0 }
        )
        return try #require(captured)
    }
}

// MARK: - Leaf / CSRF setup

/// Call in test setUp — after session middleware, before routes() — to enable
/// Leaf rendering. Required so that GET requests to form pages produce HTML
/// containing the `#csrfFormField()` hidden input, which is how tests obtain
/// a valid session-bound CSRF token.
func configureLeaf(_ app: Application) {
    // LeafKit's sandbox rejects any path that contains a hidden directory component
    // (e.g. ".claude"). When running from a git worktree under .claude, create a
    // symlink from a clean temp path so the string-level path checks pass.
    let viewsDir = app.directory.viewsDirectory
    if viewsDir.contains("/.") {
        let cleanPath = NSTemporaryDirectory() + "chickadee-leaf-\(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: cleanPath)
        try? FileManager.default.createSymbolicLink(atPath: cleanPath, withDestinationPath: viewsDir)
        app.leaf.configuration = LeafConfiguration(rootDirectory: cleanPath + "/")
    }
    app.views.use(.leaf)
    app.leaf.tags["csrfFormField"] = CSRFFormFieldTag()
    // rawJSON is safe to register in tests (pure string passthrough).
    // csrfToken / appVersion are intentionally NOT registered here — they
    // trigger CSRF.createToken / version lookups that assume a more complete
    // middleware stack than the minimal test app.  Pages that embed
    // `#csrfToken()` or `#appVersion()` will render those tokens verbatim;
    // no existing test asserts on that markup.
    app.leaf.tags["rawJSON"] = RawJSONTag()
    // Safe in the minimal test app: reads only securityConfiguration, which
    // falls back to `.default` (30 min) when unset.
    app.leaf.tags["sessionIdleTimeoutSeconds"] = SessionIdleTimeoutTag()
    app.leaf.tags["sessionIdleWarningSeconds"] = SessionIdleWarningTag()
}

// MARK: - CSRF token extraction

/// Parses the CSRF token from a rendered Leaf form page.
/// Looks for the hidden input rendered by `#csrfFormField()`:
///   `<input type='hidden' name='_csrf' value='TOKEN'>`
func extractCSRFToken(from html: String) -> String {
    guard let range = html.range(of: "name='_csrf' value='") else { return "" }
    let start = range.upperBound
    guard let end = html[start...].firstIndex(of: "'") else { return "" }
    return String(html[start..<end])
}

/// GETs `path` and returns the CSRF token embedded in the rendered form HTML,
/// along with the session cookie (creating one on first call, or reusing the
/// supplied `cookie` to stay in the same session).
func csrfFields(
    for path: String,
    cookie: String = "",
    on app: Application
) async throws -> (token: String, cookie: String) {
    var outToken = ""
    var outCookie = cookie
    try await app.asyncTest(
        .GET, path,
        beforeRequest: { req in
            if !cookie.isEmpty { req.headers.add(name: .cookie, value: cookie) }
        },
        afterResponse: { res in
            if let c = res.headers.first(name: .setCookie) { outCookie = c }
            outToken = extractCSRFToken(from: res.body.string)
        })
    return (outToken, outCookie)
}

// MARK: - Worker HMAC auth helper

/// Generates HMAC-signed HTTPHeaders for worker requests in tests.
/// Produces the same signature that WorkerHMACAuthMiddleware expects.
func workerHMACHeaders(
    method: HTTPMethod,
    path: String,
    body: ByteBuffer? = nil,
    workerSecret: String,
    workerID: String = "test-runner"
) -> HTTPHeaders {
    let timestamp = Int64(Date().timeIntervalSince1970)
    let nonce = UUID().uuidString

    var bodyCopy = body ?? ByteBuffer()
    let bodyBytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
    let bodyHash = Data(SHA256.hash(data: Data(bodyBytes))).hexEncodedString()

    let payload = [
        method.rawValue.uppercased(),
        path,
        bodyHash,
        String(timestamp),
        nonce,
    ].joined(separator: "\n")

    let key = SymmetricKey(data: Data(workerSecret.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
    let signature = Data(mac).hexEncodedString()

    var headers = HTTPHeaders()
    headers.add(name: "X-Worker-Timestamp", value: String(timestamp))
    headers.add(name: "X-Worker-Nonce", value: nonce)
    headers.add(name: "X-Worker-Body-SHA256", value: bodyHash)
    headers.add(name: "X-Worker-Signature", value: signature)
    headers.add(name: "X-Worker-Id", value: workerID)
    headers.contentType = .json
    return headers
}

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Login helper

/// Hashes a password at the minimum bcrypt cost (4) for test fixtures.
///
/// Production hashing uses the default cost (12, ~150 ms). Test security is
/// irrelevant, but running a cost-12 hash + verify for every login across the
/// parallel suite saturates a 2-core CI runner — under the nightly coverage
/// build that CPU starvation slows test-app/login setup enough to flake
/// auth-dependent tests (303/401 / ~80 s stalls). bcrypt verify reads the cost
/// from the stored hash, so logins against these fixtures are fast too.
///
/// This only changes *test fixture* hashes. It does NOT touch the app's
/// configured password hasher, so `AuthProvider`'s timing-equalizer (the
/// account-enumeration defense exercised by
/// `loginWithUnknownUserStillRunsBcryptVerify`) still runs at the production
/// cost.
func testPasswordHash(_ password: String) throws -> String {
    try Bcrypt.hash(password, cost: 4)
}

/// Creates `username` in the database (if not already present) with `role`,
/// then performs the full two-step GET /login → POST /login flow so the CSRF
/// token is valid. Returns the authenticated session cookie.
@discardableResult
func loginUser(
    username: String,
    password: String,
    role: String,
    on app: Application
) async throws -> String {
    if try await APIUser.query(on: app.db).filter(\.$username == username).first() == nil {
        let hash = try testPasswordHash(password)
        let user = APIUser(username: username, passwordHash: hash, role: role)
        try await user.save(on: app.db)
    }

    // Step 1: GET /login to generate a session and CSRF token.
    let (token, sessionCookie) = try await csrfFields(for: "/login", on: app)

    // Step 2: POST /login with the CSRF token bound to that session.
    var authCookie = sessionCookie
    try await app.asyncTest(
        .POST, "/login",
        beforeRequest: { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(
                ["username": username, "password": password, "_csrf": token],
                as: .urlEncodedForm
            )
        },
        afterResponse: { res in
            // Use the new cookie if the session was rotated, otherwise keep the old one.
            if let c = res.headers.first(name: .setCookie) { authCookie = c }
        })
    return authCookie
}

/// Explicit-roster promotion: an admin promotes an already-enrolled user to a
/// per-course instructor. Teaching authority is per-course now (#417 Slice G2):
/// login auto-enrolls a non-admin as a `.student` and there is NO auto-grant, so
/// suites whose `.auto` fixtures used to rely on "auto-enroll the instructor on
/// login" call this after `loginUser(role: "instructor")` to simulate the admin
/// promotion. Upgrades every `.student` enrollment the user holds to
/// `.instructor` (a fresh test instructor's only enrollments are the ones login
/// just auto-created); anything enrolled explicitly at another role is untouched.
func promoteToInstructor(_ username: String, on app: Application) async throws {
    guard let user = try await APIUser.query(on: app.db).filter(\.$username == username).first(),
        let userID = user.id
    else { return }
    for enrollment in try await APICourseEnrollment.query(on: app.db)
        .filter(\.$userID == userID).all() where enrollment.role == .student
    {
        enrollment.role = .instructor
        try await enrollment.save(on: app.db)
    }
}

/// Wraps a runtime skip-or-fail condition as a throwable error.  Use
/// from sync/async helpers where the test cannot proceed; the test
/// will surface the message and fail.
struct IssueRecorded: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}
