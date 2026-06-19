### Fixed

- **BrightSpace authorize uses an exact Trusted-URL `x_target`.** D2L matches
  the registered Trusted URL strictly (a parent host does **not** cover a
  sub-path, and a query string breaks the match — `"x_target does not match the
  allowed values"`). The authorize handler no longer appends a `?state=` query
  to the callback, so its `x_target` is exactly the registered callback URL
  (`{PUBLIC_BASE_URL}/admin/brightspace/valence-callback`); CSRF is now bound to
  the admin session that initiated the authorize rather than an echoed token.
