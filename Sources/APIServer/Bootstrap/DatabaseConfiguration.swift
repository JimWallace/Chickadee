import Fluent
import FluentPostgresDriver
import Foundation
import SQLKit
import Vapor

/// The server's database connection. PostgreSQL is the only backend: SQLite
/// support was removed in 0.5 (production had run on Postgres since blue-green
/// deploys, which two server versions cannot do on one SQLite file).
struct DatabaseSettings: Sendable {
    let host: String
    let port: Int
    let database: String
    let username: String
    let password: String
    /// Per-connection `search_path`. Production leaves it nil; the test suite
    /// sets it to isolate each test application in its own schema.
    let searchPath: [String]?
    /// Optional least-privilege role for the MCP path. When both are set, a
    /// second connection pool is registered under `DatabaseID.mcp` using these
    /// credentials against the same host/database, and the MCP tool surface
    /// uses it — so a restricted DB role (no access to student tables)
    /// enforces the student-data wall at the database layer, independent of
    /// the in-process boundary. nil → the MCP path shares the main pool.
    let mcpUsername: String?
    let mcpPassword: String?
    /// Fluent connection-pool size per event loop (#1159 — the pool was
    /// never configured, riding the driver default of 1/loop; the
    /// MetricsCardCache header documents the ConnectionPoolTimeoutError
    /// incident that caused). nil → 4 at configure time.
    let maxConnectionsPerEventLoop: Int?

    static func fromEnvironment() throws(DatabaseConfigurationError) -> Self {
        let poolSize = try parsedPoolSize()
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
            throw .invalidSettings(
                "Chickadee needs PostgreSQL (SQLite support was removed in 0.5). Set: "
                    + missing.joined(separator: ", ")
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

    private static func parsedPoolSize() throws(DatabaseConfigurationError) -> Int? {
        guard let raw = trimmedEnv("DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP") else { return nil }
        guard let value = Int(raw), value > 0 else {
            throw .invalidSettings(
                "DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP must be a positive integer"
            )
        }
        return value
    }

    /// The local Postgres the test suite uses when no `TEST_DATABASE_*`
    /// variable says otherwise: localhost:5432, database `chickadee_test`,
    /// user and password `postgres`. Also the database in
    /// `AppConfig.testDefaults()`, which a test application never connects
    /// with: `configureTestDatabase` gives each one its own schema.
    static let localTest = Self.postgres(
        host: "localhost",
        port: 5432,
        database: "chickadee_test",
        username: "postgres",
        password: "postgres"
    )

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
            host: host,
            port: port,
            database: database,
            username: username,
            password: password,
            searchPath: searchPath,
            mcpUsername: mcpUsername,
            mcpPassword: mcpPassword,
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
    /// typo here fails the whole `api-tests` lane loudly rather
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

    /// The database id every MCP content read uses: the least-privilege `.mcp`
    /// pool when one is configured, else nil (the default pool). One answer for
    /// `ToolContext.db` and for the `validate_assignment` progress stream,
    /// which reads outside the request (#2335).
    var mcpDatabaseID: DatabaseID? {
        usesDedicatedMCPDatabase ? .mcp : nil
    }
}

func configureDatabase(_ app: Application, settings: DatabaseSettings) {
    var configuration = SQLPostgresConfiguration(
        hostname: settings.host,
        port: settings.port,
        username: settings.username,
        password: settings.password,
        database: settings.database,
        tls: .disable
    )
    // Per-connection `SET search_path TO ...` so tests can isolate themselves
    // by schema and run in parallel against a single shared Postgres
    // database.  Postgres tolerates a non-existent name in search_path until
    // an unqualified reference resolves to it, so the bootstrap path can
    // configure first, then `CREATE SCHEMA`, then run migrations.
    if let searchPath = settings.searchPath, !searchPath.isEmpty {
        configuration.searchPath = searchPath
    }
    configuration.coreConfiguration.options.additionalStartupParameters +=
        PostgresSessionBounds.startupParameters

    // Default 4/loop (#1159): the driver default of 1/loop is the documented
    // ConnectionPoolTimeoutError incident class — one long-held connection per
    // event loop starves every other query on that loop. Override via
    // DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP.
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
    if let mcpUsername = settings.mcpUsername,
        let mcpPassword = settings.mcpPassword
    {
        var mcpConfiguration = SQLPostgresConfiguration(
            hostname: settings.host,
            port: settings.port,
            username: mcpUsername,
            password: mcpPassword,
            database: settings.database,
            tls: .disable
        )
        if let searchPath = settings.searchPath, !searchPath.isEmpty {
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

func registerMigrations(on app: Application) {
    // Note: incremental `Add*` migrations are periodically consolidated into
    // the canonical `Create*` files and the `Add*` structs deleted outright.
    // Production DBs that already applied them still carry the names in
    // `_fluent_migrations`; Fluent ignores history rows whose struct names
    // are no longer registered, so this is harmless.  Fresh deploys produce
    // the same final schema from the `Create*` files alone.  Five rounds so
    // far:
    //   - the #502/#505 round: 13 historical `Add*` migrations folded in
    //     PR #502 (v0.4.171); their remaining no-op stubs were deleted in
    //     PR #505 (VERSION was still 0.4.x when that shipped).
    //   - the second (0.5.0) round: 24 more folded, which also retired the
    //     "column must exist before a later migration full-queries the
    //     model" boot-order hazard class (#1077) — columns no longer
    //     arrive after their table does.
    //   - the third round (#1252): the two slip-day migrations
    //     (`AddCourseSlipDaySettings`, `AddEnrollmentSlipDaysAdjustment`).
    //   - the fourth round (#1806): 15 column and index migrations, from
    //     `AddAvatarIdentity` to `ScopeCourseCodeIndexToTerm`.
    //     `AddLTIGradeSyncFailureReasonColumn` stays: it backfills rows.
    //   - the fifth round: 8 column and index migrations, from
    //     `AddGitHubCourseRepositoryInvitedUser` to `AddAssignmentConcept`,
    //     and the 6 one-time data migrations deleted outright
    //     (`BackfillDeclaredLanguage` to `MoveHandlesToBirds`). Production
    //     had run every one; on a fresh database each data migration
    //     touched no rows.
    // `AddSessionsCreatedAt` is NOT consolidated — it's a real migration
    // against Vapor's `_fluent_sessions` table (not one of our own).
    app.migrations.add(CreateUsers())
    app.migrations.add(CreateCourses())
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
    app.migrations.add(CreateClassItemCoverage())
    app.migrations.add(CreatePreEnrollments())
    app.migrations.add(SessionRecord.migration)
    app.migrations.add(CreateClientDiagnostics())
    app.migrations.add(CreateAssignmentPersonalizationSeeds())
    app.migrations.add(AddSessionsCreatedAt())
    app.migrations.add(CreateAuditLog())
    app.migrations.add(CreateAssignmentExtensions())
    app.migrations.add(CreateAssignmentParticipations())
    // Deliberately left out of the second consolidation round: it interacts
    // with AdminRoutes.deleteUser's hand-rolled cleanup.
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
    // Index-only: it must follow the migrations that create the tables it
    // names (runner_snapshots, job_execution_metrics).
    app.migrations.add(CreateHotPathIndexes())

    // Audit-followup indexes (June 2026): request_metrics(finished_at) and
    // other uncovered hot-path filters. Index-only; it must follow the
    // migrations that create the tables it names.
    app.migrations.add(CreateAuditFollowupIndexes())

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

    // Class-activity leaderboards (docs/class-activities.md): one row per
    // (assignment, student) with the best ranking metric reported so far.
    // New table; FK to `users`, created far above, so no ordering constraint.
    app.migrations.add(CreateLeaderboardEntries())

    // King of the hill (docs/class-activities.md): match rows opened at claim
    // and completed at ingest, plus the one champion row per assignment. New
    // tables; FK to `users`, created far above, so no ordering constraint.
    app.migrations.add(CreateActivityMatches())

    // Round-robin standings (docs/class-activities.md): one row per
    // (assignment, student), recomputed at ingest. New table; FK to `users`.
    app.migrations.add(CreateActivityStandings())
    app.migrations.add(CreateTournamentRuns())

    // The synthetic class corpus run (docs/collaborative-class-assignments.md).
    // New table, no ordering constraint.
    app.migrations.add(CreateClassCoverageRuns())

    // Session reaper sweep column (#1365). Index-only, but it must follow
    // `AddSessionsCreatedAt` above, which is what creates the column.
    app.migrations.add(CreateSessionReaperIndex())

    // Observability prune sweep over submission_diagnostics (#1382 item 8).
    // Index-only; the table is created far above.
    app.migrations.add(CreateSubmissionDiagnosticsPruneIndex())

    // LTI 1.3 platform registrations (docs/lti-1-3.md). New table, no FKs;
    // an empty table means LTI is off.
    app.migrations.add(CreateLTIPlatforms())

    // LTI 1.3 launch (docs/lti-1-3.md slice 2): logins in flight and subject →
    // account links. Both follow CreateLTIPlatforms, whose table they
    // reference.
    app.migrations.add(CreateLTILoginStates())
    app.migrations.add(CreateLTIIdentities())

    // LTI 1.3 grades through AGS (docs/lti-1-3.md slice 4): the push queue.
    app.migrations.add(CreateLTIGradeSyncs())

    // Deep-linking requests carried by a ticket in the picker form, not the
    // session, so the picker works inside the LMS frame. New table.
    app.migrations.add(CreateLTIDeepLinkRequests())

    // Why an AGS push failed, as a code beside the sentence, so the
    // retry-on-launch rule does not key on wording (#1652).
    app.migrations.add(AddLTIGradeSyncFailureReasonColumn())

    // The registered GitHub App (docs/github-submissions.md slice 1). New
    // table, no FKs; an empty table means GitHub submission is off.
    app.migrations.add(CreateGitHubApps())

    // Linked GitHub accounts (docs/github-submissions.md slice 2). New table
    // referencing users; an empty table changes nothing.
    app.migrations.add(CreateGitHubAccountLinks())

    // Course repositories (docs/github-submissions.md slice 4). New tables
    // referencing courses, test setups and users; empty tables change nothing.
    app.migrations.add(CreateGitHubCourseRepositories())

    // Indexes for the periodic sweeps, the leaderboard poll and the push
    // webhook (#1800–#1804). Index only; must follow every `Create*` above
    // whose table it names.
    app.migrations.add(CreateSweepAndPollIndexes())

    // The match-job lookup by `match_submission_id` (#2278). Index only;
    // must follow `CreateTournamentRuns`, which creates the table.
    app.migrations.add(CreateTournamentMatchSubmissionIndex())

    // AI-assisted feedback (docs/ai-assisted-feedback.md): the per-student
    // feedback rows. The two opt-in gates and the attestation are columns in
    // `CreateCourses`, `CreateAssignments` and `CreateCourseEnrollments`.
    app.migrations.add(CreateReflectionFeedback())
    // Class composite (docs/class-composite.md, slice 3): the dealt slots.
    app.migrations.add(CreateCompositeSlots())
    // Class composite, slice 4: the latest contribution of each student.
    app.migrations.add(CreateCompositeContributions())
    // Class composite, slice 6: the reference render of each slot.
    app.migrations.add(CreateCompositeReferences())
    app.migrations.add(CreateCompositeSpares())
    // "Hatch a new bird" (Core/AvatarHatch.swift): the per-term hatch rows.
    app.migrations.add(CreateAvatarHatches())
    // Wardrobe unlocks (docs/student-wardrobe.md, W3): the items a student
    // has earned, kept for good.
    app.migrations.add(CreateWardrobeUnlocks())
    // The course dataset library (docs/datasets-course-library.md, slice 2).
    app.migrations.add(CreateCourseDatasets())
    // The per-student course cohort seed (docs/datasets-course-library.md, slice 4).
    app.migrations.add(CreateCoursePersonalizationSeeds())
    // The deal numbers behind the partition datasets
    // (docs/datasets-course-library.md §4.11). Beside the course seed, not at
    // the end: it needs only the assignments and users tables.
    app.migrations.add(CreateDatasetDeals())
    // The award ledger (docs/achievement-rewards.md, S1): the achievements a
    // student has earned, kept for good.
    app.migrations.add(CreateAchievementAwards())
    // Lab groups (docs/lab-groups.md, slice 1): group sets, groups and
    // memberships.
    app.migrations.add(CreateCourseGroups())
    // Lab groups, slice 2: per-group activity sessions and their attendance.
    app.migrations.add(CreateActivitySessions())
    // The network part of the presenter's and each join's address
    // (docs/lab-groups.md, "Presence").
    app.migrations.add(AddActivitySessionNetworks())
    // Lab groups, slice 3a: a per-group leaderboard's best rows.
    app.migrations.add(CreateGroupLeaderboardEntries())
    // Lab groups, slice 3b: each group's hill.
    app.migrations.add(CreateGroupActivityChampions())
    // Lab groups, slice 3c: the group of a round robin's standings row.
    app.migrations.add(AddActivityStandingGroup())
    // Lab groups, slice 3d: the group of a tournament run.
    app.migrations.add(AddTournamentRunGroup())
    // Lab groups, slice 4: each group's composite.
    app.migrations.add(CreateGroupCompositeSlots())
    app.migrations.add(AddCompositeContributionGroup())
    app.migrations.add(CreateGroupCompositeSpares())
    // Lab groups, slice 5: each group's class-goal snapshot.
    app.migrations.add(CreateGroupAchievementResults())
    app.migrations.add(CreateGroupClassItemCoverage())
    app.migrations.add(AddClassCoverageRunGroup())
    // Course achievements (docs/achievement-rewards.md, S3): the list on the
    // course row.
    app.migrations.add(AddCourseAchievements())
    // One-time cleanup: clears the cell outputs from every stored starter
    // notebook (file side effect only, no schema change). Needs only
    // `test_setups`.
    app.migrations.add(StripStarterNotebookOutputs())

    registerLateSchemaMigrations(on: app)
    registerDataMigrations(on: app)
}

/// The newest schema migrations, registered after the ones above and before
/// the data migrations. A separate function only to keep `registerMigrations`
/// under the body-length limit; the order is still one list, in file order.
private func registerLateSchemaMigrations(on app: Application) {
    // The `completed_at` index on job metrics and the `course_id` indexes on
    // course sections and content items (#2778). Index only; the tables are
    // created far above.
    app.migrations.add(CreateCompletedAtAndCourseIndexes())

    // The `user_id` index on submissions, the `course_id` index on assignment
    // versions and the `status` index on the BrightSpace sync log. Index
    // only; the tables are created far above.
    app.migrations.add(CreateUserTimelineAndSyncLogIndexes())

    // The claim walk's retest pass: pending retests, oldest first, whatever
    // the planner statistics say. Index only; the table is created far above.
    app.migrations.add(CreatePendingRetestIndex())

    // The `validation_variants`, `audit_log` actor and target, and
    // `class_achievements` submission indexes. Index only; the tables are
    // created far above.
    app.migrations.add(CreateAuditAndValidationIndexes())

    // Indexes for foreign keys that had none, on tables that grow: every
    // delete of a referenced row scanned the referencing table. Index only.
    app.migrations.add(CreateForeignKeyIndexes())

    // A content item attached to an assignment renders on that assignment's
    // row. Adds a nullable column to `course_content_items`
    // (CreateCourseContentItems, far above); no data change.
    app.migrations.add(AddContentItemAssignment())

    // The declared assignment type (docs/assignment-types.md). Adds a
    // nullable column to `assignments` (CreateAssignments, far above);
    // `BackfillAssignmentType` below fills it.
    app.migrations.add(AddAssignmentType())

    // A course section's optional default assignment type, in place of its
    // default grading mode (docs/assignment-types.md, phase 3). Adds a column
    // to `course_sections` (CreateCourses), gives the old mode column a
    // default and records "lab" for browser-default sections. Since 2026-11
    // the model maps neither column; a later release drops both.
    app.migrations.add(AddSectionDefaultAssignmentType())

    // A course library dataset's format, and a FHIR version's summary
    // (docs/fhir-datasets-plan.md §6). Adds a column to `course_datasets` and
    // one to `course_dataset_versions` (CreateCourseDatasets, far above); no
    // data change.
    app.migrations.add(AddCourseDatasetFormat())
}

/// The data migrations, registered after every schema migration (#1805).
/// A separate function only to keep `registerMigrations` under the body-length
/// limit; it is called last, so the order is one list. `MigrationOrderTests`
/// reads every registration from `registerMigrations` to the end of this file.
private func registerDataMigrations(on app: Application) {
    // ---------------------------------------------------------------------
    // DATA MIGRATIONS. Keep these at the end, and add every new schema
    // migration ABOVE this block (#1805).
    //
    // A migration that full-queries a model selects every column the model
    // declares, so it must follow every migration that changes the model's
    // table, or a fresh boot selects a column that does not exist yet (the
    // #1077 boot-order hazard, inverted). A raw-SQL migration must follow the
    // migration that adds each column it reads. `MigrationOrderTests` reads
    // this list and checks both rules. Moving an applied migration does not
    // re-run it: Fluent records each by name.
    // ---------------------------------------------------------------------

    // Lab groups, slice 6: a course's LEARN section category becomes a
    // synced group set.
    app.migrations.add(MoveLearnSectionCategoryToGroupSet())

    // Records a declared assignment type for every assignment that existed
    // before the column, from its manifest (docs/assignment-types.md). Reads
    // `assignments` and `test_setups`, so it follows `AddAssignmentType`.
    app.migrations.add(BackfillAssignmentType())
}
