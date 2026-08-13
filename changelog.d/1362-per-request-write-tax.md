### Fixed

- **A page view no longer rewrites its own session row.** Vapor's session
  middleware has no dirty flag, so it called `updateSession` on the way out of
  every request that arrived with a cookie — an `UPDATE` on `_fluent_sessions`,
  the table every authenticated request already reads, to store back the bytes
  it had just read. The Fluent driver is now wrapped so an untouched session
  skips the write. Sessions still write on the requests that actually change
  them (login, the OIDC handshake, an active-course switch, a stashed draft
  form), and lifetime is unaffected: the driver only ever set the data column,
  with expiry coming from `created_at` and the idle timeout enforced against
  the user row.
- **The two-second submission poll no longer writes a metrics row per poll.**
  A student's result view polls the submission-status route every two seconds
  while grading is pending, which during a deadline makes it the
  highest-frequency request the server takes — and each one persisted an
  `api_request_metrics` INSERT on the response path. It is now excluded the
  same way idle runner check-ins already were. Errors still record, and
  `/results`, `/download` and the collection route are untouched.
