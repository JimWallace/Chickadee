### Fixed

- **The migration order and user-reference scans read every migration.** Both scans found a migration's table only in the form `schema("table")`. Sixteen migrations name their table as `schema(Model.schema)`, and a few use raw `ALTER TABLE`, so the scans skipped them. One shared helper now reads all three forms, and it fails when it cannot resolve a model's table. (#2280)
