// Tests/APITests/SessionReaperServiceTests.swift
//
// Covers reapStaleSessions — the hourly sweep that ages stale rows out of
// Vapor's `_fluent_sessions` table.  The reaper previously hand-rolled raw SQL
// comparing the `timestamp` column to a text-bound cutoff, which SQLite
// accepted but Postgres rejected (`timestamp < text`), so the sweep threw every
// hour and sessions never got reaped.  The fix moved it onto a Fluent typed
// query (matching AuditLogReaperService / ActivityEventReaperService); these
// tests pin the deletion semantics AND, when run under the Postgres CI job,
// prove the sweep no longer throws on Postgres.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class SessionReaperServiceTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-reaper")
    }

    /// Creates a well-formed `_fluent_sessions` row via Vapor's own
    /// `SessionRecord` (so the json `data` column is written correctly), then
    /// stamps `created_at` explicitly through the reaper's Fluent model so the
    /// timestamp comparison is exercised identically on SQLite and Postgres
    /// (rather than leaning on the column DEFAULT, whose SQLite text encoding
    /// would make the comparison trivially true/false).
    @discardableResult
    private func makeSession(key: String, createdAt: Date?) async throws -> UUID {
        let record = SessionRecord(key: SessionID(string: key), data: SessionData())
        try await record.create(on: app.db)
        let id = try record.requireID()
        let reapable = try #require(try await ReapableSession.find(id, on: app.db))
        reapable.createdAt = createdAt
        try await reapable.update(on: app.db)
        return id
    }

    @Test func reapsStaleSessionsKeepingRecentAndNullCreatedAt() async throws {
        try await withApp(app) { _ in
            let oldID = try await makeSession(
                key: "reaper-old", createdAt: Date(timeIntervalSinceNow: -30 * 24 * 60 * 60))
            let recentID = try await makeSession(
                key: "reaper-recent", createdAt: Date(timeIntervalSinceNow: -3600))
            // Pre-migration rows have NULL created_at and must be preserved.
            let nullID = try await makeSession(key: "reaper-null", createdAt: nil)

            #expect(try await ReapableSession.query(on: app.db).count() == 3)

            // Default 8-day window. Reaching here without throwing is itself the
            // Postgres regression guard (`timestamp < text` used to throw).
            try await reapStaleSessions(on: app.db, logger: app.logger)

            #expect(try await ReapableSession.find(oldID, on: app.db) == nil)
            #expect(try await ReapableSession.find(recentID, on: app.db) != nil)
            #expect(try await ReapableSession.find(nullID, on: app.db) != nil)
        }
    }

    @Test func reapingIsANoOpWhenNothingIsStale() async throws {
        try await withApp(app) { _ in
            let recentID = try await makeSession(
                key: "reaper-fresh", createdAt: Date(timeIntervalSinceNow: -60))

            try await reapStaleSessions(on: app.db, logger: app.logger)

            #expect(try await ReapableSession.find(recentID, on: app.db) != nil)
        }
    }
}
