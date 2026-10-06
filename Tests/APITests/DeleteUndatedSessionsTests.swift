// Tests/APITests/DeleteUndatedSessionsTests.swift
//
// The one-time delete of session rows with no `created_at` (#2281). The
// reaper skips such rows, and Vapor never fills the column on an update, so
// this migration is the only thing that removes them.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class DeleteUndatedSessionsTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-undated-sessions")
    }

    /// A session row as Vapor writes it, with `created_at` then set to
    /// `createdAt` through the reaper's model.
    private func makeSession(key: String, createdAt: Date?) async throws -> UUID {
        let record = SessionRecord(key: SessionID(string: key), data: SessionData())
        try await record.create(on: app.db)
        let id = try record.requireID()
        let reapable = try #require(try await ReapableSession.find(id, on: app.db))
        reapable.createdAt = createdAt
        try await reapable.update(on: app.db)
        return id
    }

    @Test func deletesOnlyTheRowsWithNoCreatedAt() async throws {
        try await withApp(app) { app in
            let undatedID = try await makeSession(key: "undated", createdAt: nil)
            let datedID = try await makeSession(key: "dated", createdAt: Date())

            try await DeleteUndatedSessions().prepare(on: app.db)

            #expect(try await ReapableSession.find(undatedID, on: app.db) == nil)
            #expect(try await ReapableSession.find(datedID, on: app.db) != nil)
        }
    }

    /// A row Vapor inserts takes the column DEFAULT, so the migration leaves
    /// every session created after it alone.
    @Test func keepsARowThatTookTheColumnDefault() async throws {
        try await withApp(app) { app in
            let record = SessionRecord(key: SessionID(string: "defaulted"), data: SessionData())
            try await record.create(on: app.db)
            let id = try record.requireID()

            try await DeleteUndatedSessions().prepare(on: app.db)

            #expect(try await ReapableSession.find(id, on: app.db) != nil)
        }
    }
}
