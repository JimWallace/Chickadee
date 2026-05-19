// Tests/APITests/AuditLogReaperServiceTests.swift
//
// Coverage for the audit_log retention reaper added in issue #555.

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite(.serialized) final class AuditLogReaperServiceTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-auditreaper")
    }

    /// Inserts an audit_log row and back-dates its `created_at` to `daysOld`
    /// days ago.  `@Timestamp(on: .create)` only fires on first insert, so a
    /// second save with an explicit `createdAt` preserves the override —
    /// portable across SQLite and Postgres (a raw SQL UPDATE binding the
    /// timestamp as text trips Postgres's strict timestamptz typing).
    @discardableResult
    private func seedEntry(action: String, daysOld: Int) async throws -> UUID {
        let entry = APIAuditLogEntry(action: action)
        try await entry.save(on: app.db)
        let id = try #require(entry.id)
        entry.createdAt = Date().addingTimeInterval(-Double(daysOld) * 86_400)
        try await entry.save(on: app.db)
        return id
    }

    private func entryExists(_ id: UUID) async throws -> Bool {
        try await APIAuditLogEntry.find(id, on: app.db) != nil
    }

    // MARK: - Reaper behaviour

    @Test func reaper_deletesEntriesOlderThanMaxAge() async throws {
        try await withApp(app) { _ in
            let stale = try await seedEntry(action: "test.stale", daysOld: 120)
            let fresh = try await seedEntry(action: "test.fresh", daysOld: 5)

            try await reapStaleAuditLogEntries(
                on: app.db,
                logger: app.logger,
                maxAge: 90 * 86_400
            )

            let staleStillThere = try await entryExists(stale)
            let freshStillThere = try await entryExists(fresh)
            #expect(staleStillThere == false, "Entry older than maxAge should be deleted")
            #expect(freshStillThere, "Entry inside the retention window must be preserved")

        }
    }

    @Test func reaper_zeroMaxAgeIsNoOp() async throws {
        try await withApp(app) { _ in
            // Operators piping to external sinks disable the reaper with
            // AUDIT_LOG_RETENTION_DAYS=0; verify the helper short-circuits.
            let recent = try await seedEntry(action: "test.recent", daysOld: 200)
            try await reapStaleAuditLogEntries(
                on: app.db,
                logger: app.logger,
                maxAge: 0
            )
            let stillThere = try await entryExists(recent)
            #expect(stillThere, "maxAge == 0 must be a no-op")

        }
    }

    @Test func reaper_handlesEmptyTableCleanly() async throws {
        try await withApp(app) { _ in
            // No rows + no error — nothing to do, no throw.
            try await reapStaleAuditLogEntries(
                on: app.db,
                logger: app.logger,
                maxAge: 1
            )

        }
    }
}
