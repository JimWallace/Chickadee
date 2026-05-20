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

    /// Our migrations record under the module-independent "chickadee." namespace
    /// (via `ChickadeeMigration`), not the module-qualified default. This is what
    /// makes a future module rename harmless.
    @Test func migrationsUseCanonicalChickadeeNamespace() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)
            let names = try await migrationNames(app.db)
            #expect(names.contains("chickadee.CreateUsers"))
            #expect(!names.contains { $0.hasPrefix("APIServer.") })
            #expect(!names.contains { $0.hasPrefix("chickadee_server.") })
        }
    }

    /// A database recorded under either legacy namespace — `chickadee_server.*`
    /// (executable-module era) or `APIServer.*` (library-split era) — is rewritten
    /// to `chickadee.*`, so the current build sees its migrations as applied and
    /// `autoMigrate` is a clean no-op instead of re-running them.
    @Test func reconcilesBothLegacyNamespaces() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)

            // Simulate an old DB: rewrite our canonical rows to the two legacy
            // namespaces, alternating so both prefixes are exercised.
            var toServer = true
            for log in try await MigrationLog.query(on: app.db).all()
            where log.name.hasPrefix("chickadee.") {
                let suffix = String(log.name.dropFirst("chickadee.".count))
                log.name = (toServer ? "chickadee_server." : "APIServer.") + suffix
                toServer.toggle()
                try await log.save(on: app.db)
            }
            let flipped = try await migrationNames(app.db)
            #expect(flipped.contains { $0.hasPrefix("chickadee_server.") })
            #expect(flipped.contains { $0.hasPrefix("APIServer.") })
            #expect(!flipped.contains { $0.hasPrefix("chickadee.") })

            try reconcileLegacyMigrationNamespace(on: app)

            let reconciled = try await migrationNames(app.db)
            #expect(!reconciled.contains { $0.hasPrefix("chickadee_server.") })
            #expect(!reconciled.contains { $0.hasPrefix("APIServer.") })
            #expect(reconciled.contains("chickadee.CreateUsers"))

            // Would throw (42P07 re-create) if any migration were still seen as
            // unapplied; a clean return is the assertion.
            try await app.autoMigrate()
        }
    }

    /// If a legacy duplicate sits alongside the canonical row, it's dropped
    /// rather than renamed into a collision.
    @Test func dropsLegacyRowWhenCanonicalAlreadyExists() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)

            // chickadee.CreateUsers already exists from autoMigrate; add a stray
            // legacy duplicate alongside it.
            let dup = MigrationLog()
            dup.name = "APIServer.CreateUsers"
            dup.batch = 1
            try await dup.save(on: app.db)

            try reconcileLegacyMigrationNamespace(on: app)

            let names = try await migrationNames(app.db)
            #expect(!names.contains("APIServer.CreateUsers"))
            #expect(names.filter { $0 == "chickadee.CreateUsers" }.count == 1)
        }
    }

    /// On a normal (already-canonical) database, reconciliation changes nothing.
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
