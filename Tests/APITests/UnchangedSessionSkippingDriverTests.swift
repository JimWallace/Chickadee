// Tests/APITests/UnchangedSessionSkippingDriverTests.swift
//
// Vapor's SessionsMiddleware has no dirty flag: it calls updateSession on the
// way out of every request that arrived with a session cookie. With the Fluent
// driver that made a plain page view an UPDATE on `_fluent_sessions`, the table
// every authenticated request already reads. These tests pin that an untouched
// session skips the write and a modified one still takes it.

import Foundation
import NIOConcurrencyHelpers
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// A stand-in for the Fluent driver that counts what actually reaches it.
private struct RecordingSessionDriver: SessionDriver {
    let stored: SessionData?
    let updateCount = NIOLockedValueBox(0)
    let createCount = NIOLockedValueBox(0)

    func createSession(_ data: SessionData, for request: Request) -> EventLoopFuture<SessionID> {
        createCount.withLockedValue { $0 += 1 }
        return request.eventLoop.makeSucceededFuture(SessionID(string: "created"))
    }

    func readSession(_ sessionID: SessionID, for request: Request) -> EventLoopFuture<SessionData?> {
        request.eventLoop.makeSucceededFuture(stored)
    }

    func updateSession(
        _ sessionID: SessionID,
        to data: SessionData,
        for request: Request
    ) -> EventLoopFuture<SessionID> {
        updateCount.withLockedValue { $0 += 1 }
        return request.eventLoop.makeSucceededFuture(sessionID)
    }

    func deleteSession(_ sessionID: SessionID, for request: Request) -> EventLoopFuture<Void> {
        request.eventLoop.makeSucceededFuture(())
    }
}

@Suite(.serialized) final class UnchangedSessionSkippingDriverTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-session-driver")
    }

    private func makeRequest() -> Request {
        Request(application: app, on: app.eventLoopGroup.next())
    }

    /// The common case by a wide margin: a request reads its session, changes
    /// nothing, and would have written the same bytes back.
    @Test func unchangedSessionSkipsTheWrite() async throws {
        try await withApp(app) { _ in
            let data: SessionData = ["user": "abc", "active_course": "CS136"]
            let base = RecordingSessionDriver(stored: data)
            let driver = UnchangedSessionSkippingDriver(base: base)
            let request = makeRequest()
            let sessionID = SessionID(string: "sid")

            let loaded = try await driver.readSession(sessionID, for: request).get()
            #expect(loaded == data)

            let returned = try await driver.updateSession(sessionID, to: data, for: request).get()
            #expect(returned == sessionID)
            #expect(base.updateCount.withLockedValue { $0 } == 0)
        }
    }

    /// A login, an OIDC handshake, or an active-course switch must still land.
    @Test func modifiedSessionStillWrites() async throws {
        try await withApp(app) { _ in
            let data: SessionData = ["user": "abc"]
            let base = RecordingSessionDriver(stored: data)
            let driver = UnchangedSessionSkippingDriver(base: base)
            let request = makeRequest()
            let sessionID = SessionID(string: "sid")

            _ = try await driver.readSession(sessionID, for: request).get()

            var changed = data
            changed["active_course"] = "CS135"
            _ = try await driver.updateSession(sessionID, to: changed, for: request).get()
            #expect(base.updateCount.withLockedValue { $0 } == 1)
        }
    }

    /// Removing a key is a change too — comparing only added keys would leave a
    /// logged-out session on disk.
    @Test func clearingAKeyStillWrites() async throws {
        try await withApp(app) { _ in
            let data: SessionData = ["user": "abc", "oidc_state": "xyz"]
            let base = RecordingSessionDriver(stored: data)
            let driver = UnchangedSessionSkippingDriver(base: base)
            let request = makeRequest()
            let sessionID = SessionID(string: "sid")

            _ = try await driver.readSession(sessionID, for: request).get()

            var cleared = data
            cleared["oidc_state"] = nil
            _ = try await driver.updateSession(sessionID, to: cleared, for: request).get()
            #expect(base.updateCount.withLockedValue { $0 } == 1)
        }
    }

    /// With nothing read for this request there is no baseline to compare
    /// against, so the write must go through rather than be assumed redundant.
    @Test func updateWithoutAPriorReadAlwaysWrites() async throws {
        try await withApp(app) { _ in
            let base = RecordingSessionDriver(stored: nil)
            let driver = UnchangedSessionSkippingDriver(base: base)
            let request = makeRequest()

            _ = try await driver.updateSession(
                SessionID(string: "sid"), to: ["user": "abc"], for: request
            ).get()
            #expect(base.updateCount.withLockedValue { $0 } == 1)
        }
    }

    /// A session id that no longer resolves reads back nil, and the middleware
    /// then creates a fresh session — nothing is cached that could make the
    /// create look redundant.
    @Test func missingSessionCreatesRatherThanSkips() async throws {
        try await withApp(app) { _ in
            let base = RecordingSessionDriver(stored: nil)
            let driver = UnchangedSessionSkippingDriver(base: base)
            let request = makeRequest()

            let loaded = try await driver.readSession(SessionID(string: "gone"), for: request).get()
            #expect(loaded == nil)

            _ = try await driver.createSession(["user": "abc"], for: request).get()
            #expect(base.createCount.withLockedValue { $0 } == 1)
            #expect(base.updateCount.withLockedValue { $0 } == 0)
        }
    }
}
