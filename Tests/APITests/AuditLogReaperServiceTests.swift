// Tests/APITests/AuditLogReaperServiceTests.swift
//
// Coverage for the audit_log retention reaper added in issue #555.

import Fluent
import Foundation
import XCTVapor
import XCTest

@testable import chickadee_server

final class AuditLogReaperServiceTests: XCTestCase {

    private var app: Application!

    override func setUp() async throws {
        app = try await makeTestApp(prefix: "chickadee-auditreaper")
    }

    override func tearDown() async throws {
        try await app.tearDownTestApp()
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
        let id = try XCTUnwrap(entry.id)
        entry.createdAt = Date().addingTimeInterval(-Double(daysOld) * 86_400)
        try await entry.save(on: app.db)
        return id
    }

    private func entryExists(_ id: UUID) async throws -> Bool {
        try await APIAuditLogEntry.find(id, on: app.db) != nil
    }

    // MARK: - Reaper behaviour

    func testReaper_deletesEntriesOlderThanMaxAge() async throws {
        let stale = try await seedEntry(action: "test.stale", daysOld: 120)
        let fresh = try await seedEntry(action: "test.fresh", daysOld: 5)

        try await reapStaleAuditLogEntries(
            on: app.db,
            logger: app.logger,
            maxAge: 90 * 86_400
        )

        let staleStillThere = try await entryExists(stale)
        let freshStillThere = try await entryExists(fresh)
        XCTAssertFalse(staleStillThere, "Entry older than maxAge should be deleted")
        XCTAssertTrue(freshStillThere, "Entry inside the retention window must be preserved")
    }

    func testReaper_zeroMaxAgeIsNoOp() async throws {
        // Operators piping to external sinks disable the reaper with
        // AUDIT_LOG_RETENTION_DAYS=0; verify the helper short-circuits.
        let recent = try await seedEntry(action: "test.recent", daysOld: 200)
        try await reapStaleAuditLogEntries(
            on: app.db,
            logger: app.logger,
            maxAge: 0
        )
        let stillThere = try await entryExists(recent)
        XCTAssertTrue(stillThere, "maxAge == 0 must be a no-op")
    }

    func testReaper_handlesEmptyTableCleanly() async throws {
        // No rows + no error — nothing to do, no throw.
        try await reapStaleAuditLogEntries(
            on: app.db,
            logger: app.logger,
            maxAge: 1
        )
    }
}
