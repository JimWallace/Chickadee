// Tests/APITests/ClientDiagnosticsRoutesTests.swift
//
// Covers POST /api/v1/client-diagnostics — the endpoint the student submit
// page posts to when the in-browser editor (JupyterLite + Pyodide) cannot
// start.  Verifies authentication, kind validation, persistence of the
// expected fields, and the per-(user, setup, kind) rate-limit behaviour.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class ClientDiagnosticsRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-cdr")
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
    ) async throws -> TestingHTTPResponse {
        try await app.asyncSendRequest(.POST, "/api/v1/client-diagnostics") { req in
            req.headers.add(name: .cookie, value: auth.cookie)
            req.headers.add(name: "x-csrf-token", value: auth.csrf)
            req.headers.contentType = .json
            if let ua = userAgent { req.headers.replaceOrAdd(name: .userAgent, value: ua) }
            req.body = ByteBuffer(string: body)
        }
    }

    // MARK: - Auth

    @Test func requiresAuthentication() async throws {
        try await withApp(app) { _ in
            let res = try await app.asyncSendRequest(.POST, "/api/v1/client-diagnostics") { req in
                req.headers.contentType = .json
                req.body = ByteBuffer(string: #"{"kind":"watchdog_timeout"}"#)
            }
            #expect(res.status == .unauthorized)

        }
    }

    // MARK: - Validation

    @Test func rejectsUnknownKind() async throws {
        try await withApp(app) { _ in
            let auth = try await loginAsStudent()
            let res = try await postJSON(#"{"kind":"hacker_stuff"}"#, auth: auth)
            #expect(res.status == .badRequest)

        }
    }

    // MARK: - Persistence

    @Test func persistsWatchdogTimeoutRecord() async throws {
        try await withApp(app) { _ in
            let auth = try await loginAsStudent()
            try await insertSetup(id: "setup_abc")
            let body = #"{"kind":"watchdog_timeout","testSetupID":"setup_abc"}"#
            let res = try await postJSON(body, auth: auth, userAgent: "Mozilla/5.0 (TestRunner)")
            #expect(res.status == .accepted)

            let records = try await APIClientDiagnostic.query(on: app.db).all()
            #expect(records.count == 1)
            #expect(records.first?.kind == "watchdog_timeout")
            #expect(records.first?.testSetupID == "setup_abc")
            #expect(records.first?.userAgent == "Mozilla/5.0 (TestRunner)")
            #expect(records.first?.failedChecks == nil)

        }
    }

    @Test func persistsPageUnresponsiveRecord() async throws {
        try await withApp(app) { _ in
            // The freeze watchdog worker beacons this kind when the editor page's
            // main thread hard-froze. message carries "stalled_ms=…".
            let auth = try await loginAsStudent()
            try await insertSetup(id: "setup_frozen")
            let body = #"{"kind":"page_unresponsive","testSetupID":"setup_frozen","message":"stalled_ms=9120"}"#
            let res = try await postJSON(body, auth: auth, userAgent: "Mozilla/5.0 (TestRunner)")
            #expect(res.status == .accepted)

            let records = try await APIClientDiagnostic.query(on: app.db).all()
            #expect(records.count == 1)
            #expect(records.first?.kind == "page_unresponsive")
            #expect(records.first?.testSetupID == "setup_frozen")
            #expect(records.first?.message == "stalled_ms=9120")
        }
    }

    @Test func acceptsEditorReadyAndSwStateTelemetry() async throws {
        try await withApp(app) { _ in
            // Non-failure telemetry: editor_ready is the success denominator,
            // sw_state reports service-worker registration. Both are accepted
            // and persisted, and surface in get_browser_diagnostics by kind.
            let auth = try await loginAsStudent()
            try await insertSetup(id: "setup_tele")
            let bodies = [
                #"{"kind":"editor_ready","testSetupID":"setup_tele","message":"elapsed_ms=3400"}"#,
                #"{"kind":"sw_state","testSetupID":"setup_tele","message":"supported=true;registrations=1"}"#,
            ]
            for body in bodies {
                let res = try await postJSON(body, auth: auth, userAgent: "Mozilla/5.0 (TestRunner)")
                #expect(res.status == .accepted)
            }

            let kinds = try await APIClientDiagnostic.query(on: app.db).all().map(\.kind).sorted()
            #expect(kinds == ["editor_ready", "sw_state"])
        }
    }

    @Test func acceptsKernelReadyTelemetry() async throws {
        try await withApp(app) { _ in
            // kernel_ready is the stronger success signal — the Pyodide kernel
            // (not just the shell) reached idle/busy — so a hung kernel is
            // distinguishable from a healthy boot. Accepted + persisted.
            let auth = try await loginAsStudent()
            try await insertSetup(id: "setup_kready")
            let body = #"""
                {"kind":"kernel_ready","testSetupID":"setup_kready","message":"elapsed_ms=4200;coi=true;waitasync=true;compat=false"}
                """#
            let res = try await postJSON(body, auth: auth, userAgent: "Mozilla/5.0 (TestRunner)")
            #expect(res.status == .accepted)

            let rec = try #require(try await APIClientDiagnostic.query(on: app.db).first())
            #expect(rec.kind == "kernel_ready")
            #expect(rec.testSetupID == "setup_kready")
        }
    }

    @Test func acceptsInIframeKernelPhaseAndErrorTelemetry() async throws {
        try await withApp(app) { _ in
            // The in-iframe collector (jl-kernel-diagnostics.js), forwarded by
            // notebook.js, reports the kernel boot from inside the cross-process
            // iframe: kernel_phase breadcrumbs (phase name in `source`) and
            // kernel_error (failure source + detail). Both are accepted and feed
            // get_browser_diagnostics (kernelBootFunnel / bySource).
            let auth = try await loginAsStudent()
            try await insertSetup(id: "setup_kphase")
            let bodies = [
                #"{"kind":"kernel_phase","testSetupID":"setup_kphase","source":"boot_start"}"#,
                #"{"kind":"kernel_phase","testSetupID":"setup_kphase","source":"kernel_idle"}"#,
                #"{"kind":"kernel_error","testSetupID":"setup_kphase","source":"csp_violation","message":"worker-src blocked data:"}"#,
            ]
            for body in bodies {
                let res = try await postJSON(body, auth: auth, userAgent: "Mozilla/5.0 (TestRunner)")
                #expect(res.status == .accepted)
            }

            let records = try await APIClientDiagnostic.query(on: app.db).all()
            let kinds = records.map(\.kind).sorted()
            #expect(kinds == ["kernel_error", "kernel_phase", "kernel_phase"])
            let err = try #require(records.first { $0.kind == "kernel_error" })
            #expect(err.source == "csp_violation")
            #expect(err.message == "worker-src blocked data:")
        }
    }

    @Test func persistsKernelBootTimeoutSubtype() async throws {
        try await withApp(app) { _ in
            // A kernel that mounts the shell but never reaches ready is reported
            // as watchdog_timeout with the distinct failedChecks
            // ["kernel-boot-timeout"] subtype (vs the positive-evidence
            // "kernel-unhealthy" one), so the silent spinner is finally counted.
            let auth = try await loginAsStudent()
            try await insertSetup(id: "setup_boot_timeout")
            let body = #"""
                {"kind":"watchdog_timeout","testSetupID":"setup_boot_timeout","failedChecks":["kernel-boot-timeout"],"source":"kernel","message":"coi=true;waitasync=false;compat=false"}
                """#
            let res = try await postJSON(body, auth: auth, userAgent: "TestUA/5.0")
            #expect(res.status == .accepted)

            let rec = try #require(try await APIClientDiagnostic.query(on: app.db).first())
            #expect(rec.kind == "watchdog_timeout")
            #expect(rec.failedChecks == "kernel-boot-timeout")
            #expect(rec.source == "kernel")
        }
    }

    @Test func persistsPreflightFailRecord() async throws {
        try await withApp(app) { _ in
            let auth = try await loginAsStudent()
            try await insertSetup(id: "setup_xyz")
            let body = #"""
                {"kind":"preflight_fail","testSetupID":"setup_xyz","failedChecks":["serviceWorker","indexedDB"]}
                """#
            let res = try await postJSON(body, auth: auth, userAgent: "TestUA/1.0")
            #expect(res.status == .accepted)

            let records = try await APIClientDiagnostic.query(on: app.db).all()
            #expect(records.count == 1)
            #expect(records.first?.kind == "preflight_fail")
            #expect(records.first?.failedChecks == "serviceWorker,indexedDB")

        }
    }

    @Test func staleSetupIDIsNullified() async throws {
        try await withApp(app) { _ in
            // If the supplied setup doesn't exist (e.g. it was deleted between
            // the page load and the diagnostic post), the row is still recorded
            // but with testSetupID = nil — no FK violation, no 500.
            let auth = try await loginAsStudent()
            let body = #"{"kind":"watchdog_timeout","testSetupID":"setup_does_not_exist"}"#
            let res = try await postJSON(body, auth: auth)
            #expect(res.status == .accepted)

            let records = try await APIClientDiagnostic.query(on: app.db).all()
            #expect(records.count == 1)
            #expect(records.first?.testSetupID == nil)

        }
    }

    @Test func persistsWatchdogKernelUnhealthySubtype() async throws {
        try await withApp(app) { _ in
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
            #expect(res.status == .accepted)

            let records = try await APIClientDiagnostic.query(on: app.db).all()
            #expect(records.count == 1)
            #expect(records.first?.kind == "watchdog_timeout")
            #expect(records.first?.failedChecks == "kernel-unhealthy")

        }
    }

    @Test func persistsEditorErrorRecord() async throws {
        try await withApp(app) { _ in
            // An uncaught JS error / unhandled rejection on the editor page is
            // posted as kind=editor_error carrying message + stack + source so
            // the actual failure is diagnosable, not just a symbolic bucket.
            let auth = try await loginAsStudent()
            try await insertSetup(id: "setup_editor_err")
            let body = #"""
                {"kind":"editor_error","testSetupID":"setup_editor_err","source":"onerror","message":"TypeError: x is undefined","stack":"at foo (a.js:1:1)\nat bar (b.js:2:2)"}
                """#
            let res = try await postJSON(body, auth: auth, userAgent: "TestUA/3.0")
            #expect(res.status == .accepted)

            let records = try await APIClientDiagnostic.query(on: app.db).all()
            #expect(records.count == 1)
            let rec = try #require(records.first)
            #expect(rec.kind == "editor_error")
            #expect(rec.source == "onerror")
            #expect(rec.message == "TypeError: x is undefined")
            #expect(rec.stack?.contains("at foo") == true)
            #expect(rec.failedChecks == nil)
        }
    }

    @Test func persistsSubmitPhaseBreadcrumb() async throws {
        try await withApp(app) { _ in
            // The browser submit flow posts breadcrumbs (kind=submit_phase,
            // source=the phase, message=elapsed timing) so a freeze during
            // grading leaves a server-visible trail of how far the submit got.
            let auth = try await loginAsStudent()
            try await insertSetup(id: "setup_submit_phase")
            let body = #"""
                {"kind":"submit_phase","testSetupID":"setup_submit_phase","source":"suite_started","message":"elapsed_ms=4200;tests=8"}
                """#
            let res = try await postJSON(body, auth: auth, userAgent: "TestUA/4.0")
            #expect(res.status == .accepted)

            let rec = try #require(try await APIClientDiagnostic.query(on: app.db).first())
            #expect(rec.kind == "submit_phase")
            #expect(rec.source == "suite_started")
            #expect(rec.message == "elapsed_ms=4200;tests=8")
            #expect(rec.userAgent == "TestUA/4.0")
        }
    }

    @Test func persistsAppVersionWhenProvided() async throws {
        try await withApp(app) { _ in
            // Every diagnostic stamps the page build's `app-version` so a report
            // can be attributed to a build — an old value flags a stale browser
            // tab still serving the pre-deploy bundle.
            let auth = try await loginAsStudent()
            try await insertSetup(id: "setup_ver")
            let body = #"""
                {"kind":"kernel_error","testSetupID":"setup_ver","source":"recover_failed","appVersion":"0.4.530"}
                """#
            let res = try await postJSON(body, auth: auth, userAgent: "TestUA/9.0")
            #expect(res.status == .accepted)

            let rec = try #require(try await APIClientDiagnostic.query(on: app.db).first())
            #expect(rec.source == "recover_failed")
            #expect(rec.appVersion == "0.4.530")
        }
    }

    @Test func appVersionIsOptionalAndTrimmed() async throws {
        try await withApp(app) { _ in
            let auth = try await loginAsStudent()
            try await insertSetup(id: "setup_nover")
            // Absent → nil (older clients that don't send it). Checked while it's
            // the only row, so `first()` is unambiguous.
            _ = try await postJSON(
                #"{"kind":"editor_ready","testSetupID":"setup_nover","message":"elapsed_ms=1"}"#,
                auth: auth)
            let none = try #require(try await APIClientDiagnostic.query(on: app.db).first())
            #expect(none.appVersion == nil)

            // Over-long → trimmed to the 32-char column bound.
            let longVersion = String(repeating: "v", count: 40)
            _ = try await postJSON(
                #"{"kind":"editor_ready","testSetupID":"setup_nover","source":"x","appVersion":"\#(longVersion)"}"#,
                auth: auth)
            let rows = try await APIClientDiagnostic.query(on: app.db).all()
            let trimmed = try #require(rows.first { $0.appVersion != nil })
            #expect(trimmed.appVersion?.count == 32)
        }
    }

    @Test func submitPhasesRecordEachPhaseOnceForTheFunnel() async throws {
        try await withApp(app) { _ in
            // The funnel relies on each distinct phase (source) being recorded —
            // so two different phases persist two rows, while a repeat of the same
            // phase within the window dedups to one.
            let auth = try await loginAsStudent()
            try await insertSetup(id: "setup_funnel")
            for source in ["grading_start", "runtime_loaded", "grading_start"] {
                let body = """
                    {"kind":"submit_phase","testSetupID":"setup_funnel","source":"\(source)","message":"elapsed_ms=10"}
                    """
                let res = try await postJSON(body, auth: auth)
                #expect(res.status == .accepted)
            }
            let sources = try await APIClientDiagnostic.query(on: app.db).all()
                .compactMap(\.source).sorted()
            #expect(sources == ["grading_start", "runtime_loaded"])
        }
    }

    @Test func editorErrorMessageAndStackAreTruncated() async throws {
        try await withApp(app) { _ in
            let auth = try await loginAsStudent()
            let longMessage = String(repeating: "m", count: 5000)
            let longStack = String(repeating: "s", count: 10000)
            let body = """
                {"kind":"editor_error","source":"unhandledrejection",\
                "message":"\(longMessage)","stack":"\(longStack)"}
                """
            let res = try await postJSON(body, auth: auth)
            #expect(res.status == .accepted)

            let rec = try #require(try await APIClientDiagnostic.query(on: app.db).first())
            #expect(rec.message?.count == 1024)
            #expect(rec.stack?.count == 4096)
        }
    }

    @Test func editorErrorsWithDifferentSourceAreNotDeduplicated() async throws {
        try await withApp(app) { _ in
            // The error source is part of the dedup key, so onerror vs.
            // unhandledrejection on the same (user, setup, kind) each keep a
            // slot; a repeat of the same source within the window is dropped.
            let auth = try await loginAsStudent()
            let res1 = try await postJSON(
                #"{"kind":"editor_error","testSetupID":"setup_ed","source":"onerror","message":"a"}"#,
                auth: auth)
            #expect(res1.status == .accepted)
            let res2 = try await postJSON(
                #"{"kind":"editor_error","testSetupID":"setup_ed","source":"unhandledrejection","message":"b"}"#,
                auth: auth)
            #expect(res2.status == .accepted)
            let res3 = try await postJSON(
                #"{"kind":"editor_error","testSetupID":"setup_ed","source":"onerror","message":"c"}"#,
                auth: auth)
            #expect(res3.status == .accepted)

            let count = try await APIClientDiagnostic.query(on: app.db).count()
            #expect(count == 2)
        }
    }

    @Test func acceptsMissingTestSetupID() async throws {
        try await withApp(app) { _ in
            let auth = try await loginAsStudent()
            let body = #"{"kind":"watchdog_timeout"}"#
            let res = try await postJSON(body, auth: auth)
            #expect(res.status == .accepted)

            let records = try await APIClientDiagnostic.query(on: app.db).all()
            #expect(records.count == 1)
            #expect(records.first?.testSetupID == nil)

        }
    }

    // MARK: - Rate limiting

    @Test func deduplicatesRepeatedFailuresInWindow() async throws {
        try await withApp(app) { _ in
            let auth = try await loginAsStudent()
            let body = #"{"kind":"watchdog_timeout","testSetupID":"setup_dup"}"#

            // First three posts in quick succession — only the first should
            // persist a row. All three return 202 to the client (the
            // diagnostic was accepted, just deduplicated).
            for _ in 0..<3 {
                let res = try await postJSON(body, auth: auth)
                #expect(res.status == .accepted)
            }

            let count = try await APIClientDiagnostic.query(on: app.db).count()
            #expect(count == 1, "Repeated diagnostics within cooldown should not produce additional rows")

        }
    }

    @Test func differentSetupOrKindAreNotDeduplicated() async throws {
        try await withApp(app) { _ in
            let auth = try await loginAsStudent()

            let res1 = try await postJSON(
                #"{"kind":"watchdog_timeout","testSetupID":"setup_a"}"#, auth: auth)
            #expect(res1.status == .accepted)

            // Different setup → distinct rate-limit key.
            let res2 = try await postJSON(
                #"{"kind":"watchdog_timeout","testSetupID":"setup_b"}"#, auth: auth)
            #expect(res2.status == .accepted)

            // Different kind on same setup → also distinct.
            let res3 = try await postJSON(
                #"{"kind":"preflight_fail","testSetupID":"setup_a","failedChecks":["worker"]}"#,
                auth: auth)
            #expect(res3.status == .accepted)

            let count = try await APIClientDiagnostic.query(on: app.db).count()
            #expect(count == 3)

        }
    }

    // MARK: - Rate limiter unit tests

    @Test func rateLimiterAdmitsOnceWithinCooldown() async throws {
        try await withApp(app) { _ in
            let limiter = ClientDiagnosticsRateLimiter(cooldown: 60)
            let userID = UUID()
            let key = ClientDiagnosticsRateLimiter.Key(
                userID: userID, testSetupID: "s1", kind: "watchdog_timeout"
            )
            let t0 = Date()
            let first = await limiter.admit(key: key, now: t0)
            let second = await limiter.admit(key: key, now: t0.addingTimeInterval(30))
            #expect(first)
            #expect(second == false)

        }
    }

    @Test func rateLimiterReadmitsAfterCooldown() async throws {
        try await withApp(app) { _ in
            let limiter = ClientDiagnosticsRateLimiter(cooldown: 60)
            let userID = UUID()
            let key = ClientDiagnosticsRateLimiter.Key(
                userID: userID, testSetupID: "s1", kind: "watchdog_timeout"
            )
            let t0 = Date()
            _ = await limiter.admit(key: key, now: t0)
            let third = await limiter.admit(key: key, now: t0.addingTimeInterval(61))
            #expect(third)

        }
    }
}
