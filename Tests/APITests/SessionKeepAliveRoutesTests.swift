// Tests/APITests/SessionKeepAliveRoutesTests.swift
//
// Integration tests for POST /session/keepalive — the endpoint the client
// inactivity watchdog calls to extend a session ("Stay signed in" and the
// throttled notebook-activity ping).

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct SessionKeepAliveRoutesTests {

    private func makeApp() async throws -> Application {
        try await makeTestApp(prefix: "chickadee-keepalive")
    }

    @Test func keepAliveRefreshesLastSeenAndReturnsRemaining() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginUser(
                username: "student", password: "pass1234", role: "student", on: app)

            // Backdate lastSeenAt so we can prove the handler refreshed it.
            try await APIUser.query(on: app.db)
                .filter(\.$username == "student")
                .set(\.$lastSeenAt, to: Date().addingTimeInterval(-10 * 60))
                .update()

            let (token, _) = try await csrfFields(for: "/account", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/session/keepalive",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    req.headers.add(name: "x-csrf-token", value: token)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(KeepAliveResponse.self)
                    #expect(body.secondsRemaining == 30 * 60)
                })

            let user = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "student").first())
            let lastSeen = try #require(user.lastSeenAt)
            // Refreshed to ~now (well inside the 10-minute backdate).
            #expect(lastSeen.timeIntervalSinceNow > -30)
        }
    }

    @Test func keepAliveWithoutCSRFTokenIsForbidden() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginUser(
                username: "student", password: "pass1234", role: "student", on: app)
            try await app.asyncTest(
                .POST, "/session/keepalive",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })
        }
    }

    @Test func keepAliveUnauthenticatedIsRejected() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                .POST, "/session/keepalive",
                afterResponse: { res in
                    #expect(res.status != .ok)
                })
        }
    }
}
