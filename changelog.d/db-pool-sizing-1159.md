### Changed

- **Fluent connection-pool size is now explicit and configurable (#1159).**
  The pool was never configured, riding the driver default of one connection
  per event loop — the documented `ConnectionPoolTimeoutError` incident
  class, where one long-held admin query starved every other query on its
  loop. Postgres now defaults to 4 connections per event loop (SQLite stays
  at 1 — its writes serialize anyway), overridable via
  `DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP`, logged in the startup summary,
  and documented in the deploy README alongside the `max_connections`
  budgeting guidance.
