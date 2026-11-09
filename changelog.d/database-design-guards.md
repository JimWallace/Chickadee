### Fixed

- **Deleting an assignment or a course removes its activity rows.** Badges, leaderboards, king-of-the-hill matches and champions, round-robin standings, tournaments and the LTI push queue, for the class and each lab group, kept a student's ID and submission after the delete. `assignments.slug` is now NOT NULL, as the model already assumed.

### Changed

- **Database design rules and guards.** `docs/database-design.md` states the rules for a new table, migration and query. New guards read the migrated catalog: every foreign key has an index, no index is covered by another, every model field matches its column, and a delete leaves no row keyed to what it deleted. The statement count of six hot requests is pinned. Eighteen foreign keys gained an index (a course purge scanned the request log once per submission), four covered indexes were dropped, and a `db-review` agent covers the judgment half.
