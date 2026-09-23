### Fixed

- **`get_validation_result` reports the primary run when the variant batch cannot be read.**
  In production the least-privilege `chickadee_mcp` role had no grant on
  `validation_variants`, because the grants file was applied before that table
  existed. The variant query then failed every call, and the log showed only
  `PSQLError`'s generic text. The tool now returns the per-test outcomes, adds a
  warning that names the reason, and logs the Postgres server message and
  SQLSTATE. To get the variant batch back, apply
  `deploy/sql/mcp-least-privilege-role.sql` again on the database host.
