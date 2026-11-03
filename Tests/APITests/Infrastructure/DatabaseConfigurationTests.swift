import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

/// The five variables a Postgres connection needs, all set.
private let completePostgresEnvironment: [String: String?] = [
    "DATABASE_HOST": "db",
    "DATABASE_PORT": "5432",
    "DATABASE_NAME": "chickadee",
    "DATABASE_USER": "chickadee_user",
    "DATABASE_PASSWORD": "secret",
]

@Suite(.serialized)
struct DatabaseConfigurationTests {

    @Test func appDatabaseSettingsRequirePostgresVariables() async throws {
        try await withTestEnvironment([
            "DATABASE_HOST": nil,
            "DATABASE_PORT": nil,
            "DATABASE_NAME": nil,
            "DATABASE_USER": nil,
            "DATABASE_PASSWORD": nil,
        ]) {
            #expect(throws: DatabaseConfigurationError.self) {
                _ = try DatabaseSettings.fromEnvironment()
            }
        }
    }

    /// A deployment that still runs SQLite sets none of the five, so the
    /// error must say that SQLite is gone and name every missing variable.
    @Test func missingPostgresVariablesNameSQLiteRemovalAndEachVariable() async throws {
        try await withTestEnvironment([
            "DATABASE_HOST": nil,
            "DATABASE_PORT": nil,
            "DATABASE_NAME": "chickadee",
            "DATABASE_USER": "chickadee_user",
            "DATABASE_PASSWORD": "secret",
        ]) {
            do {
                _ = try DatabaseSettings.fromEnvironment()
                Issue.record("expected fromEnvironment to throw")
            } catch {
                let message = (error as? DatabaseConfigurationError)?.errorDescription ?? ""
                #expect(message.contains("SQLite support was removed"))
                #expect(message.contains("DATABASE_HOST"))
                #expect(message.contains("DATABASE_PORT"))
                #expect(!message.contains("DATABASE_NAME"))
            }
        }
    }

    @Test func appDatabaseSettingsParsePostgresConfiguration() async throws {
        try await withTestEnvironment(completePostgresEnvironment) {
            let settings = try DatabaseSettings.fromEnvironment()
            #expect(settings.host == "db")
            #expect(settings.port == 5432)
            #expect(settings.database == "chickadee")
            #expect(settings.username == "chickadee_user")
            #expect(settings.password == "secret")
            #expect(settings.searchPath == nil)
        }
    }

    @Test func testDatabaseSettingsDefaultToTheLocalTestDatabase() async throws {
        try await withTestEnvironment([
            "TEST_DATABASE_HOST": nil,
            "TEST_DATABASE_PORT": nil,
            "TEST_DATABASE_NAME": nil,
            "TEST_DATABASE_USER": nil,
            "TEST_DATABASE_PASSWORD": nil,
        ]) {
            let settings = try testDatabaseSettingsFromEnvironment()
            let defaults = DatabaseSettings.localTest
            #expect(settings.host == defaults.host)
            #expect(settings.port == defaults.port)
            #expect(settings.database == defaults.database)
            #expect(settings.username == defaults.username)
            #expect(settings.password == defaults.password)
        }
    }

    @Test func testDatabaseSettingsRejectANonNumericPort() async throws {
        try await withTestEnvironment(["TEST_DATABASE_PORT": "fivefourthreetwo"]) {
            #expect(throws: DatabaseConfigurationError.self) {
                _ = try testDatabaseSettingsFromEnvironment()
            }
        }
    }

    @Test func testDatabaseSettingsParsePostgresConfiguration() async throws {
        try await withTestEnvironment([
            "TEST_DATABASE_HOST": "db",
            "TEST_DATABASE_PORT": "6543",
            "TEST_DATABASE_NAME": "chickadee_ci",
            "TEST_DATABASE_USER": "ci",
            "TEST_DATABASE_PASSWORD": "secret",
        ]) {
            let settings = try testDatabaseSettingsFromEnvironment()
            #expect(settings.host == "db")
            #expect(settings.port == 6543)
            #expect(settings.database == "chickadee_ci")
            #expect(settings.username == "ci")
            #expect(settings.password == "secret")
        }
    }

    @Test func configureDatabaseAcceptsPostgresSettings() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            configureDatabase(
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

    @Test func configureTestDatabaseBootstrapsMigrations() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            try await configureTestDatabase(app)
            #expect(app.databases.configuration(for: .chickadee) != nil)
        }
    }

    @Test func configureTestDatabaseIncludesRunnerProfiles() async throws {
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

// MARK: - Pool sizing (#1159)

@Suite(.serialized)
struct DatabasePoolSizingTests {

    @Test func poolSizeDefaultsToNilWhenUnset() async throws {
        var environment = completePostgresEnvironment
        environment["DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP"] = .some(nil)
        try await withTestEnvironment(environment) {
            let settings = try DatabaseSettings.fromEnvironment()
            #expect(settings.maxConnectionsPerEventLoop == nil)
        }
    }

    @Test func poolSizeParses() async throws {
        var environment = completePostgresEnvironment
        environment["DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP"] = "6"
        try await withTestEnvironment(environment) {
            let settings = try DatabaseSettings.fromEnvironment()
            #expect(settings.maxConnectionsPerEventLoop == 6)
        }
    }

    @Test func poolSizeRejectsNonPositiveOrGarbageValues() async throws {
        for bad in ["0", "-2", "many"] {
            var environment = completePostgresEnvironment
            environment["DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP"] = bad
            try await withTestEnvironment(environment) {
                #expect(throws: DatabaseConfigurationError.self) {
                    _ = try DatabaseSettings.fromEnvironment()
                }
            }
        }
    }

    @Test func configureDatabaseAcceptsExplicitPoolSize() async throws {
        let app = try await makeTestingApplication { app in
            configureDatabase(
                app,
                settings: .postgres(
                    host: "db", port: 5432, database: "chickadee", username: "postgres",
                    password: "secret", maxConnectionsPerEventLoop: 4))
        }
        try await app.tearDownTestApp()
    }
}
