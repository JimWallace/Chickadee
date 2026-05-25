### Fixed

- **Timeout logout no longer 403s on a stale CSRF token.** `POST /logout` is now
  exempt from CSRF validation. When the inactivity watchdog posts
  `/logout?reason=timeout` from a long-idle tab, the server-side session (and its
  CSRF secret) is often already gone, so the page's stale token failed validation
  and the user hit a `403 Invalid CSRF token` instead of landing on the
  timeout-notice login page. Login and register stay CSRF-protected; the logout
  handler is idempotent and logout-CSRF is low risk (worst case: an unwanted sign-out).
