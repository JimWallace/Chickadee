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

/// Session-level bounds sent to Postgres as startup parameters on every
/// pooled connection (both the main and the least-privilege MCP pool).
///
/// #1159 was a pool-starvation incident: one slow admin-dashboard scan held
/// its event loop's only connection and starved every other query on that
/// loop. The pool is now 4/loop and the dashboard reads are cached, but
/// nothing bounded how long a single pathological statement could hold a
/// pooled connection — these do. Values are deliberate constants, not
/// configuration: they exist to be generous ceilings that only a defect can
/// reach, so there is nothing an operator should tune.
enum PostgresSessionBounds {
    /// 60 s: far above any legitimate single statement (the widest query in
    /// the app is the 72 h-clamped metrics window; migrations at current
    /// data sizes are sub-second), far below "holds a pooled connection
    /// indefinitely". Applies to migrations too — a future migration
    /// genuinely expected to exceed it should `SET statement_timeout = 0`
    /// for its own session rather than raising this.
    static let statementTimeoutMs = 60_000

    /// 5 min: kills sessions idle *inside a transaction*. Generous because
    /// the course-bundle import legitimately writes files between statements
    /// of its import transaction; a connection wedged mid-transaction now
    /// dies in minutes instead of never.
    static let idleInTransactionSessionTimeoutMs = 300_000

    /// The exact parameter list appended to both pools' startup options.
    /// Postgres rejects an unknown parameter name at connection time, so a
    /// typo here fails the whole `api-tests-postgres` lane loudly rather
    /// than silently binding nothing.
    static var startupParameters: [(String, String)] {
        [
            ("statement_timeout", String(statementTimeoutMs)),
            ("idle_in_transaction_session_timeout", String(idleInTransactionSessionTimeoutMs)),
        ]
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
        configuration.coreConfiguration.options.additionalStartupParameters +=
            PostgresSessionBounds.startupParameters

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
            mcpConfiguration.coreConfiguration.options.additionalStartupParameters +=
                PostgresSessionBounds.startupParameters
            app.databases.use(
                .postgres(configuration: mcpConfiguration, maxConnectionsPerEventLoop: poolSize),
                as: .mcp)
            app.usesDedicatedMCPDatabase = true
            app.logger.info("MCP database: dedicated least-privilege role \(mcpUsername) in use")
        }
    }
}

func registerMigrations(on app: Application) {
    // Note: incremental `Add*` migrations are periodically consolidated into
    // the canonical `Create*` files and the `Add*` structs deleted outright.
    // Production DBs that already applied them still carry the names in
    // `_fluent_migrations`; Fluent ignores history rows whose struct names
    // are no longer registered, so this is harmless.  Fresh deploys produce
    // the same final schema from the `Create*` files alone.  Two rounds so
    // far:
    //   - the #502/#505 round: 13 historical `Add*` migrations folded in
    //     PR #502 (v0.4.171); their remaining no-op stubs were deleted in
    //     PR #505 (VERSION was still 0.4.x when that shipped).
    //   - the second (0.5.0) round: 24 more folded, which also retired the
    //     "column must exist before a later migration full-queries the
    //     model" boot-order hazard class (#1077) — columns no longer
    //     arrive after their table does.
    // `AddSessionsCreatedAt` is NOT consolidated — it's a real migration
    // against Vapor's `_fluent_sessions` table (not one of our own).
    app.migrations.add(CreateUsers())
    app.migrations.add(CreateCourses())
    // Deliberately left out of the second consolidation round (#1228 columns
    // only days old at v0.4.669) — fold in the next consolidation round.
    app.migrations.add(AddCourseSlipDaySettings())
    app.migrations.add(CreateCourseEnrollments())
    app.migrations.add(CreateTestSetups())
    app.migrations.add(CreateSubmissions())
    app.migrations.add(CreateValidationVariants())
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
    app.migrations.add(AddAchievementResultCoverage())
    app.migrations.add(CreateClassItemCoverage())
    app.migrations.add(CreatePreEnrollments())
    app.migrations.add(SessionRecord.migration)
    app.migrations.add(CreateClientDiagnostics())
    app.migrations.add(CreateAssignmentPersonalizationSeeds())
    app.migrations.add(AddSessionsCreatedAt())
    app.migrations.add(CreateAuditLog())
    app.migrations.add(CreateAssignmentExtensions())
    app.migrations.add(CreateAssignmentParticipations())
    // Deliberately left out of the second consolidation round: folding would
    // newly enforce these FKs on dev/test SQLite and interacts with
    // AdminRoutes.deleteUser's hand-rolled cleanup.
    app.migrations.add(AddUserFKConstraints())
    // MCP OAuth authorization-server tables (Phase 2). FKs reference `users`.
    app.migrations.add(CreateMCPOAuthClients())
    app.migrations.add(CreateMCPAuthorizationCodes())
    app.migrations.add(CreateMCPGrants())
    app.migrations.add(CreateBrightSpaceSyncLog())
    // Single-row store for the admin-authorized BrightSpace Valence user key
    // (durable alternative to BRIGHTSPACE_USER_ID/KEY in env).
    app.migrations.add(CreateBrightSpaceCredentials())
    // Single-use consent requests for the browser OAuth flow (cookie-less
    // POST /oauth/authorize). FK references `users`.
    app.migrations.add(CreateMCPConsentRequests())
    // Per-student grade overrides. FKs reference `users` and `test_setups`.
    app.migrations.add(CreateGradeOverrides())
    // Explicit LEARN grade-clear queue rows. FKs reference `users` and
    // `test_setups`. (Nearly lost in the second consolidation: the two folded
    // registrations around it were deleted and took this line with them —
    // caught by GradeOverridesTests before it shipped.)
    app.migrations.add(CreateBrightSpaceGradeClears())
    // Per-user activity pings behind the admin dashboard's "active users over
    // time" chart. FK references `users`.
    app.migrations.add(CreateUserActivityEvents())
    // Append-only assignment content-snapshot history. FK references `courses`
    // and `users`; deliberately none on `test_setups` (see the migration).
    app.migrations.add(CreateAssignmentVersions())
    // Index migrations run last: they reference tables created above
    // (runner_snapshots, job_execution_metrics) and only add indexes.
    app.migrations.add(CreateHotPathIndexes())

    // Audit-followup indexes (June 2026): request_metrics(finished_at) and
    // other uncovered hot-path filters. Index-only, runs last.
    app.migrations.add(CreateAuditFollowupIndexes())

    // Per-student slip-day budget adjustment (#1228, only days old at
    // v0.4.669) — fold in the next consolidation round.
    app.migrations.add(AddEnrollmentSlipDaysAdjustment())

    // Collapse the deployment-global role to user|admin (#417 Slice G2):
    // rewrite every legacy student/instructor row to `user`. A pure data
    // rewrite — on a fresh DB it runs against zero rows. On the historical
    // DBs where it did real work, the enrollment-role backfill (since folded
    // into CreateCourseEnrollments by the second consolidation round) had
    // already seeded each enrollment's per-course role from the user's
    // then-current global role, so normalising the now-meaningless global
    // label here loses no teaching authority.
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
    // CreateResults, whose `collection_json` this migration backfills from
    // and then drops. Deliberately left standalone in the second
    // consolidation round — the side-table partial fold is out of scope.
    app.migrations.add(CreateResultCollections())

    // Spent secret-reveal tokens: one row per (student, assignment). The
    // per-assignment toggle column lives on `assignments` (CreateAssignments).
    app.migrations.add(CreateSecretRevealUnlocks())

    // Personal-data export tracking (#557): one row per user, doubling as
    // the one-export-per-day rate-limit ledger. FK to users; no ordering
    // constraints beyond CreateUsers.
    app.migrations.add(CreateDataExports())

    // Ungraded course content items (reference material shown inside a course
    // section alongside assignments). New table; FKs reference `courses` and
    // `course_sections`, both created by CreateCourses above, so no additional
    // ordering constraint.
    app.migrations.add(CreateCourseContentItems())

    // Slip-day ledger (#1228): one row per spent slip day, refunds stamped
    // in place. New table; FKs reference `users`, `courses`, `assignments`,
    // all created above, so no additional ordering constraint.
    app.migrations.add(CreateSlipDaySpends())

    // Worker claim priority (#1361): covers the fresh-work-first split's
    // `retested_at` predicate, which the older submissions index stopped short
    // of. Index-only; `submissions` is created far above.
    app.migrations.add(CreateClaimPriorityIndex())

    // Session reaper sweep column (#1365). Index-only, but it must follow
    // `AddSessionsCreatedAt` above, which is what creates the column.
    app.migrations.add(CreateSessionReaperIndex())

    // Observability prune sweep over submission_diagnostics (#1382 item 8).
    // Index-only; the table is created far above.
    app.migrations.add(CreateSubmissionDiagnosticsPruneIndex())

    // Data backfill, registered LAST on purpose: it full-queries `APITestSetup`,
    // which is only safe once every migration that adds a column to
    // `test_setups` has already run (the #1077 boot-order hazard, inverted —
    // here the model query is the late one rather than the column).
    app.migrations.add(BackfillDeclaredLanguage())
}
