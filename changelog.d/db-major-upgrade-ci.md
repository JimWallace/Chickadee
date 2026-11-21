### Fixed

- **`scripts/db-major-upgrade.sh` works end to end on PostgreSQL 16 → 18.** Its inventory query failed on every run (`text || "char"` is ambiguous), the PostgreSQL 17 `MAINTAIN` privilege made the before/after inventory differ, and a failed run hung forever after its rollback instead of exiting; the CI test (#3148) now passes in about a minute and also covers `--pin-current`.
