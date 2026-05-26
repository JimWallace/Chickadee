import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import Foundation
import SQLKit
import Vapor

enum DatabaseBackend: String, Sendable {
    case sqlite
    case postgres
}

struct DatabaseSettings: Sendable {
    let backend: DatabaseBackend
    let sqlitePath: String?
    let sqliteStorage: SQLiteConfiguration.Storage
    let postgresHost: String?
    let postgresPort: Int?
    let postgresDatabase: String?
    let postgresUsername: String?
    let postgresPassword: String?
    let postgresSearchPath: [String]?

    static func fromEnvironment(defaultSQLitePath: String) throws -> Self {
        let backend: DatabaseBackend
        if let configuredBackend = trimmedEnv("DATABASE_BACKEND")?.lowercased() {
            guard let parsed = DatabaseBackend(rawValue: configuredBackend) else {
                throw DatabaseConfigurationError.invalidSettings(
                    "DATABASE_BACKEND must be one of: sqlite, postgres"
                )
            }
            backend = parsed
        } else {
            backend = .sqlite
        }

        switch backend {
        case .sqlite:
            return .sqlite(path: trimmedEnv("SQLITE_PATH") ?? defaultSQLitePath)
        case .postgres:
            let host = trimmedEnv("DATABASE_HOST")
            let database = trimmedEnv("DATABASE_NAME")
            let username = trimmedEnv("DATABASE_USER")
            let password = trimmedEnv("DATABASE_PASSWORD")
            let port = environmentInt("DATABASE_PORT")

            var missing: [String] = []
            if host == nil { missing.append("DATABASE_HOST") }
            if database == nil { missing.append("DATABASE_NAME") }
            if username == nil { missing.append("DATABASE_USER") }
            if password == nil { missing.append("DATABASE_PASSWORD") }
            if port == nil { missing.append("DATABASE_PORT") }

            guard let host, let database, let username, let password, let port else {
                throw DatabaseConfigurationError.invalidSettings(
                    "DATABASE_BACKEND=postgres requires: \(missing.joined(separator: ", "))"
                )
            }

            return .postgres(
                host: host,
                port: port,
                database: database,
                username: username,
                password: password
            )
        }
    }

    static func sqlite(path: String) -> Self {
        .init(
            backend: .sqlite,
            sqlitePath: path,
            sqliteStorage: .file(path: path),
            postgresHost: nil,
            postgresPort: nil,
            postgresDatabase: nil,
            postgresUsername: nil,
            postgresPassword: nil,
            postgresSearchPath: nil
        )
    }

    static func sqliteInMemory() -> Self {
        .init(
            backend: .sqlite,
            sqlitePath: nil,
            sqliteStorage: .memory,
            postgresHost: nil,
            postgresPort: nil,
            postgresDatabase: nil,
            postgresUsername: nil,
            postgresPassword: nil,
            postgresSearchPath: nil
        )
    }

    static func postgres(
        host: String,
        port: Int,
        database: String,
        username: String,
        password: String,
        searchPath: [String]? = nil
    ) -> Self {
        .init(
            backend: .postgres,
            sqlitePath: nil,
            sqliteStorage: .memory,
            postgresHost: host,
            postgresPort: port,
            postgresDatabase: database,
            postgresUsername: username,
            postgresPassword: password,
            postgresSearchPath: searchPath
        )
    }
}

enum DatabaseConfigurationError: Error, LocalizedError {
    case invalidSettings(String)

    var errorDescription: String? {
        switch self {
        case .invalidSettings(let message):
            return message
        }
    }
}

extension DatabaseID {
    static let chickadee = DatabaseID(string: "chickadee")
}

func configureDatabase(_ app: Application, settings: DatabaseSettings) throws {
    switch settings.backend {
    case .sqlite:
        let sqliteConfig = SQLiteConfiguration(
            storage: settings.sqliteStorage,
            enableForeignKeys: true
        )
        app.databases.use(.sqlite(sqliteConfig), as: .chickadee, isDefault: true)

        if case .file = settings.sqliteStorage, let sql = app.db as? SQLDatabase {
            _ = try sql.raw("PRAGMA journal_mode = WAL").all().wait()
        }
    case .postgres:
        guard
            let host = settings.postgresHost,
            let port = settings.postgresPort,
            let database = settings.postgresDatabase,
            let username = settings.postgresUsername,
            let password = settings.postgresPassword
        else {
            throw DatabaseConfigurationError.invalidSettings(
                "Postgres database configuration is incomplete."
            )
        }

        var configuration = SQLPostgresConfiguration(
            hostname: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disable
        )
        // Per-connection `SET search_path TO ...` so tests can isolate themselves
        // by schema and run in parallel against a single shared Postgres
        // database.  Postgres tolerates a non-existent name in search_path until
        // an unqualified reference resolves to it, so the bootstrap path can
        // configure first, then `CREATE SCHEMA`, then run migrations.
        if let searchPath = settings.postgresSearchPath, !searchPath.isEmpty {
            configuration.searchPath = searchPath
        }
        app.databases.use(
            .postgres(configuration: configuration),
            as: .chickadee,
            isDefault: true
        )
    }
}

func registerMigrations(on app: Application) {
    // Note: 13 historical `Add*` migrations were consolidated into the
    // corresponding `Create*` files in PR #502 (v0.4.171), and their
    // no-op stubs were removed in v0.5.0.  Production DBs that already
    // applied those migrations still carry the names in
    // `_fluent_migrations`; Fluent ignores history rows whose struct
    // names are no longer registered, so this is harmless.  Fresh
    // deploys produce the same final schema from the `Create*` files
    // alone.  `AddSessionsCreatedAt` is NOT consolidated — it's a real
    // migration against Vapor's `_fluent_sessions` table (not one of
    // our own).
    app.migrations.add(CreateUsers())
    app.migrations.add(CreateCourses())
    app.migrations.add(CreateCourseEnrollments())
    app.migrations.add(CreateTestSetups())
    app.migrations.add(CreateSubmissions())
    app.migrations.add(CreateResults())
    app.migrations.add(CreateAssignments())
    app.migrations.add(CreatePerformanceIndexes())
    app.migrations.add(CreateSubmissionDiagnostics())
    app.migrations.add(CreateRequestMetrics())
    app.migrations.add(CreateJobExecutionMetrics())
    app.migrations.add(CreateRunnerSnapshots())
    app.migrations.add(CreateRunnerProfiles())
    app.migrations.add(CreateAssignmentRequirements())
    app.migrations.add(CreateClassAchievements())
    app.migrations.add(CreatePreEnrollments())
    app.migrations.add(SessionRecord.migration)
    app.migrations.add(CreateClientDiagnostics())
    app.migrations.add(CreateAssignmentPersonalizationSeeds())
    app.migrations.add(AddSessionsCreatedAt())
    app.migrations.add(CreateAuditLog())
    app.migrations.add(CreateAssignmentExtensions())
    app.migrations.add(CreateAssignmentParticipations())
    app.migrations.add(AddUrlTokenToUsers())
    app.migrations.add(AddUserFKConstraints())
    app.migrations.add(AddCourseArchivedAt())
    // MCP OAuth authorization-server tables (Phase 2). FKs reference `users`.
    app.migrations.add(CreateMCPOAuthClients())
    app.migrations.add(CreateMCPAuthorizationCodes())
    app.migrations.add(CreateMCPGrants())
    app.migrations.add(AddPreviousRefreshTokenHashToGrants())
    app.migrations.add(AddAssignmentStartsAt())
    // Index migrations run last: they reference tables created above
    // (runner_snapshots, job_execution_metrics) and only add indexes.
    app.migrations.add(CreateHotPathIndexes())
}
