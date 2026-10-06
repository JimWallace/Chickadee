// Tests/APITests/LegacyMigrationNamespaceGuardTests.swift
//
// The server refuses to boot on a database whose migration history uses a
// module-derived namespace from v0.4.200 or earlier (#2282). Replaces the
// tests of the old rename, which could no longer produce a working database.

import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized)
struct LegacyMigrationNamespaceGuardTests {

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

    /// One history row under either legacy namespace stops the boot, and the
    /// error names it.
    @Test(arguments: ["chickadee_server.", "APIServer."])
    func refusesALegacyNamespace(_ prefix: String) async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)
            let log = try #require(
                try await MigrationLog.query(on: app.db).filter(\.$name == "chickadee.CreateUsers").first())
            log.name = prefix + "CreateUsers"
            try await log.save(on: app.db)

            let error = try #require(throws: LegacyMigrationNamespaceError.self) {
                try refuseLegacyMigrationNamespace(on: app)
            }
            #expect(error.legacyRows == 1)
            #expect(error.description.contains(prefix + "CreateUsers"))
        }
    }

    /// On a normal (already-canonical) database the check passes and changes
    /// nothing.
    @Test func passesWhenNoLegacyRowsArePresent() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)
            let before = try await migrationNames(app.db).sorted()
            try refuseLegacyMigrationNamespace(on: app)
            let after = try await migrationNames(app.db).sorted()
            #expect(before == after)
        }
    }
}
