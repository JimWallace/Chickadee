### Fixed

- **CSRF "No CSRF token provided" failures are now observable and recoverable.**
  CSRF rejections previously threw a bare 403 with no server-side log, making
  production failures impossible to diagnose. The app's CSRF middleware now
  emits a structured `csrf_token_missing` log line (method, path, content-type,
  content-length) when a token never reaches the server, and browser users see
  an actionable "go back, reload, and try again" message instead of a cryptic
  dead-end. Added regression tests covering the per-student extension form's
  real-page token and course codes containing spaces.
