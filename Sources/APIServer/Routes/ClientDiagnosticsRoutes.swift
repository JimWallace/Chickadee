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
//
// Records flow into client_diagnostics for the instructor dashboard's
// "Students With Browser Errors" card.  Rate-limited per (user, setup, kind)
// so a stuck student reloading 50 times doesn't fill the table.

import Vapor
import Fluent
import Foundation

struct ClientDiagnosticsRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1", "client-diagnostics")
        api.post(use: submit)
    }

    @Sendable
    func submit(req: Request) async throws -> HTTPStatus {
        let caller = try req.auth.require(APIUser.self)
        guard let userID = caller.id else {
            throw Abort(.internalServerError, reason: "Authenticated user has no ID")
        }

        let body = try req.content.decode(ClientDiagnosticBody.self)

        let allowedKinds: Set<String> = ["preflight_fail", "watchdog_timeout"]
        guard allowedKinds.contains(body.kind) else {
            throw Abort(.badRequest, reason: "Unknown kind")
        }

        // De-duplicate within an hour so reloads don't multiply rows.
        let limiter = req.application.clientDiagnosticsRateLimiter
        let key = ClientDiagnosticsRateLimiter.Key(
            userID: userID,
            testSetupID: body.testSetupID,
            kind: body.kind
        )
        let admitted = await limiter.admit(key: key, now: Date())
        guard admitted else { return .accepted }

        // Trim defensive bounds — these are short strings in practice but we
        // do not want a hostile client filling rows with megabyte payloads.
        let trimmedAgent  = req.headers.first(name: .userAgent).map { String($0.prefix(512)) }
        let trimmedChecks = body.failedChecks.map { checks -> String in
            String(checks.joined(separator: ",").prefix(256))
        }

        // Verify the supplied setup exists before storing the FK.  A stale
        // page (e.g. the assignment was deleted between page load and the
        // diagnostic post) should still record a row — just without the
        // setup link — instead of returning 500 from a FK violation.
        var verifiedSetupID: String? = body.testSetupID
        if let candidate = verifiedSetupID,
           try await APITestSetup.find(candidate, on: req.db) == nil {
            verifiedSetupID = nil
        }

        let record = APIClientDiagnostic(
            userID:       userID,
            testSetupID:  verifiedSetupID,
            kind:         body.kind,
            failedChecks: trimmedChecks,
            userAgent:    trimmedAgent
        )
        try await record.save(on: req.db)
        return .accepted
    }
}

// MARK: - Request body

struct ClientDiagnosticBody: Content {
    /// "preflight_fail" | "watchdog_timeout"
    var kind: String
    /// Symbolic names of the capability checks that failed (preflight only).
    var failedChecks: [String]?
    /// The assignment the student was trying to load (best-effort).
    var testSetupID: String?
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
