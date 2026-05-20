import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized)
struct MigrationNamespaceReconcilerTests {

    private func migrationNames(_ db: Database) async throws -> [String] {
        try await MigrationLog.query(on: db).all().map(\.name)
    }

    /// Headline scenario: a restored pre-rename snapshot records migrations under
    /// `chickadee_server.*`; after reconciliation the current build sees them as
    /// applied, so `autoMigrate` is a clean no-op instead of re-running
    /// `CreateUsers` and colliding with the existing schema.
    @Test func renamesLegacyNamespaceSoRestoredSnapshotMigratesCleanly() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)

            let currentPrefix =
                String(String(reflecting: CreateUsers.self).prefix { $0 != "." }) + "."
            #expect(currentPrefix == "APIServer.")

            // Simulate a pre-rename DB by rewriting every current-namespace row to
            // the legacy `chickadee_server.*`.
            for log in try await MigrationLog.query(on: app.db).all()
            where log.name.hasPrefix(currentPrefix) {
                log.name = "chickadee_server." + String(log.name.dropFirst(currentPrefix.count))
                try await log.save(on: app.db)
            }
            let flipped = try await migrationNames(app.db)
            #expect(flipped.contains("chickadee_server.CreateUsers"))
            #expect(!flipped.contains("APIServer.CreateUsers"))

            try reconcileLegacyMigrationNamespace(on: app)

            let reconciled = try await migrationNames(app.db)
            #expect(!reconciled.contains { $0.hasPrefix("chickadee_server.") })
            #expect(reconciled.contains("APIServer.CreateUsers"))

            // Would throw (42P07 re-create) if any migration were still seen as
            // unapplied; a clean return is the assertion.
            try await app.autoMigrate()
        }
    }

    /// If both the legacy and canonical rows somehow exist, the legacy duplicate
    /// is dropped rather than renamed into a collision.
    @Test func dropsLegacyRowWhenCanonicalAlreadyExists() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)

            // APIServer.CreateUsers already exists from autoMigrate; add a stray
            // legacy duplicate alongside it.
            let dup = MigrationLog()
            dup.name = "chickadee_server.CreateUsers"
            dup.batch = 1
            try await dup.save(on: app.db)

            try reconcileLegacyMigrationNamespace(on: app)

            let names = try await migrationNames(app.db)
            #expect(!names.contains("chickadee_server.CreateUsers"))
            #expect(names.filter { $0 == "APIServer.CreateUsers" }.count == 1)
        }
    }

    /// On a normal database (no legacy rows) reconciliation changes nothing.
    @Test func noOpWhenNoLegacyRowsPresent() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)
            let before = try await migrationNames(app.db).sorted()
            try reconcileLegacyMigrationNamespace(on: app)
            let after = try await migrationNames(app.db).sorted()
            #expect(before == after)
        }
    }
}
