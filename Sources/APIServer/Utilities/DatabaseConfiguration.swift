import Vapor
import Fluent
import FluentSQLiteDriver
import FluentPostgresDriver
import SQLKit
import Foundation

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

    static func fromEnvironment(defaultSQLitePath: String) throws -> Self {
        let backend: DatabaseBackend
        if let configuredBackend = Environment.get("DATABASE_BACKEND")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !configuredBackend.isEmpty {
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
            let sqlitePath = Environment.get("SQLITE_PATH")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? defaultSQLitePath
            return .sqlite(path: sqlitePath)
        case .postgres:
            let host = Environment.get("DATABASE_HOST")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let database = Environment.get("DATABASE_NAME")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let username = Environment.get("DATABASE_USER")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let password = Environment.get("DATABASE_PASSWORD")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let port = Environment.get("DATABASE_PORT")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : Int($0) }

            var missing: [String] = []
            if host?.isEmpty != false { missing.append("DATABASE_HOST") }
            if database?.isEmpty != false { missing.append("DATABASE_NAME") }
            if username?.isEmpty != false { missing.append("DATABASE_USER") }
            if password?.isEmpty != false { missing.append("DATABASE_PASSWORD") }
            if port == nil { missing.append("DATABASE_PORT") }

            guard missing.isEmpty else {
                throw DatabaseConfigurationError.invalidSettings(
                    "DATABASE_BACKEND=postgres requires: \(missing.joined(separator: ", "))"
                )
            }

            return .postgres(
                host: host!,
                port: port!,
                database: database!,
                username: username!,
                password: password!
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
            postgresPassword: nil
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
            postgresPassword: nil
        )
    }

    static func postgres(
        host: String,
        port: Int,
        database: String,
        username: String,
        password: String
    ) -> Self {
        .init(
            backend: .postgres,
            sqlitePath: nil,
            sqliteStorage: .memory,
            postgresHost: host,
            postgresPort: port,
            postgresDatabase: database,
            postgresUsername: username,
            postgresPassword: password
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

        let configuration = SQLPostgresConfiguration(
            hostname: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disable
        )
        app.databases.use(
            .postgres(configuration: configuration),
            as: .chickadee,
            isDefault: true
        )
    }
}

func registerMigrations(on app: Application) {
    app.migrations.add(CreateUsers())
    app.migrations.add(CreateCourses())
    app.migrations.add(CreateCourseEnrollments())
    app.migrations.add(CreateTestSetups())
    app.migrations.add(CreateSubmissions())
    app.migrations.add(CreateResults())
    app.migrations.add(CreateAssignments())
    app.migrations.add(AddAssignmentSlugs())
    app.migrations.add(CreatePerformanceIndexes())
    app.migrations.add(AddCourseSections())
    app.migrations.add(AddCourseOpenEnrollment())
    app.migrations.add(AddCourseEnrollmentMode())
    app.migrations.add(CreateSubmissionDiagnostics())
    app.migrations.add(CreateRequestMetrics())
    app.migrations.add(CreateJobExecutionMetrics())
    app.migrations.add(AddJobExecutionStageTimings())
    app.migrations.add(CreateRunnerSnapshots())
    app.migrations.add(CreateRunnerProfiles())
    app.migrations.add(CreateAssignmentRequirements())
    app.migrations.add(AddSubmissionRetestedAt())
    app.migrations.add(AddAssignmentDeadlineOverrideActive())
    app.migrations.add(CreateClassAchievements())
    app.migrations.add(AddSubmissionRetestedByUserID())
    app.migrations.add(AddTestSetupLastRetestedManifestHash())
    app.migrations.add(SessionRecord.migration)
}
