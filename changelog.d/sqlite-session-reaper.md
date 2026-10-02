### Fixed

- **The session reaper deletes old sessions on SQLite too.** SQLite stores the `created_at` column default as text, and orders every number below every text value, so the reaper's date filter never matched a session row Vapor wrote, and a SQLite database kept every session for ever. On SQLite the reaper now compares both encodings as seconds since 1970. Postgres, the production database, was not affected (#1810).
