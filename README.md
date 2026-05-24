<img src="Assets/chickadee-icon-alt.png" alt="Chickadee mascot" width="160" align="right">

# Chickadee

A clean-break rewrite of [Marmoset](https://marmoset.cs.umd.edu), the student code submission and autograding system originally built at the University of Maryland. Written in Swift using [Vapor](https://vapor.codes), targeting macOS and Linux.


## Key features

- **Shell-script test suites.** Any language, any framework — the runner executes scripts and maps the exit code to `pass / fail / error / timeout`. Helper libraries are bundled in the test-setup zip by the instructor.
- **Test dependency trees.** Tests can declare prerequisites (`dependsOn`). If a prerequisite doesn't pass, dependent tests are automatically skipped rather than run against broken code.
- **Three test tiers.** `public` results are shown immediately; `release` results are hidden until the assignment deadline; `secret` results are never shown.
- **In-browser notebook grading.** A full JupyterLite instance is embedded for both student submission and instructor assignment creation — no separate tooling required.
- **Local and SSO auth.** Local username/password for development and self-hosting; full OIDC/SSO (Authorization Code + PKCE) for institutional deployments (Duo, Okta, Entra, etc.). Dual mode runs both simultaneously. Controlled by the `AUTH_MODE` environment variable; roles are auto-assigned from `SSO_ADMIN_USERS` / `SSO_INSTRUCTOR_USERS` allowlists on every login.
- **HMAC-signed runner protocol.** All runner↔server requests are signed with a shared secret. The server auto-generates a diceware passphrase if none is provided.
- **Content-authoring MCP server.** An opt-in [Model Context Protocol](https://modelcontextprotocol.io) endpoint (`/mcp`) lets AI agents author course content (assignments, etc.) over OAuth 2.1 bearer tokens. Deliberately scoped to authoring — it exposes no student data, grades, enrolment, or submissions. See [MCP content-authoring server](#mcp-content-authoring-server).

---

## Deployment

### Docker (recommended)

No Swift toolchain required on the host. The multi-stage `Dockerfile` compiles both binaries inside a build container and produces a minimal Ubuntu runtime image (~150 MB).

```bash
git clone https://github.com/JimWallace/Chickadee.git
cd Chickadee

cp .env.example .env
# Edit .env for auth / URL settings as needed

docker compose up -d --build
```

The first build compiles Swift — expect 5–15 minutes. Subsequent builds with no source changes use the cached layers and are nearly instant.

In Docker Compose, the server auto-generates a three-word `.worker-secret` on
the shared data volume and the runner reads that file automatically. You can
still set `RUNNER_SHARED_SECRET` explicitly in `.env` if you want a fixed secret.

```bash
# Verify
curl http://localhost:8080/health

# View logs
docker compose logs -f server

# Scale to more runner workers
docker compose up -d --scale runner=4

# Update after a git pull
docker compose up -d --build
```

Each scaled Docker runner now derives a unique default worker ID from its
container hostname. If you run runners outside Docker, make sure each one still
uses a distinct `--worker-id`.

For HTTPS, nginx, and production configuration see **[deploy/README.md](deploy/README.md)**.

### VM / systemd

Install Swift via [`swiftly`](https://swift.org/install/linux), build release binaries, and manage them as systemd services with nginx as a reverse proxy. See **[deploy/README.md](deploy/README.md)** for step-by-step instructions, service files, and certbot setup.

---

## Local development

Requires Swift 6 ([swift.org](https://swift.org/download)) and Xcode 16+ on macOS.

```bash
swift build
swift test
```

Run the server:

```bash
# AUTH_MODE defaults to SSO; override for local dev:
AUTH_MODE=local ENABLE_NON_SSO_AUTH_MODES=true \
  swift run chickadee-server serve --port 8080 --worker-secret dev-secret
```

Run the runner against the local server:

```bash
RUNNER_SHARED_SECRET=dev-secret \
  swift run chickadee-runner \
    --api-base-url http://localhost:8080 \
    --worker-id    local-runner \
    --max-jobs     2
```

The admin dashboard also supports a **local runner autostart** toggle that spawns a runner subprocess automatically — useful for development without a second terminal.

For backend observability details, retention settings, and the protected
`/admin/metrics` JSON endpoint, see **[docs/operational-diagnostics.md](docs/operational-diagnostics.md)**.

For backend runner capability matching and assignment requirement rollout
guidance, see **[docs/runner-capability-profiles.md](docs/runner-capability-profiles.md)**.

---

## JupyterLite

`Public/jupyterlite/` is generated output and is checked in. Source-of-truth config lives in `Tools/jupyterlite/`. Rebuild only when updating kernel versions or config:

```bash
scripts/setup-jupyterlite.sh
scripts/build-jupyterlite.sh
```

---

## MCP content-authoring server

Chickadee ships an optional [Model Context Protocol](https://modelcontextprotocol.io/specification/2025-11-25) server at `POST /mcp` (Streamable HTTP, JSON-RPC 2.0) so AI agents can author course content. It is **disabled by default** and **scoped to authoring only** — the tools touch no student data, grades, enrolment, submissions, or administration, and the bearer gate rejects any token lacking a `content:*` scope.

For Phase 1, Chickadee acts as its own OAuth 2.1 authorization server: an admin provisions a service account and mints a short-lived bearer token. (Browser-based OAuth is a future phase.)

### Enable it

Set these and restart the server:

```bash
MCP_ENABLED=true
PUBLIC_BASE_URL=https://your-host        # issuer + resource are derived from this
# Optional overrides / hardening:
# MCP_ISSUER=https://your-host           # defaults to PUBLIC_BASE_URL
# MCP_RESOURCE=https://your-host/mcp     # defaults to PUBLIC_BASE_URL + /mcp
# MCP_TOKEN_TTL_SECONDS=86400            # access-token lifetime (default 24h)
# MCP_SIGNING_KEY_PATH=.mcp-signing-key  # ES256 key; auto-generated on first start
# MCP_ALLOWED_HOSTS=your-host            # DNS-rebinding guard (empty = allow any)
# MCP_ALLOWED_ORIGINS=https://your-host  # rejects mismatched browser Origins
```

Discovery endpoints come online (all unauthenticated):

- `GET /.well-known/oauth-protected-resource` — RFC 9728 metadata (authorization server + supported scopes).
- `GET /.well-known/oauth-authorization-server` — RFC 8414 metadata (authorize / token / register endpoints, JWKS URI, PKCE methods).
- `GET /.well-known/jwks.json` — the ES256 public signing key (RFC 7517), for token verification.

Chickadee acts as its own OAuth 2.1 authorization server, so there are two ways an agent gets a token.

### Browser OAuth (for MCP clients / connectors)

Point an MCP client (e.g. the Claude connector, or the MCP Inspector's OAuth mode) at `https://your-host/mcp`. It discovers the metadata above, then:

1. **Self-registers** via Dynamic Client Registration (`POST /oauth/register`, RFC 7591) — no manual client setup.
2. Opens `/oauth/authorize` in a browser. An **instructor or admin** logs in (if not already) and approves the requested scopes on a consent screen. Students cannot authorize agents.
3. Exchanges the PKCE code at `/oauth/token` for a short-lived access token + a long, **rotating** refresh token (authorize once, works for a term).

The access token's subject is the **human**; the agent is recorded separately (`client_id` / `agent_name`) so its actions are auditable as "*human*, via *agent*" (`mcp.tool_called`). Manage or revoke authorizations at **`/agents`** ("Connected agents"), or `POST /oauth/revoke` (RFC 7009). Replaying a rotated refresh token revokes the whole grant.

### Admin-minted tokens (for headless / CI use)

For non-interactive agents (no human in the loop), mint a token directly. In the web UI go to **Admin → MCP**:

1. **Create account** — provisions a non-loginable `mcp`-role service account. First-login flows (local registration and SSO) can never auto-assign this role.
2. **Mint token** — choose `read + write` or `read only` and copy the token (shown once).

Tokens are stateless JWTs: deleting an account stops new tokens being minted, but a token already issued stays valid until it expires (keep `MCP_TOKEN_TTL_SECONDS` short).

### Smoke test

```bash
TOKEN=...   # the minted token

# Handshake
curl -s https://your-host/mcp \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'

# List tools
curl -s https://your-host/mcp \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# Call a tool
curl -s https://your-host/mcp \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call",
       "params":{"name":"list_assignments","arguments":{"courseCode":"CS136"}}}'
```

A missing/invalid token returns `401` with a `WWW-Authenticate: Bearer resource_metadata="…"` challenge; calling a `content:write` tool with a read-only token returns `403` `insufficient_scope`. The endpoint also works with the [MCP Inspector](https://github.com/modelcontextprotocol/inspector) (paste the token as the bearer credential).

---

## Versioning

Chickadee follows Semantic Versioning in the `0.y.z` phase. Current version: see [`VERSION`](VERSION).
