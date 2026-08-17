### Security

- **Operator-managed MCP client allowlist.** Which AI tool may connect to the MCP
  surface is now an enforced deployment policy rather than a human judgement.
  The operator lists the permitted client redirect origins, one per line, in
  `.mcp-client-allowlist` in the work directory (no new environment variable —
  a file-backed store like `.worker-secret`), and both `/oauth/authorize` verbs
  refuse anything else with a 403: the `GET` before any consent token is minted,
  the `POST` again on submit, since the consent token outlives a list change.
  Matching is on the redirect URI's **origin** — the one client-identifying
  field that is neither generated per registration (`client_id`) nor
  self-asserted (`client_name`). `/oauth/register` stays open; a registration
  has always been inert until a course instructor consents, and there is no
  client identity to gate on at registration time.

  **Operator action required before upgrading a production deployment with MCP
  enabled.** An empty allowlist still means "allow any" outside production, so
  development and existing tests are unaffected — but production now refuses to
  mount `/mcp`, `/admin-mcp`, and the OAuth consent flow while the list is
  empty, logging the reason. Create the file before deploying, or the MCP
  surface will not come up.
