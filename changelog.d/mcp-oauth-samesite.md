### Fixed

- **MCP connector OAuth login over HTTPS.** The session cookie now uses
  `SameSite=None; Secure` when served over HTTPS (falling back to `Lax` on
  plain-HTTP dev). The Claude MCP connector runs the browser OAuth flow in a
  popup opened by `claude.ai`, so the login POST that resumes
  `/oauth/authorize` is treated as cross-site; the previous `SameSite=Lax`
  cookie was dropped on that POST, which both failed CSRF validation and lost
  the stashed authorize request, so no authorization code was ever delivered
  to the connector.
