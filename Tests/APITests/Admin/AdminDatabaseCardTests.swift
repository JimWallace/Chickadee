// Tests/APITests/Admin/AdminDatabaseCardTests.swift
//
// The admin Overview's Database card and its change tracking
// (`DatabaseProfileService`), against the test Postgres.
//
// The card shows the live values; a read that fails shows "unavailable" and
// the page still renders. A changed configuration writes one audit entry and
// moves "Since" and "Previously"; an unchanged one writes none; two servers
// recording the same change at once write one. `get_deployment_info` reports
// the cached reading.

import Core
import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) final class AdminDatabaseCardTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-admin-database")
    }

    private func fingerprint(version: String = "16.4", maxConnections: Int = 200) -> DatabaseFingerprint {
        DatabaseFingerprint(
            serverVersion: version, dataChecksums: true, maxConnections: maxConnections,
            statStatementsLoaded: false, serverEncoding: "UTF8", collation: "C", mcpPoolSeparateRole: false)
    }

    private func auditEntries() async throws -> [APIAuditLogEntry] {
        try await APIAuditLogEntry.query(on: app.db)
            .filter(\.$action == AuditAction.databaseConfigurationChanged.rawValue)
            .all()
    }

    private func liveSetting(_ name: String) async throws -> String {
        let sql = try #require(app.db as? any SQLDatabase)
        let row = try #require(try await sql.raw("SELECT current_setting(\(bind: name)) AS value").first())
        return try row.decode(column: "value", as: String.self)
    }

    @Test func overviewShowsTheLiveDatabaseConfiguration() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("database_card_admin", on: app)
            let response = try await getResponse("/admin", cookie: cookie, on: app)
            #expect(response.status == .ok)
            let body = response.body.string

            #expect(body.contains("<h2>Database</h2>"))
            #expect(body.contains(try await liveSetting("server_version")))
            #expect(body.contains(try await liveSetting("max_connections")))
            #expect(body.contains(try await liveSetting("server_encoding")))
            #expect(body.contains("Shares the main pool"))
            #expect(!body.contains("unavailable"), "every read succeeds against the test database")

            // The first reading is stored, with nothing before it and no audit entry.
            let stored = try #require(
                try await DatabaseProfileRecord.find(DatabaseProfileRecord.currentKey, on: app.db))
            #expect(stored.previous == nil)
            #expect(try await auditEntries().isEmpty)
        }
    }

    @Test func aFailedReadShowsUnavailableAndThePageStillRenders() async throws {
        try await withApp(app) { _ in
            // A dedicated MCP pool that cannot connect: nothing listens on port 1.
            let configuration = SQLPostgresConfiguration(
                hostname: "127.0.0.1", port: 1, username: "nobody", password: "nothing", database: "none",
                tls: .disable)
            app.databases.use(.postgres(configuration: configuration, maxConnectionsPerEventLoop: 1), as: .mcp)
            app.usesDedicatedMCPDatabase = true

            let cookie = try await loginAsAdmin("database_card_unavailable", on: app)
            let response = try await getResponse("/admin", cookie: cookie, on: app)
            #expect(response.status == .ok)
            let body = response.body.string
            #expect(body.contains("unavailable"))
            #expect(body.contains(try await liveSetting("server_version")), "the other reads still show")

            // A partial reading records nothing.
            #expect(try await DatabaseProfileRecord.find(DatabaseProfileRecord.currentKey, on: app.db) == nil)
        }
    }

    @Test func anMCPPoolOnTheMainRoleIsReportedAsTheSameRole() async throws {
        try await withApp(app) { _ in
            try await registerEmptyPostgresSchemaPool(on: app, as: .mcp)
            app.usesDedicatedMCPDatabase = true

            let snapshot = await DatabaseProfileService.read(app: app)
            #expect(snapshot.mcpPool == .sameRole)
            #expect(snapshot.fingerprint?.mcpPoolSeparateRole == false)
        }
    }

    @Test func aChangeWritesOneAuditEntryAndMovesSinceAndPrevious() async throws {
        try await withApp(app) { _ in
            let first = Date(timeIntervalSince1970: 1_790_000_000)
            let later = first.addingTimeInterval(3_600)
            try await DatabaseProfileService.record(fingerprint(), now: first, app: app)
            try await DatabaseProfileService.record(fingerprint(), now: later, app: app)
            #expect(try await auditEntries().isEmpty, "an unchanged configuration writes no entry")

            let upgraded = fingerprint(version: "18.1", maxConnections: 300)
            let stored = try await DatabaseProfileService.record(upgraded, now: later, app: app)
            #expect(stored.fingerprint == upgraded)
            #expect(stored.previous == fingerprint())
            #expect(abs(stored.since.timeIntervalSince(later)) < 1)

            let entries = try await auditEntries()
            #expect(entries.count == 1)
            let metadata = try #require(entries.first).metadataDictionary
            #expect(metadata["server_version"] == "16.4 → 18.1")
            #expect(metadata["max_connections"] == "200 → 300")
            #expect(metadata["collation"] == nil, "an unchanged value is not named")

            #expect(upgraded.changes(from: fingerprint()).map(\.key) == ["server_version", "max_connections"])
        }
    }

    @Test func twoServersRecordingTheSameChangeWriteOneEntry() async throws {
        try await withApp(app) { app in
            try await DatabaseProfileService.record(fingerprint(), app: app)
            for round in 1...5 {
                let next = fingerprint(maxConnections: 200 + round)
                async let one = DatabaseProfileService.record(next, app: app)
                async let two = DatabaseProfileService.record(next, app: app)
                _ = try await (one, two)
                #expect(try await auditEntries().count == round, "round \(round)")
            }
        }
    }

    @Test func overviewShowsPreviouslyAfterAChange() async throws {
        try await withApp(app) { _ in
            // The stored row says the database used to be something else.
            let live = try #require(await DatabaseProfileService.read(app: app).fingerprint)
            let old = DatabaseFingerprint(
                serverVersion: "16.4", dataChecksums: live.dataChecksums, maxConnections: live.maxConnections,
                statStatementsLoaded: live.statStatementsLoaded, serverEncoding: live.serverEncoding,
                collation: live.collation, mcpPoolSeparateRole: live.mcpPoolSeparateRole)
            try await DatabaseProfileService.record(old, app: app)

            let cookie = try await loginAsAdmin("database_card_previous", on: app)
            let body = try await getResponse("/admin", cookie: cookie, on: app).body.string
            #expect(body.contains("Previously PostgreSQL 16.4."))
            #expect(try await auditEntries().count == 1)
        }
    }

    @Test func getDeploymentInfoReportsTheCachedReading() async throws {
        try await withApp(app) { _ in
            let context = adminMCPContext(app, subject: "root")
            let before = try await GetDeploymentInfoTool().execute(.init(), context)
            #expect(before.database == nil, "no reading before the first one")

            _ = await DatabaseProfileService.snapshot(app: app)
            let output = try await GetDeploymentInfoTool().execute(.init(), context)
            let database = try #require(output.database)
            #expect(database.serverVersion == (try await liveSetting("server_version")))
            #expect(database.majorVersion == (Int(try await liveSetting("server_version_num")) ?? 0) / 10_000)
            #expect(database.maxConnections == Int(try await liveSetting("max_connections")))
            #expect(database.dataChecksums != nil)
            #expect(database.statStatementsLoaded != nil)
            #expect(database.collation != nil)
            #expect(database.sizeBytes != nil)
            #expect(database.mcpPoolConfigured == false)
            #expect(database.mcpPoolSeparateRole == false)
            #expect(database.since != nil)

            let encoded = try JSONValue(encoding: output)
            let schema = try #require(GetDeploymentInfoTool.outputSchema)
            let violations = MCPOutputSchemaValidator.violations(of: encoded, against: schema)
            #expect(violations.isEmpty, "\(violations)")
        }
    }
}
