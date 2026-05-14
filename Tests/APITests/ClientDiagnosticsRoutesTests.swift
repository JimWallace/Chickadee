// Tests/APITests/ClientDiagnosticsRoutesTests.swift
//
// Covers POST /api/v1/client-diagnostics — the endpoint the student submit
// page posts to when the in-browser editor (JupyterLite + Pyodide) cannot
// start.  Verifies authentication, kind validation, persistence of the
// expected fields, and the per-(user, setup, kind) rate-limit behaviour.

import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent
import Foundation

final class ClientDiagnosticsRoutesTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await makeTestApp(prefix: "chickadee-cdr")
    }

    override func tearDown() async throws {
        try await app.tearDownTestApp()
    }

    // MARK: - Helpers

    /// Returns (sessionCookie, csrfToken) for a logged-in student.
    private func loginAsStudent(
        username: String = "cd_student"
    ) async throws -> (cookie: String, csrf: String) {
        let cookie = try await loginUser(username: username, password: "pass", role: "student", on: app)
        let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
        return (sessionCookie, csrf)
    }

    /// Inserts a minimal test setup record matching the structure used in
    /// production so the route's setup-existence lookup succeeds.
    @discardableResult
    private func insertSetup(id: String) async throws -> APITestSetup {
        if let existing = try await APITestSetup.find(id, on: app.db) {
            return existing
        }
        let course = APICourse(code: "CD\(id)", name: "CD course \(id)")
        try await course.save(on: app.db)
        let setup = APITestSetup(
            id: id,
            manifest: #"{"schemaVersion":1}"#,
            zipPath: "/tmp/\(id).zip",
            courseID: try course.requireID()
        )
        try await setup.save(on: app.db)
        return setup
    }

    private func postJSON(
        _ body: String,
        auth: (cookie: String, csrf: String),
        userAgent: String? = nil
    ) async throws -> XCTHTTPResponse {
        try await app.asyncSendRequest(.POST, "/api/v1/client-diagnostics") { req in
            req.headers.add(name: .cookie, value: auth.cookie)
            req.headers.add(name: "x-csrf-token", value: auth.csrf)
            req.headers.contentType = .json
            if let ua = userAgent { req.headers.replaceOrAdd(name: .userAgent, value: ua) }
            req.body = ByteBuffer(string: body)
        }
    }

    // MARK: - Auth

    func testRequiresAuthentication() async throws {
        let res = try await app.asyncSendRequest(.POST, "/api/v1/client-diagnostics") { req in
            req.headers.contentType = .json
            req.body = ByteBuffer(string: #"{"kind":"watchdog_timeout"}"#)
        }
        XCTAssertEqual(res.status, .unauthorized)
    }

    // MARK: - Validation

    func testRejectsUnknownKind() async throws {
        let auth = try await loginAsStudent()
        let res = try await postJSON(#"{"kind":"hacker_stuff"}"#, auth: auth)
        XCTAssertEqual(res.status, .badRequest)
    }

    // MARK: - Persistence

    func testPersistsWatchdogTimeoutRecord() async throws {
        let auth = try await loginAsStudent()
        try await insertSetup(id: "setup_abc")
        let body = #"{"kind":"watchdog_timeout","testSetupID":"setup_abc"}"#
        let res = try await postJSON(body, auth: auth, userAgent: "Mozilla/5.0 (TestRunner)")
        XCTAssertEqual(res.status, .accepted)

        let records = try await APIClientDiagnostic.query(on: app.db).all()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.kind, "watchdog_timeout")
        XCTAssertEqual(records.first?.testSetupID, "setup_abc")
        XCTAssertEqual(records.first?.userAgent, "Mozilla/5.0 (TestRunner)")
        XCTAssertNil(records.first?.failedChecks)
    }

    func testPersistsPreflightFailRecord() async throws {
        let auth = try await loginAsStudent()
        try await insertSetup(id: "setup_xyz")
        let body = #"""
        {"kind":"preflight_fail","testSetupID":"setup_xyz","failedChecks":["serviceWorker","indexedDB"]}
        """#
        let res = try await postJSON(body, auth: auth, userAgent: "TestUA/1.0")
        XCTAssertEqual(res.status, .accepted)

        let records = try await APIClientDiagnostic.query(on: app.db).all()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.kind, "preflight_fail")
        XCTAssertEqual(records.first?.failedChecks, "serviceWorker,indexedDB")
    }

    func testStaleSetupIDIsNullified() async throws {
        // If the supplied setup doesn't exist (e.g. it was deleted between
        // the page load and the diagnostic post), the row is still recorded
        // but with testSetupID = nil — no FK violation, no 500.
        let auth = try await loginAsStudent()
        let body = #"{"kind":"watchdog_timeout","testSetupID":"setup_does_not_exist"}"#
        let res = try await postJSON(body, auth: auth)
        XCTAssertEqual(res.status, .accepted)

        let records = try await APIClientDiagnostic.query(on: app.db).all()
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.testSetupID)
    }

    func testPersistsWatchdogKernelUnhealthySubtype() async throws {
        // The watchdog distinguishes two failure modes by populating
        // failedChecks=["kernel-unhealthy"] when the JupyterLite app shell
        // mounted but the Pyodide kernel never reached idle/busy.  Both
        // count toward "Students With Browser Errors" but the subtype is
        // preserved on the record for debugging.
        let auth = try await loginAsStudent()
        try await insertSetup(id: "setup_kernel_unhealthy")
        let body = #"""
        {"kind":"watchdog_timeout","testSetupID":"setup_kernel_unhealthy","failedChecks":["kernel-unhealthy"]}
        """#
        let res = try await postJSON(body, auth: auth, userAgent: "TestUA/2.0")
        XCTAssertEqual(res.status, .accepted)

        let records = try await APIClientDiagnostic.query(on: app.db).all()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.kind, "watchdog_timeout")
        XCTAssertEqual(records.first?.failedChecks, "kernel-unhealthy")
    }

    func testAcceptsMissingTestSetupID() async throws {
        let auth = try await loginAsStudent()
        let body = #"{"kind":"watchdog_timeout"}"#
        let res = try await postJSON(body, auth: auth)
        XCTAssertEqual(res.status, .accepted)

        let records = try await APIClientDiagnostic.query(on: app.db).all()
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.testSetupID)
    }

    // MARK: - Rate limiting

    func testDeduplicatesRepeatedFailuresInWindow() async throws {
        let auth = try await loginAsStudent()
        let body = #"{"kind":"watchdog_timeout","testSetupID":"setup_dup"}"#

        // First three posts in quick succession — only the first should
        // persist a row. All three return 202 to the client (the
        // diagnostic was accepted, just deduplicated).
        for _ in 0..<3 {
            let res = try await postJSON(body, auth: auth)
            XCTAssertEqual(res.status, .accepted)
        }

        let count = try await APIClientDiagnostic.query(on: app.db).count()
        XCTAssertEqual(count, 1, "Repeated diagnostics within cooldown should not produce additional rows")
    }

    func testDifferentSetupOrKindAreNotDeduplicated() async throws {
        let auth = try await loginAsStudent()

        let res1 = try await postJSON(
            #"{"kind":"watchdog_timeout","testSetupID":"setup_a"}"#, auth: auth)
        XCTAssertEqual(res1.status, .accepted)

        // Different setup → distinct rate-limit key.
        let res2 = try await postJSON(
            #"{"kind":"watchdog_timeout","testSetupID":"setup_b"}"#, auth: auth)
        XCTAssertEqual(res2.status, .accepted)

        // Different kind on same setup → also distinct.
        let res3 = try await postJSON(
            #"{"kind":"preflight_fail","testSetupID":"setup_a","failedChecks":["worker"]}"#,
            auth: auth)
        XCTAssertEqual(res3.status, .accepted)

        let count = try await APIClientDiagnostic.query(on: app.db).count()
        XCTAssertEqual(count, 3)
    }

    // MARK: - Rate limiter unit tests

    func testRateLimiterAdmitsOnceWithinCooldown() async {
        let limiter = ClientDiagnosticsRateLimiter(cooldown: 60)
        let userID = UUID()
        let key = ClientDiagnosticsRateLimiter.Key(
            userID: userID, testSetupID: "s1", kind: "watchdog_timeout"
        )
        let t0 = Date()
        let first  = await limiter.admit(key: key, now: t0)
        let second = await limiter.admit(key: key, now: t0.addingTimeInterval(30))
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testRateLimiterReadmitsAfterCooldown() async {
        let limiter = ClientDiagnosticsRateLimiter(cooldown: 60)
        let userID = UUID()
        let key = ClientDiagnosticsRateLimiter.Key(
            userID: userID, testSetupID: "s1", kind: "watchdog_timeout"
        )
        let t0 = Date()
        _ = await limiter.admit(key: key, now: t0)
        let third = await limiter.admit(key: key, now: t0.addingTimeInterval(61))
        XCTAssertTrue(third)
    }
}
