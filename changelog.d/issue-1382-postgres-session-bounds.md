### Added

- **Postgres sessions carry statement and idle-in-transaction timeouts.**
  Every pooled connection (main and MCP pools) now starts with
  `statement_timeout = 60s` and `idle_in_transaction_session_timeout = 5min`,
  so a pathological query or a wedged transaction can no longer hold a pooled
  connection indefinitely — the missing third bound after the #1159
  pool-starvation fixes (pool size, cached dashboard reads). The compose
  Postgres template also documents modest `shared_buffers`/`max_connections`
  tuning; the stock 100-connection ceiling is below the app's pool ceiling on
  large hosts.
