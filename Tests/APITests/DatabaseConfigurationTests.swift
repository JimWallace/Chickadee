import Fluent
import Foundation
import Testing
import Vapor

@testable import chickadee_server

@Suite(.serialized)
struct DatabaseConfigurationTests {
    final class EnvironmentScope: @unchecked Sendable {
        private var backup: [String: String?] = [:]

        // Acquire the shared env lock so this scope's env mutations don't
        // race with env-touching tests in other suites (notably
        // APIServerAppTests).  `@Suite(.serialized)` on this suite only
        // covers within-suite parallelism.
        init() {
            EnvTestLock.shared.lock()
        }

        deinit {
            for (key, value) in backup {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            EnvTestLock.shared.unlock()
        }

        func set(_ key: String, _ value: String?) {
            if backup[key] == nil {
                backup[key] = ProcessInfo.processInfo.environment[key]
            }
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }

    @Test func appDatabaseSettingsDefaultToSQLiteWhenUnset() throws {
        let env = EnvironmentScope()
        env.set("DATABASE_BACKEND", nil)
        env.set("SQLITE_PATH", nil)

        let settings = try DatabaseSettings.fromEnvironment(defaultSQLitePath: "/tmp/chickadee.sqlite")

        #expect(settings.backend == .sqlite)
        #expect(settings.sqlitePath == "/tmp/chickadee.sqlite")
    }

    @Test func appDatabaseSettingsHonorExplicitSQLitePath() throws {
        let env = EnvironmentScope()
        env.set("DATABASE_BACKEND", "sqlite")
        env.set("SQLITE_PATH", "/var/lib/chickadee/custom.sqlite")

        let settings = try DatabaseSettings.fromEnvironment(defaultSQLitePath: "/tmp/chickadee.sqlite")

        #expect(settings.backend == .sqlite)
        #expect(settings.sqlitePath == "/var/lib/chickadee/custom.sqlite")
    }

    @Test func appDatabaseSettingsRequirePostgresVariables() throws {
        let env = EnvironmentScope()
        env.set("DATABASE_BACKEND", "postgres")
        env.set("DATABASE_HOST", nil)
        env.set("DATABASE_PORT", nil)
        env.set("DATABASE_NAME", nil)
        env.set("DATABASE_USER", nil)
        env.set("DATABASE_PASSWORD", nil)

        #expect(throws: DatabaseConfigurationError.self) {
            _ = try DatabaseSettings.fromEnvironment(defaultSQLitePath: "/tmp/chickadee.sqlite")
        }
    }

    @Test func appDatabaseSettingsParsePostgresConfiguration() throws {
        let env = EnvironmentScope()
        env.set("DATABASE_BACKEND", "postgres")
        env.set("DATABASE_HOST", "db")
        env.set("DATABASE_PORT", "5432")
        env.set("DATABASE_NAME", "chickadee")
        env.set("DATABASE_USER", "chickadee_user")
        env.set("DATABASE_PASSWORD", "secret")

        let settings = try DatabaseSettings.fromEnvironment(defaultSQLitePath: "/tmp/chickadee.sqlite")

        #expect(settings.backend == .postgres)
        #expect(settings.postgresHost == "db")
        #expect(settings.postgresPort == 5432)
        #expect(settings.postgresDatabase == "chickadee")
        #expect(settings.postgresUsername == "chickadee_user")
    }

    @Test func testDatabaseSettingsDefaultToSQLiteWhenUnset() throws {
        let env = EnvironmentScope()
        env.set("TEST_DATABASE_BACKEND", nil)
        env.set("TEST_DATABASE_HOST", nil)
        env.set("TEST_DATABASE_PORT", nil)
        env.set("TEST_DATABASE_NAME", nil)
        env.set("TEST_DATABASE_USER", nil)
        env.set("TEST_DATABASE_PASSWORD", nil)

        let settings = try testDatabaseSettingsFromEnvironment()

        #expect(settings.backend == .sqlite)
        switch settings.sqliteStorage {
        case .memory:
            #expect(Bool(true))
        default:
            Issue.record("Expected in-memory SQLite storage for default test database settings")
        }
    }

    @Test func testDatabaseSettingsRequirePostgresVariables() {
        let env = EnvironmentScope()
        env.set("TEST_DATABASE_BACKEND", "postgres")
        env.set("TEST_DATABASE_HOST", "db")
        env.set("TEST_DATABASE_PORT", nil)
        env.set("TEST_DATABASE_NAME", "chickadee_test")
        env.set("TEST_DATABASE_USER", "postgres")
        env.set("TEST_DATABASE_PASSWORD", "secret")

        #expect(throws: DatabaseConfigurationError.self) {
            _ = try testDatabaseSettingsFromEnvironment()
        }
    }

    @Test func testDatabaseSettingsParsePostgresConfiguration() throws {
        let env = EnvironmentScope()
        env.set("TEST_DATABASE_BACKEND", "postgres")
        env.set("TEST_DATABASE_HOST", "db")
        env.set("TEST_DATABASE_PORT", "5432")
        env.set("TEST_DATABASE_NAME", "chickadee_test")
        env.set("TEST_DATABASE_USER", "postgres")
        env.set("TEST_DATABASE_PASSWORD", "secret")

        let settings = try testDatabaseSettingsFromEnvironment()

        #expect(settings.backend == .postgres)
        #expect(settings.postgresHost == "db")
        #expect(settings.postgresPort == 5432)
        #expect(settings.postgresDatabase == "chickadee_test")
        #expect(settings.postgresUsername == "postgres")
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
        let env = EnvironmentScope()
        env.set("TEST_DATABASE_BACKEND", nil)

        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)
            #expect(app.databases.configuration(for: .chickadee) != nil)
        }
    }

    @Test func configureTestDatabaseIncludesRunnerProfiles() async throws {
        let env = EnvironmentScope()
        env.set("TEST_DATABASE_BACKEND", nil)

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
