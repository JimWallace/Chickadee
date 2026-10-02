### Fixed

- **The index coverage test reads only its own schema on Postgres.** It listed `pg_indexes` across every schema, so it failed whenever a parallel suite was mid-migration in a schema of its own and still held an index a later migration drops.
