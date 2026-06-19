// APIServer/Routes/ClientDiagnosticsRoutes.swift
//
// Accepts client-side diagnostic posts from the student submit page when the
// in-browser editor (JupyterLite + Pyodide) cannot start.  Two kinds of
// failures are reported:
//
//   "preflight_fail"    — a capability check failed before the iframe was
//                          mounted (no service workers, IndexedDB blocked,
//                          WebAssembly disabled, etc.)
//   "watchdog_timeout"  — the iframe loaded but the JupyterLite kernel did
//                          not become ready within the 45-second watchdog
//                          window
//   "editor_error"      — an uncaught error / unhandled promise rejection on
//                          the editor page (window.onerror / unhandledrejection),
//                          carrying message + stack for diagnosis
//   "page_unresponsive" — the editor page's main thread hard-froze; a dedicated
//                          worker (which keeps running while the page is frozen)
//                          beaconed it, since the blocked main thread cannot
//                          (message carries "stalled_ms=…")
//
// "editor_error" and the kernel-unhealthy "watchdog_timeout" subtype may carry
// `message` / `stack` / `source`.  These are JupyterLite/Pyodide infrastructure
// errors captured on the editor-load path only — never student-code execution —
// so no student-authored content is stored here.
//
// Records flow into client_diagnostics for the instructor dashboard's
// "Browser Errors" card and the admin diagnostic tooling.  Rate-limited per
// (user, setup, kind, source) so a stuck student reloading 50 times doesn't
// fill the table, while distinct error sources are still preserved.

import Fluent
import Foundation
import Vapor

struct ClientDiagnosticsRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1", "client-diagnostics")
        api.post(use: submit)
    }

    @Sendable
    func submit(req: Request) async throws -> HTTPStatus {
        let caller = try req.auth.require(APIUser.self)
        guard let userID = caller.id else {
            throw AppError.internalFailure(reason: "Authenticated user has no ID")
        }

        let body = try req.content.decode(ClientDiagnosticBody.self)

        // "submit_phase" / "submit_error" are breadcrumbs from the browser
        // grading/submission flow (source = phase name, message = "elapsed_ms=…").
        // They let us see how far a submit got when the page freezes during
        // grading — which produces no exception and no result POST, so it is
        // otherwise invisible to the server. Like the editor errors, these are
        // infrastructure breadcrumbs (phase + timing + a pipeline error string),
        // never student-code output, so no student-authored content is stored.
        // "page_unresponsive" is the main-thread freeze beacon: the editor page
        // hard-froze (a synchronous Pyodide hang with no SharedArrayBuffer /
        // service-worker sync path) and a dedicated worker — which keeps running
        // while the page is frozen — reported it. Such freezes are otherwise
        // invisible: the blocked main thread can't post anything itself.
        // "editor_ready" and "sw_state" are non-failure telemetry: editor_ready
        // is the success denominator (the editor shell came up, message
        // "elapsed_ms=…") so we can compute a success RATE; sw_state reports
        // whether JupyterLite's service worker registered (message
        // "supported=…;registrations=…"), which diagnoses the "Kernel Unknown"
        // failure mode per browser/device.
        let allowedKinds: Set<String> = [
            "preflight_fail", "watchdog_timeout", "editor_error",
            "submit_phase", "submit_error", "page_unresponsive",
            "editor_ready", "sw_state",
        ]
        guard allowedKinds.contains(body.kind) else {
            throw AppError.badRequest(reason: "Unknown kind")
        }

        // Trim defensive bounds — these are short strings in practice but we
        // do not want a hostile client filling rows with large payloads.
        let trimmedAgent = req.headers.first(name: .userAgent).map { String($0.prefix(512)) }
        let trimmedChecks = body.failedChecks.map { checks -> String in
            String(checks.joined(separator: ",").prefix(256))
        }
        let trimmedSource = body.source.map { String($0.prefix(64)) }
        let trimmedMessage = body.message.map { String($0.prefix(1024)) }
        let trimmedStack = body.stack.map { String($0.prefix(4096)) }

        // De-duplicate within an hour so reloads don't multiply rows.  The
        // source is part of the key so distinct error origins (onerror vs.
        // unhandledrejection vs. kernel) each keep a slot rather than the first
        // one suppressing the rest; preflight/watchdog records pass nil and so
        // dedupe by (user, setup, kind) exactly as before.
        let limiter = req.application.clientDiagnosticsRateLimiter
        let key = ClientDiagnosticsRateLimiter.Key(
            userID: userID,
            testSetupID: body.testSetupID,
            kind: body.kind,
            subkey: trimmedSource
        )
        let admitted = await limiter.admit(key: key, now: Date())
        guard admitted else { return .accepted }

        // Verify the supplied setup exists before storing the FK.  A stale
        // page (e.g. the assignment was deleted between page load and the
        // diagnostic post) should still record a row — just without the
        // setup link — instead of returning 500 from a FK violation.
        var verifiedSetupID: String? = body.testSetupID
        if let candidate = verifiedSetupID,
            try await APITestSetup.find(candidate, on: req.db) == nil
        {
            verifiedSetupID = nil
        }

        let record = APIClientDiagnostic(
            userID: userID,
            testSetupID: verifiedSetupID,
            kind: body.kind,
            failedChecks: trimmedChecks,
            userAgent: trimmedAgent,
            message: trimmedMessage,
            stack: trimmedStack,
            source: trimmedSource
        )
        try await record.save(on: req.db)
        return .accepted
    }
}

// MARK: - Request body

struct ClientDiagnosticBody: Content {
    /// "preflight_fail" | "watchdog_timeout" | "editor_error"
    var kind: String
    /// Symbolic names of the capability checks that failed (preflight only).
    var failedChecks: [String]?
    /// The assignment the student was trying to load (best-effort).
    var testSetupID: String?
    /// Error message (editor_error + kernel-unhealthy watchdog).
    var message: String?
    /// JS stack trace (editor_error).
    var stack: String?
    /// Origin of the error: "onerror" | "unhandledrejection" | "kernel".
    var source: String?
}

// MARK: - Rate limiter

/// In-memory rate limiter: one row per (user, setupID, kind) per hour.
/// State is per-process and resets on restart — fine for this use case
/// because the dashboard query already groups by user, so duplicate rows
/// across restarts collapse to one student in the metric.
actor ClientDiagnosticsRateLimiter {
    struct Key: Hashable, Sendable {
        let userID: UUID
        let testSetupID: String?
        let kind: String
        /// Optional sub-discriminator (the error source) so distinct origins
        /// aren't collapsed by the (user, setup, kind) dedup. nil for
        /// preflight/watchdog records.
        var subkey: String?
    }

    private var lastAdmitted: [Key: Date] = [:]
    private let cooldown: TimeInterval

    init(cooldown: TimeInterval = 3600) {
        self.cooldown = cooldown
    }

    /// Returns true if the key has not been admitted within the cooldown
    /// window, and records this admission.  False otherwise.
    func admit(key: Key, now: Date) -> Bool {
        if let previous = lastAdmitted[key], now.timeIntervalSince(previous) < cooldown {
            return false
        }
        lastAdmitted[key] = now
        // Cheap eviction: every ~1000 admissions, drop anything older than 24h.
        if lastAdmitted.count > 1000 {
            let stale = now.addingTimeInterval(-24 * 60 * 60)
            lastAdmitted = lastAdmitted.filter { $0.value >= stale }
        }
        return true
    }
}

struct ClientDiagnosticsRateLimiterKey: StorageKey {
    typealias Value = ClientDiagnosticsRateLimiter
}

extension Application {
    var clientDiagnosticsRateLimiter: ClientDiagnosticsRateLimiter {
        if let existing = storage[ClientDiagnosticsRateLimiterKey.self] {
            return existing
        }
        let new = ClientDiagnosticsRateLimiter()
        storage[ClientDiagnosticsRateLimiterKey.self] = new
        return new
    }
}
