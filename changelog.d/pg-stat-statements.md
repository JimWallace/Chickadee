### Added

- **Per-statement database timing.** The new admin MCP tool `get_query_stats` reports the top database statements from the Postgres extension `pg_stat_statements`: calls, total / mean / max time, rows, cache hit rate and share of total time. The server creates the extension at startup when Postgres has loaded the library; until then the tool says which step is missing. Turning it on in production needs one host-side change and one `db` restart: see `docs/operational-diagnostics.md` §"Database statement timing".
