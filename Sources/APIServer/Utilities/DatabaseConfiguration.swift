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
    /// Optional least-privilege role for the MCP path (postgres only). When both
    /// are set, a second connection pool is registered under `DatabaseID.mcp`
    /// using these credentials against the same host/database, and the MCP tool
    /// surface uses it — so a restricted DB role (no access to student tables)
    /// enforces the student-data wall at the database layer, independent of the
    /// in-process boundary. nil → the MCP path shares the main pool.
    let postgresMCPUsername: String?
    let postgresMCPPassword: String?
    /// Fluent connection-pool size per event loop (#1159 — the pool was
    /// never configured, riding the driver default of 1/loop; the
    /// MetricsCardCache header documents the ConnectionPoolTimeoutError
    /// incident that caused). nil → per-backend default at configure time
    /// (1 for SQLite, whose writes serialize anyway; 4 for Postgres).
    let maxConnectionsPerEventLoop: Int?

    static func fromEnvironment(defaultSQLitePath: String) throws -> Self {
        let poolSize = try parsedPoolSize()
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
            return .sqlite(
                path: trimmedEnv("SQLITE_PATH") ?? defaultSQLitePath,
                maxConnectionsPerEventLoop: poolSize)
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
                password: password,
                mcpUsername: trimmedEnv("MCP_DATABASE_USER"),
                mcpPassword: trimmedEnv("MCP_DATABASE_PASSWORD"),
                maxConnectionsPerEventLoop: poolSize
            )
        }
    }

    private static func parsedPoolSize() throws -> Int? {
        guard let raw = trimmedEnv("DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP") else { return nil }
        guard let value = Int(raw), value > 0 else {
            throw DatabaseConfigurationError.invalidSettings(
                "DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP must be a positive integer"
            )
        }
        return value
    }

    static func sqlite(path: String, maxConnectionsPerEventLoop: Int? = nil) -> Self {
        .init(
            backend: .sqlite,
            sqlitePath: path,
            sqliteStorage: .file(path: path),
            postgresHost: nil,
            postgresPort: nil,
            postgresDatabase: nil,
            postgresUsername: nil,
            postgresPassword: nil,
            postgresSearchPath: nil,
            postgresMCPUsername: nil,
            postgresMCPPassword: nil,
            maxConnectionsPerEventLoop: maxConnectionsPerEventLoop
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
            postgresSearchPath: nil,
            postgresMCPUsername: nil,
            postgresMCPPassword: nil,
            maxConnectionsPerEventLoop: nil
        )
    }

    static func postgres(
        host: String,
        port: Int,
        database: String,
        username: String,
        password: String,
        searchPath: [String]? = nil,
        mcpUsername: String? = nil,
        mcpPassword: String? = nil,
        maxConnectionsPerEventLoop: Int? = nil
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
            postgresSearchPath: searchPath,
            postgresMCPUsername: mcpUsername,
            postgresMCPPassword: mcpPassword,
            maxConnectionsPerEventLoop: maxConnectionsPerEventLoop
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
    /// Optional dedicated pool for the MCP path, backed by a least-privilege
    /// Postgres role (see `deploy/sql/mcp-least-privilege-role.sql`). Registered
    /// only when `MCP_DATABASE_USER`/`MCP_DATABASE_PASSWORD` are set.
    static let mcp = DatabaseID(string: "mcp")
}

private struct UsesDedicatedMCPDatabaseKey: StorageKey {
    typealias Value = Bool
}

extension Application {
    /// True when a dedicated least-privilege MCP database pool (`DatabaseID.mcp`)
    /// is registered. When false, the MCP path shares the main pool. The MCP tool
    /// surface reads this to choose its connection (see `ToolContext.db`).
    var usesDedicatedMCPDatabase: Bool {
        get { storage[UsesDedicatedMCPDatabaseKey.self] ?? false }
        set { storage[UsesDedicatedMCPDatabaseKey.self] = newValue }
    }
}

func configureDatabase(_ app: Application, settings: DatabaseSettings) throws {
    switch settings.backend {
    case .sqlite:
        let sqliteConfig = SQLiteConfiguration(
            storage: settings.sqliteStorage,
            enableForeignKeys: true
        )
        // Default 1/loop: SQLite serializes writes anyway, and the in-memory
        // test storage must stay on the driver default. Raising it only helps
        // concurrent WAL reads and only when explicitly configured (#1159).
        app.databases.use(
            .sqlite(sqliteConfig, maxConnectionsPerEventLoop: settings.maxConnectionsPerEventLoop ?? 1),
            as: .chickadee, isDefault: true)

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
        // Default 4/loop on Postgres (#1159): the driver default of 1/loop is
        // the documented ConnectionPoolTimeoutError incident class — one
        // long-held connection per event loop starves every other query on
        // that loop. Override via DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP.
        let poolSize = settings.maxConnectionsPerEventLoop ?? 4
        app.databases.use(
            .postgres(configuration: configuration, maxConnectionsPerEventLoop: poolSize),
            as: .chickadee,
            isDefault: true
        )
        app.logger.info("Postgres pool: \(poolSize) connections per event loop")

        // Optional: a second pool for the MCP path backed by a least-privilege
        // role (no access to student tables). Same host/database/search_path,
        // different credentials. When unset, MCP shares the main pool above.
        if let mcpUsername = settings.postgresMCPUsername,
            let mcpPassword = settings.postgresMCPPassword
        {
            var mcpConfiguration = SQLPostgresConfiguration(
                hostname: host,
                port: port,
                username: mcpUsername,
                password: mcpPassword,
                database: database,
                tls: .disable
            )
            if let searchPath = settings.postgresSearchPath, !searchPath.isEmpty {
                mcpConfiguration.searchPath = searchPath
            }
            app.databases.use(
                .postgres(configuration: mcpConfiguration, maxConnectionsPerEventLoop: poolSize),
                as: .mcp)
            app.usesDedicatedMCPDatabase = true
            app.logger.info("MCP database: dedicated least-privilege role \(mcpUsername) in use")
        }
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
    // Must precede any migration that queries the APICourse *model* (e.g.
    // AddCourseArchivedAt's backfill). Fluent's model query SELECTs every
    // declared column, so the column has to exist before those run on a
    // fresh DB. Existing prod is unaffected — only this new migration runs.
    app.migrations.add(AddBrightSpaceOrgUnitName())
    // Same ordering constraint as AddBrightSpaceOrgUnitName: a courses column
    // that must exist before AddCourseArchivedAt queries the APICourse model.
    app.migrations.add(AddCourseBrightSpaceSyncUserID())
    // Same ordering constraint: brightspace_section_category_id must exist
    // before AddCourseArchivedAt (or any migration) queries the APICourse model.
    app.migrations.add(AddCourseBrightSpaceSectionCategoryID())
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
    app.migrations.add(CreateAchievementResults())
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
    app.migrations.add(CreateBrightSpaceSyncLog())
    // Single-row store for the admin-authorized BrightSpace Valence user key
    // (durable alternative to BRIGHTSPACE_USER_ID/KEY in env).
    app.migrations.add(CreateBrightSpaceCredentials())
    // Per-instructor scope on the captured Valence key (NULL = deployment-wide).
    app.migrations.add(AddBrightSpaceCredentialUserID())
    // Single-use consent requests for the browser OAuth flow (cookie-less
    // POST /oauth/authorize). FK references `users`.
    app.migrations.add(CreateMCPConsentRequests())
    // Per-student grade overrides. FKs reference `users` and `test_setups`.
    app.migrations.add(CreateGradeOverrides())
    // Per-user activity pings behind the admin dashboard's "active users over
    // time" chart. FK references `users`.
    app.migrations.add(CreateUserActivityEvents())
    // Index migrations run last: they reference tables created above
    // (runner_snapshots, job_execution_metrics) and only add indexes.
    app.migrations.add(CreateHotPathIndexes())
    app.migrations.add(AddGrantPreviousRefreshTokenHashIndex())
    // Replaces assignments.is_open (bool) with assignments.visibility (enum
    // string). Runs after CreateAssignments on every deploy.
    app.migrations.add(ChangeAssignmentIsOpenToVisibility())

    // Adds submissions.materialization_json — cached once-at-enqueue
    // personalization for validation submissions, so worker poll + download
    // stay eval-free.
    app.migrations.add(AddSubmissionMaterialization())

    // Audit-followup indexes (June 2026): request_metrics(finished_at) and
    // other uncovered hot-path filters. Index-only, runs last.
    app.migrations.add(CreateAuditFollowupIndexes())

    // Denormalized grade columns on results + one-time backfill from the
    // collection_json blob (June 2026 audit, P1.1).
    app.migrations.add(AddResultGradeColumns())

    // Error-detail columns on client_diagnostics (message/stack/source) so
    // browser-side failures carry diagnosable signal.
    app.migrations.add(AddClientDiagnosticErrorDetail())

    // app_version column on client_diagnostics: the page build that emitted each
    // report, so a diagnostic can be attributed to a build (an old value flags a
    // stale browser tab / cached bundle, not a live regression).
    app.migrations.add(AddClientDiagnosticAppVersion())

    // Per-(student, course) LEARN sync readiness on course_enrollments:
    // unconfirmed (default) → confirmed / unreachable, maintained by the
    // roster-readiness sweep. MUST run before AddCourseEnrollmentRole: that
    // migration's backfill does a full-model `APICourseEnrollment.query().all()`,
    // which on a fresh DB selects every column the model declares — including
    // these — so the columns have to exist by the time it runs.
    app.migrations.add(AddEnrollmentBrightSpaceSyncStatus())
    // Same ordering constraint: brightspace_section must exist before
    // AddCourseEnrollmentRole queries the full APICourseEnrollment model.
    app.migrations.add(AddEnrollmentBrightSpaceSection())

    // Per-course role on each enrollment (Phase 1 of
    // docs/multi-course-roles.md). Behaviour-preserving: backfills role from
    // each user's current global role; nothing reads it yet. Runs after
    // CreateCourseEnrollments (the table) and CreateUsers (the backfill reads
    // users).
    app.migrations.add(AddCourseEnrollmentRole())

    // BrightSpace grade-sync bookkeeping on grade_overrides, mirroring the
    // columns on results. Lets an override on a student with no submissions
    // (e.g. a manually-registered pre-enrolled student) enqueue a grade push.
    app.migrations.add(AddGradeOverrideBrightSpaceSync())

    // Queue of pending BrightSpace grade removals (override cleared on a
    // no-submission student Chickadee had pushed a grade for). FK to
    // test_setups + users.
    app.migrations.add(CreateBrightSpaceGradeClears())

    // Explicit "do not sync this assignment to LEARN" flag on assignments,
    // distinct from an unmapped grade item. Column-only; no migration
    // full-queries APIAssignment, so ordering is unconstrained.
    app.migrations.add(AddAssignmentBrightSpaceSyncExcluded())

    // Collapse the deployment-global role to user|admin (#417 Slice G2):
    // rewrite every legacy student/instructor row to `user`. MUST run after
    // AddCourseEnrollmentRole, which has already seeded each enrollment's
    // per-course role from the user's then-current global role — so normalising
    // the now-meaningless global label here loses no teaching authority.
    app.migrations.add(CollapseUserRoles())

    // Multi-process security state (#1154): worker-HMAC replay nonces and
    // login rate-limit/lockout events move from process-local memory to the
    // database so their guarantees hold behind a load balancer. New tables,
    // no ordering constraints.
    app.migrations.add(CreateWorkerNonces())
    app.migrations.add(CreateLoginAttempts())

    // Leader leases so each periodic sweep runs on exactly one process
    // (#1155). New table, no ordering constraints.
    app.migrations.add(CreateSweepLeases())

    // Relocates results.collection_json to the result_collections side table
    // (#1173) so hot result-row queries never carry the blob. MUST run after
    // AddResultGradeColumns — its backfill reads the column this migration
    // drops.
    app.migrations.add(CreateResultCollections())

    // Secret reveal tokens: per-assignment instructor toggle plus one
    // spent-token row per (student, assignment). Column-only + new table;
    // no migration full-queries APIAssignment, so ordering is unconstrained.
    app.migrations.add(AddAssignmentSecretRevealEnabled())
    app.migrations.add(CreateSecretRevealUnlocks())
}
