// Tests/APITests/AuditLogReaperServiceTests.swift
//
// Coverage for the audit_log retention reaper added in issue #555.

import Fluent
import Foundation
import SQLKit
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
    /// days ago.  Fluent's @Timestamp(.create) populates created_at to "now"
    /// on save, so we explicitly UPDATE afterwards.
    @discardableResult
    private func seedEntry(action: String, daysOld: Int) async throws -> UUID {
        let entry = APIAuditLogEntry(action: action)
        try await entry.save(on: app.db)
        let id = try XCTUnwrap(entry.id)

        let cutoff = Date().addingTimeInterval(-Double(daysOld) * 86_400)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let backdated = formatter.string(from: cutoff)
        guard let sql = app.db as? SQLDatabase else {
            XCTFail("Expected SQLDatabase")
            return id
        }
        try await sql.raw(
            "UPDATE audit_log SET created_at = \(bind: backdated) WHERE id = \(bind: id.uuidString)"
        ).run()
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
