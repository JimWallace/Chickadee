### Fixed

- **MCP connector authorization now works in Safari (and any browser that
  blocks cross-site cookies).** The OAuth consent submit (`POST /oauth/authorize`)
  no longer depends on the session cookie surviving the cross-site hop — which
  Safari/ITP drops, causing a "CSRF token" 403 on Authorize. The consent screen
  now mints a single-use, server-stored consent token (carrying the consenting
  user's identity and standing in for CSRF) that the form submits instead. The
  `SameSite=None` session cookie alone could not fix this, because Safari gates
  cross-site cookies independently of `SameSite`.
