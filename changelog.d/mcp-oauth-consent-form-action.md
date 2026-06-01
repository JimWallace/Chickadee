### Fixed

- **MCP OAuth "Authorize" button silently did nothing.** Clicking *Authorize*
  on the connector consent screen consumed the single-use token but never
  navigated back to the connector, so a second click reported "this
  authorization request has expired or already been used." The consent POST
  303-redirects to the OAuth client's `redirect_uri`, and browsers enforce the
  CSP `form-action` directive across that redirect — the default `form-action
  'self'` blocked the hop to the connector's origin. `GET /oauth/authorize` now
  adds the validated `redirect_uri` origin to `form-action` (mirroring the
  existing SSO-logout fix) and relaxes `Cross-Origin-Opener-Policy` to
  `same-origin-allow-popups` so a popup-driven connector keeps its
  `window.opener` handshake. Both are scoped to the consent response only.
