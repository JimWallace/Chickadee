// Tests/APITests/SchemaMutatingSuites.swift
//
// The suites that change their database's shape, and so need a schema of
// their own.

import Testing

/// Suites that change their database's SHAPE, and therefore must not be given
/// a recycled schema.
///
/// Five suites, one consequence:
///
///   * `LegacyMigrationNamespaceGuardTests` rewrites the Fluent migration
///     log: it renames a history row into a legacy namespace to prove the
///     server refuses to boot on it.
///   * `MCPAuditFailClosedTests` drops the `audit_log` table outright, to
///     prove a write tool fails closed when its audit record cannot persist.
///   * `GetValidationResultVariantFallbackTests` drops the
///     `validation_variants` table, to prove `get_validation_result` still
///     reports the primary run when the variant batch cannot be read.
///   * `ResultCollectionBackfillMigrationTests` builds a legacy-shaped schema
///     with raw DDL.
///   * `WriteLockedTransactionTests` creates a table in a SQLite file of its
///     own.
///
/// Each is exactly right against a schema it owns, and each would leave a
/// pooled schema different from a freshly migrated one — a corruption that
/// surfaces as unrelated tests failing on a missing table, several files away
/// from the cause.
///
/// (Two of the five are declared and inert.
/// `ResultCollectionBackfillMigrationTests` configures its own bare
/// `.sqliteInMemory()` application and never calls `configureTestDatabase`,
/// and `WriteLockedTransactionTests` opens a SQLite file of its own, so neither
/// asks the pool for anything. They are listed because the scan below flags
/// what they DO, and a list that disagreed with the scan would be a list
/// somebody edits the scan to silence.)
///
/// **Naming a suite is the brittle half of this design, and
/// docs/ci-flakiness.md already records why**: "a guard pointed at a
/// mechanism by name is a guard that changing the mechanism silently empties"
/// (Family 5, attack note 5). So the names are not trusted on their own. Two guards stand behind
/// them and NEITHER knows any of them:
///
///   * `PostgresSchemaPoolTests.everySchemaMutatingSuiteIsDeclared` scans
///     `Tests/APITests/` for suites that touch the migration log or issue DDL,
///     and fails if the set it finds differs from this one. Renaming a suite,
///     splitting it, or writing a new one is then a red test naming the
///     missing suite — not a silent hole.
///   * The pool fingerprints every schema on the way back in (see
///     `MigratedPostgresSchemaPool.sweepStatement(for:on:)`). A schema whose
///     tables, sequences or migration log changed while it was on loan is
///     dropped and rebuilt, and the borrowing test's teardown throws. That
///     guard is keyed on the damage rather than on who did it, so it holds for
///     a suite nobody thought of.
///
/// The second guard is not theoretical: `MCPAuditFailClosedTests` is in this
/// list because the fingerprint caught it on the first full run, having been
/// missed by a hand search that forgot to recurse into `Tests/APITests/MCP/`.
enum SchemaMutatingSuites {
    static let names: Set<String> = [
        "LegacyMigrationNamespaceGuardTests",
        "MCPAuditFailClosedTests",
        "ResultCollectionBackfillMigrationTests",
        "GetValidationResultVariantFallbackTests",
        "WriteLockedTransactionTests",
    ]

    /// True when the test currently running belongs to one of those suites.
    ///
    /// `Test.current` is nil outside a test body — the pool's own builder
    /// applications, for one — and "not running inside a test" mutates
    /// nobody's schema.
    static var currentTestMutatesItsSchema: Bool {
        guard let test = Test.current else { return false }
        return !names.isDisjoint(with: test.id.nameComponents)
    }
}
