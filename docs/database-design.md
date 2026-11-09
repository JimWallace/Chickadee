# Database design rules

The rules for a new table, a new migration and a new query. Each rule is here
because a load test or an audit found its defect after it shipped. The
2026-11 audit found the same few defect classes behind a run of perf PRs
(#2894 to #2923). Each PR fixed one call site and nothing stopped the next.

Four guards and one review hold these rules. The guards run in the
`api-tests` lane; the review runs in a Claude Code session (CI runs no
model).

| Rule | Held by |
|---|---|
| Every foreign key has an index | `SchemaDesignTests.everyForeignKeyHasAnIndex` |
| No index is covered by another | `SchemaDesignTests.noIndexIsCoveredByAnother` |
| Timestamps are `timestamptz`; new JSON is `jsonb` | `SchemaDesignTests.columnTypesFollowTheConventions` |
| Every model field has a column, and no non-optional field sits over a nullable column | `ModelSchemaAgreementTests` |
| A delete leaves no row keyed to what it deleted | `StudentWorkDeletionCoverageTests` |
| A hot request sends a fixed number of statements | `HotPathStatementBudgetTests` |
| Everything that needs judgment (below) | the `db-review` agent |

The schema guards read the migrated test schema through `pg_catalog`
(`Tests/APITests/Guards/SchemaCatalog.swift`), not the Swift sources. Each
allowlist holds what was there when its rule arrived, with the reason, and may
only shrink: an entry that no longer applies fails its test.

## A new table

- **Index what its queries filter on, in the `Create*` migration.** Do not
  wait for a load test. Name every query the feature runs and give each one
  an index whose leading columns match its filter. Before 2026-11, 45 of the
  67 named indexes arrived later in index-only migrations.
- **Index every foreign key.** Postgres does not index the referencing side.
  Without an index, each deleted parent row scans the child table once. A
  course purge scanned `request_metrics` once per submission this way.
- **Name indexes `idx_<table>_<columns>`**, with the full table name.
- **Prefer a foreign key.** A key column without one (`test_setup_id` as a
  string, a soft-removed `group_id`) needs a reason in the migration's header
  and a delete in `SetupRowDeletion` or the user delete.
  `StudentWorkDeletionCoverageTests` seeds a row into every table with a
  `test_setup_id`, `submission_id`, `assignment_id` or `course_id` column and
  fails if the assignment or course delete leaves it.
- **Enforce uniqueness in the database.** "One row per X" is a unique
  constraint, or a partial unique index for "one running row per X". A
  read-then-write under READ COMMITTED lets two requests both pass the read.
  Use `createIgnoringConflict` for first-insert-wins.
- **Types.** `.datetime` (timestamptz) for times. `jsonb` for new JSON. A
  status or kind column whose values are a Swift enum's raw values: a partial
  index or query that names a value must reference the Swift constant, so a
  rename cannot silently empty the index.
- **Keep large values off hot rows.** A blob that a hot query does not need
  goes in a side table (`result_collections`, #1173) or behind a projection.
- **Plan retention.** A table that grows with traffic (a log, a metric, a
  ledger) gets a leased reaper sweep, or a line in its migration header that
  says why it is kept.

## A migration

- **Additive in 0.x.** Two server versions share the database during a
  blue-green deploy (`docs/zero-downtime-deploy.md`). Add a column nullable or
  with a default. Do not drop or rename a column the running version reads;
  drop it a release later.
- **An index on a large table** (`submissions`, `results`,
  `request_metrics`, the diagnostics tables) blocks writes while it builds,
  and the build counts against the 60 s `statement_timeout`. Keep such builds
  small, or build the index `CONCURRENTLY` (Fluent does not wrap a migration
  in a transaction, so it can) and check for an invalid index afterwards.
- **A schema migration goes above the data-migration block** in
  `registerMigrations` (#1805). `MigrationOrderTests` checks the order.
- **A `Create*` fold must not change a column.** Consolidating `Add*`
  migrations into `Create*` once changed nullability against production;
  `ModelSchemaAgreementTests` now fails when a non-optional field sits over
  a nullable column, the direction that fails to decode a NULL row. The other
  direction (an optional field over a NOT NULL column, as every `@Timestamp`
  is) is safe and not reported.

## A query

- **No query per row in a loop.** Read the rows the loop needs in one query
  (`~~` with `chunkedForInFilter`) and index them in a dictionary. Write N rows
  with one statement, or at least inside one transaction.
- **Count, group and pick the latest in SQL.** Do not load a time window or a
  setup's whole history to count it, group it or keep each user's newest row
  in Swift (#2921). Use `COUNT`, `GROUP BY` and `DISTINCT ON`.
- **Project.** A full-model read of `test_setups` loads the manifest, and of
  `submissions` loads `materialization_json`. Use `.field(...)` or a SQLKit
  row type (`SubmissionStatusRow`) when only a few columns are needed.
- **Read a row once per request.** Pass the setup or assignment you already
  read down to the helpers (#2916), instead of reading it again by ID.
- **Bound every list.** A list shown to a person or returned to MCP has a
  limit, and pages with a key, not an offset, on a large table.
- **One transaction for one change.** Writes that must land together share a
  transaction. Do no file or network work inside one: it holds a pooled
  connection, bounded only by the 5-minute idle-in-transaction timeout.
- **Make a row claimable last.** A row a runner can claim is saved after
  every row the runner's report needs.
- **Bind values.** `\(bind:)` for every value. `\(unsafeRaw:)` only for a
  schema constant or a closed enum.

## Hot paths and their budgets

`HotPathStatementBudgetTests` pins the exact statement count of the idle
runner poll, a claim, a result report, the status poll, the student dashboard
and the submission page. A change in either direction fails the test: lower
the budget when a change saves a statement, and give the reason in the commit
when it adds one. The test prints every statement the request sent.

To measure a query's plan, use `EXPLAIN (ANALYZE, BUFFERS)` against a
database seeded to production size. The CI database is nearly empty, so its
plans prove nothing. The claim walk's index coupling is in
`docs/feature-interactions.md`. In production, the admin MCP tool
`get_query_stats` reads `pg_stat_statements`.

## Connections

Each server process opens up to 4 connections per event loop (one loop per
core), and the optional MCP pool as many again. During a blue-green overlap
two servers are connected. Keep
`2 × 4 × cores` (doubled again with the MCP pool), plus the runner, below
Postgres's `max_connections` (200 in `docker-compose.yml`).
