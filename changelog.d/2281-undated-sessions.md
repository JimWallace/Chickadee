### Fixed

- **Session rows older than their `created_at` column are deleted.** The reaper skips a row with no `created_at`, and Vapor never fills that column when it updates a session. So the rows that predate the column stayed in the session table for ever. A one-time migration deletes them, and three comments that said they would age out are corrected. (#2281)
