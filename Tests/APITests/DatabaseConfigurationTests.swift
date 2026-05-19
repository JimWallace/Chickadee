import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized)
struct DatabaseConfigurationTests {

    @Test func appDatabaseSettingsDefaultToSQLiteWhenUnset() async throws {
        try await withTestEnvironment([
            "DATABASE_BACKEND": nil,
            "SQLITE_PATH": nil,
        ]) {
            let settings = try DatabaseSettings.fromEnvironment(
                defaultSQLitePath: "/tmp/chickadee.sqlite")
            #expect(settings.backend == .sqlite)
            #expect(settings.sqlitePath == "/tmp/chickadee.sqlite")
        }
    }

    @Test func appDatabaseSettingsHonorExplicitSQLitePath() async throws {
        try await withTestEnvironment([
            "DATABASE_BACKEND": "sqlite",
            "SQLITE_PATH": "/var/lib/chickadee/custom.sqlite",
        ]) {
            let settings = try DatabaseSettings.fromEnvironment(
                defaultSQLitePath: "/tmp/chickadee.sqlite")
            #expect(settings.backend == .sqlite)
            #expect(settings.sqlitePath == "/var/lib/chickadee/custom.sqlite")
        }
    }

    @Test func appDatabaseSettingsRequirePostgresVariables() async throws {
        try await withTestEnvironment([
            "DATABASE_BACKEND": "postgres",
            "DATABASE_HOST": nil,
            "DATABASE_PORT": nil,
            "DATABASE_NAME": nil,
            "DATABASE_USER": nil,
            "DATABASE_PASSWORD": nil,
        ]) {
            #expect(throws: DatabaseConfigurationError.self) {
                _ = try DatabaseSettings.fromEnvironment(
                    defaultSQLitePath: "/tmp/chickadee.sqlite")
            }
        }
    }

    @Test func appDatabaseSettingsParsePostgresConfiguration() async throws {
        try await withTestEnvironment([
            "DATABASE_BACKEND": "postgres",
            "DATABASE_HOST": "db",
            "DATABASE_PORT": "5432",
            "DATABASE_NAME": "chickadee",
            "DATABASE_USER": "chickadee_user",
            "DATABASE_PASSWORD": "secret",
        ]) {
            let settings = try DatabaseSettings.fromEnvironment(
                defaultSQLitePath: "/tmp/chickadee.sqlite")
            #expect(settings.backend == .postgres)
            #expect(settings.postgresHost == "db")
            #expect(settings.postgresPort == 5432)
            #expect(settings.postgresDatabase == "chickadee")
            #expect(settings.postgresUsername == "chickadee_user")
        }
    }

    @Test func testDatabaseSettingsDefaultToSQLiteWhenUnset() async throws {
        try await withTestEnvironment([
            "TEST_DATABASE_BACKEND": nil,
            "TEST_DATABASE_HOST": nil,
            "TEST_DATABASE_PORT": nil,
            "TEST_DATABASE_NAME": nil,
            "TEST_DATABASE_USER": nil,
            "TEST_DATABASE_PASSWORD": nil,
        ]) {
            let settings = try testDatabaseSettingsFromEnvironment()
            #expect(settings.backend == .sqlite)
            switch settings.sqliteStorage {
            case .memory:
                #expect(Bool(true))
            default:
                Issue.record("Expected in-memory SQLite storage for default test database settings")
            }
        }
    }

    @Test func testDatabaseSettingsRequirePostgresVariables() async throws {
        try await withTestEnvironment([
            "TEST_DATABASE_BACKEND": "postgres",
            "TEST_DATABASE_HOST": "db",
            "TEST_DATABASE_PORT": nil,
            "TEST_DATABASE_NAME": "chickadee_test",
            "TEST_DATABASE_USER": "postgres",
            "TEST_DATABASE_PASSWORD": "secret",
        ]) {
            #expect(throws: DatabaseConfigurationError.self) {
                _ = try testDatabaseSettingsFromEnvironment()
            }
        }
    }

    @Test func testDatabaseSettingsParsePostgresConfiguration() async throws {
        try await withTestEnvironment([
            "TEST_DATABASE_BACKEND": "postgres",
            "TEST_DATABASE_HOST": "db",
            "TEST_DATABASE_PORT": "5432",
            "TEST_DATABASE_NAME": "chickadee_test",
            "TEST_DATABASE_USER": "postgres",
            "TEST_DATABASE_PASSWORD": "secret",
        ]) {
            let settings = try testDatabaseSettingsFromEnvironment()
            #expect(settings.backend == .postgres)
            #expect(settings.postgresHost == "db")
            #expect(settings.postgresPort == 5432)
            #expect(settings.postgresDatabase == "chickadee_test")
            #expect(settings.postgresUsername == "postgres")
        }
    }

    @Test func configureDatabaseAcceptsSQLiteSettings() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try configureDatabase(app, settings: .sqliteInMemory())
            #expect(app.databases.configuration(for: .chickadee) != nil)
        }
    }

    @Test func configureDatabaseAcceptsPostgresSettings() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try configureDatabase(
                app,
                settings: .postgres(
                    host: "db",
                    port: 5432,
                    database: "chickadee",
                    username: "postgres",
                    password: "secret"
                )
            )

            #expect(app.databases.configuration(for: .chickadee) != nil)
        }
    }

    @Test func configureTestDatabaseBootstrapsSQLiteMigrations() async throws {
        try await withTestEnvironment(["TEST_DATABASE_BACKEND": nil]) {
            let app = try await Application.make(.testing)
            try await withApp(app) { app in
                try await configureTestDatabase(app)
                #expect(app.databases.configuration(for: .chickadee) != nil)
            }
        }
    }

    @Test func configureTestDatabaseIncludesRunnerProfiles() async throws {
        try await withTestEnvironment(["TEST_DATABASE_BACKEND": nil]) {
            let app = try await Application.make(.testing)
            try await withApp(app) { app in
                try await configureTestDatabase(app)

                let now = Date()
                let profile = RunnerProfile()
                profile.runnerID = "runner-observability"
                profile.displayName = "Runner Observability"
                profile.platform = "macOS"
                profile.architecture = "arm64"
                profile.languageVersionsJSON = "[]"
                profile.capabilitiesJSON = "[]"
                profile.profileHash = nil
                profile.lastRegisteredAt = now
                profile.lastSeenAt = now
                profile.isActive = true
                try await profile.save(on: app.db)

                let saved = try await RunnerProfile.query(on: app.db)
                    .filter(\.$runnerID == "runner-observability")
                    .first()
                #expect(saved != nil)
            }
        }
    }
}
