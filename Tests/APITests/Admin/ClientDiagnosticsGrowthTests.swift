// Tests/APITests/Admin/ClientDiagnosticsGrowthTests.swift
//
// A student could grow `client_diagnostics` without bound (#2900): the rate
// limit keyed on a client-chosen setup ID that need not exist, nothing capped
// one user's rows, and nothing ever deleted a row. These cover the verified
// setup key, the per-user hourly cap and the 90-day retention sweep.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3)))
struct ClientDiagnosticsGrowthTests {

    // MARK: - Limiter

    private func key(_ user: UUID, setup: String? = nil, source: String) -> ClientDiagnosticsRateLimiter.Key {
        ClientDiagnosticsRateLimiter.Key(userID: user, testSetupID: setup, kind: "editor_error", subkey: source)
    }

    @Test func oneUserIsCappedPerWindowWhateverTheKeys() async {
        let limiter = ClientDiagnosticsRateLimiter(cooldown: 3600, maxPerUserPerWindow: 3)
        let user = UUID()
        let now = Date()
        var admitted = 0
        for index in 0..<10 {
            let accepted = await limiter.admit(key: key(user, source: "s\(index)"), now: now)
            admitted += accepted ? 1 : 0
        }
        #expect(admitted == 3)
        // Another user has their own allowance.
        #expect(await limiter.admit(key: key(UUID(), source: "s0"), now: now))
    }

    @Test func theCapResetsWhenTheWindowPasses() async {
        let limiter = ClientDiagnosticsRateLimiter(cooldown: 3600, maxPerUserPerWindow: 1)
        let user = UUID()
        let now = Date()
        #expect(await limiter.admit(key: key(user, source: "a"), now: now))
        #expect(await !limiter.admit(key: key(user, source: "b"), now: now))
        #expect(await limiter.admit(key: key(user, source: "b"), now: now.addingTimeInterval(3601)))
    }

    // MARK: - Route

    @Test func unknownSetupIDsShareOneSlot() async throws {
        try await withTestApp(prefix: "chickadee-cdg") { app in
            let cookie = try await loginUser(username: "cdg_student", password: "pass", role: "student", on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)
            for index in 0..<5 {
                let res = try await app.asyncSendRequest(.POST, "/api/v1/client-diagnostics") { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(
                        string: #"{"kind":"watchdog_timeout","testSetupID":"random_\#(index)"}"#)
                }
                #expect(res.status == .accepted)
            }
            let rows = try await APIClientDiagnostic.query(on: app.db).count()
            #expect(rows == 1)
        }
    }

    // MARK: - Retention

    @Test func theSweepDeletesRowsOlderThanNinetyDays() async throws {
        try await withTestApp(prefix: "chickadee-cdg-retention") { app in
            let user = try await makeTestUser(on: app, username: "cdg_owner")
            let old = APIClientDiagnostic(
                userID: try user.requireID(), testSetupID: nil, kind: "editor_ready", failedChecks: nil,
                userAgent: nil, message: "old")
            let recent = APIClientDiagnostic(
                userID: try user.requireID(), testSetupID: nil, kind: "editor_ready", failedChecks: nil,
                userAgent: nil, message: "recent")
            try await old.save(on: app.db)
            try await recent.save(on: app.db)
            let now = Date()
            try await APIClientDiagnostic.query(on: app.db)
                .filter(\.$id == old.requireID())
                .set(\.$createdAt, to: now.addingTimeInterval(-91 * 86_400))
                .update()

            await ClientDiagnosticsReaper.purgeExpired(db: app.db, logger: app.logger, now: now)

            let left = try await APIClientDiagnostic.query(on: app.db).all().compactMap(\.message)
            #expect(left == ["recent"])
        }
    }
}
