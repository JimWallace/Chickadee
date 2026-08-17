# Implementation brief — MCP client allowlist

**Status:** ready to implement. Hand this to an agent as-is.
**Branch:** `claude/uw-mcp-approval-process-ou02ab`
**Why now:** this control is being described in a UW IRA-PIA submission. Nothing
goes in that form that is not merged, so this needs to land before submission.

---

## 1. Context

Chickadee's MCP surface is being put through the University of Waterloo's
Information Risk Assessment / Privacy Impact Assessment process. The reviewers'
central question is *which AI tool can connect*, because UW classifies AI tools
by what data they may receive, and the tool this surface was designed against
(Claude) is **not approved for University data**.

Today the answer is a **human** gate: any client may complete Dynamic Client
Registration, but a registration is inert until a UW-authenticated instructor or
admin consents at `/oauth/authorize`
(`Sources/APIServer/MCP/OAuth/MCPOAuthRoutes+Registration.swift:56`). That gate is
real, but it depends on the instructor knowing which tools UW has approved. A
reviewer discounts that, correctly.

This change turns it into a **deployment policy**: the operator names which client
identities may be authorized, and the server enforces it. That is a claim a
reviewer can verify.

## 2. What to build

An operator-managed allowlist of permitted OAuth client identities, enforced at
both `/oauth/authorize` verbs, with production refusing to mount the MCP
transport when the allowlist is open.

## 3. Design decisions — already made, do not re-litigate

These were settled deliberately. If you believe one is wrong, say so in the PR
description rather than silently changing it.

### 3.1 Key the allowlist on the redirect-URI origin

Not `client_id`, not `client_name`.

- `client_id` is **generated per registration** by DCR, so it cannot be
  configured ahead of time — the operator would have to wait for a client to
  register, read the id out of the database, and add it. Useless as a gate.
- `client_name` is **self-asserted** in the registration request. Anything can
  claim to be "Microsoft Copilot".
- The **redirect URI** is the one field that is both stable per client product
  and already validated on every authorization request
  (`MCPOAuthRoutes+Authorize.swift:32`). It is what actually identifies the
  connecting product.

Match on **scheme + host (+ port if present)** of the registered redirect URI —
i.e. the origin, not the full URI, since products vary the path. Reuse
`SecurityHeadersMiddleware.cspOrigin(of:)` if its normalization fits; otherwise
write a small helper next to the store and test it directly. Compare
case-insensitively on scheme and host. Require `https` except for `http://localhost`
and `http://127.0.0.1`, which stay permitted so local development works.

This also forward-maps cleanly to OAuth Client ID Metadata Documents (see §9),
where the `client_id` *is* an HTTPS URL and its origin is the natural key.

### 3.2 Empty allowlist = open in development, refused in production

Mirror the existing `allowOpenTransportGuards` precedent exactly
(`Sources/APIServer/Configuration/MCPConfig.swift:46-52`): an empty allowlist
means "allow any", **and production refuses to mount `/mcp` and `/admin-mcp`
with it empty**, logging the reason the way the issuer/resource guard already
does at `MCPServerRegistration.swift:113`.

This keeps every existing test and local dev flow working unchanged while giving
the deployment a fail-closed property. Do **not** make the empty case deny-all
globally — that breaks the test corpus for no compliance gain, since the
production guard is what the submission cites.

### 3.3 No new environment variable

This is a **standing repo rule** (`CLAUDE.md` → "What Not To Do"). Do not add one,
and do not overload `MCP_ALLOWED_HOSTS` / `MCP_ALLOWED_ORIGINS` — those are
DNS-rebinding transport guards and mean something else.

Use the established file-backed store pattern instead, as `.worker-secret`,
`.local-runner-autostart`, and `.mcp-signing-key` already do: a file in the work
directory, read through a Swift `actor`. Follow `WorkerSecretStore` /
`LocalRunnerAutoStartStore` for structure.

- File: `<workDir>/.mcp-client-allowlist`
- Format: one origin per line; blank lines and `#`-prefixed lines ignored.
- Absent or empty file = empty allowlist (see §3.2).

### 3.4 Refuse with 403 at the authorize step, both verbs

Follow the existing idiom at `MCPOAuthRoutes+Authorize.swift:192`
(`Abort(.forbidden, reason:)`), not an OAuth error redirect — a redirect hands a
disallowed client something to retry-loop on, and a human-readable refusal tells
the instructor why.

- **GET** `/oauth/authorize`: check *after* the client lookup and redirect-URI
  validation (lines 26-34, so the redirect target is already trusted) and
  *before* the surface resolution at line 51. Refuse before any consent token is
  minted.
- **POST** `/oauth/authorize`: re-check. The consent token has a 600 s TTL
  (line 118) and the allowlist can change inside that window. This mirrors the
  existing re-check of the user's role between render and submit (the guard at
  line 187-192 and its comment).

Reason string should name the origin and say it is not permitted on this
deployment — no hint about how to get added.

### 3.5 Leave `/oauth/register` open

Registration stays unrestricted. It is inert without consent (§1), there is no
client identity to gate on at registration time, and the existing
`maxRegisteredClients` cap already backstops flooding. Gating at authorize is
the whole control. Note this explicitly in the PR description — a reviewer of
this change will ask.

## 4. Files you will touch

| Path | Change |
|---|---|
| `Sources/APIServer/MCP/OAuth/` (new file) | `MCPClientAllowlistStore.swift` — the actor + origin parsing/normalization |
| `Sources/APIServer/MCP/OAuth/MCPOAuthRoutes+Authorize.swift` | the two guards (§3.4) |
| `Sources/APIServer/MCP/Transport/MCPServerRegistration.swift` | production refuses to mount with an open allowlist (§3.2) |
| `Sources/APIServer/MCP/Admin/AdminMCPServerRegistration.swift` | same guard for `/admin-mcp` |
| `Sources/APIServer/APIServerApp.swift` / `Configuration/AppConfig.swift` | wire the store onto the app, include state in the redacted startup summary |

**Should-have, not blocking:** surface the list read/write on the existing admin
MCP page (`Sources/APIServer/Routes/Web/AdminRoutes+MCP.swift`). Without it the
operator edits a file and recycles the container, which is acceptable for now
given deploys are host-side anyway. If you do add UI, follow the stylesheet
conventions in `CLAUDE.md` and run `scripts/check-styles.sh`.

## 5. Tests

Swift Testing only. `@Suite` / `@Test` / `#expect` / `try #require`. **No force
unwraps, including in tests** — `Tests/.swiftlint.yml` no longer exempts them.
Use `.serialized` on anything touching the DB or the filesystem, and the
`with*App` helpers for app fixtures (see `Tests/APITests/AdminRoutesTests.swift`
for the stored-`app` + per-test `withApp` pattern).

Cover at minimum:

1. Origin normalization: scheme/host case, port handling, path ignored,
   `http` rejected except localhost/127.0.0.1, malformed input.
2. Allowlist file parsing: absent file, empty file, comments, blank lines,
   whitespace, duplicate entries.
3. GET `/oauth/authorize` with a non-allowlisted client → 403, **and no
   `MCPConsentRequest` row is created**. Assert the row count, not just the status.
4. GET with an allowlisted client → consent screen renders as before.
5. POST `/oauth/authorize` for a client removed from the allowlist *after* the
   consent token was minted → 403, and the code is not issued.
6. Empty allowlist → both verbs behave exactly as today (no regression).
7. Production environment + empty allowlist → `/mcp` and `/admin-mcp` are not
   mounted, matching the existing open-guards refusal test if one exists.

## 6. Repo rules that will fail CI if missed

- **Do not touch** `VERSION`, `Sources/Core/ChickadeeVersion.swift`, or
  `CHANGELOG.md`. Add **one** fragment under `changelog.d/` instead — see
  `changelog.d/README.md`.
- Run `scripts/format.sh` and `scripts/swiftlint.sh` before pushing.
  SwiftLint runs `--strict`; every warning fails.
- Swift 6 strict concurrency. No `@unchecked Sendable` without a comment
  explaining why.
- No new environment variables (§3.3).
- Push with `git push -u origin claude/uw-mcp-approval-process-ou02ab`, then open
  a **draft** PR.

## 7. Docs to update in the same PR

- `docs/compliance/uw-ai-approval-readiness.md` §4 — add the allowlist to the
  deployment attestation checklist alongside `MCP_ALLOWED_HOSTS` and
  `MCP_DATABASE_USER`.
- `docs/compliance/mcp-student-data-audit-2026-07.md` §3 F-9 — same, it is an
  operator-attested production property.
- `docs/admin-mcp.md` — if you add the admin UI.

Keep the wording factual and mechanism-level. These files are being read by
external reviewers.

## 8. Acceptance criteria

- A client whose redirect origin is not on the list cannot obtain a consent
  token or an authorization code, at either verb.
- With the file absent, every existing test passes unchanged.
- A production configuration with an empty allowlist does not mount either MCP
  transport, and logs why.
- The operator can change the list without a code change or a new env var.
- `scripts/format.sh`, `scripts/swiftlint.sh`, and the full test suite are green.

## 9. Explicitly out of scope

- **OAuth Client ID Metadata Documents.** The MCP spec now deprecates Dynamic
  Client Registration in favour of CIMD, where the `client_id` is an HTTPS URL
  the authorization server fetches metadata from. That is a better long-term
  identity model and composes with this allowlist (§3.1), but it needs
  third-party HTTPS fetching with SSRF handling, caching, `redirect_uris`
  validation against the fetched document, and rotation. Not now.
- **Federating to UW's IdP as the MCP authorization server.** Requires UW to mint
  resource-bound tokens (RFC 8707) for this app. Out of our hands.
- Anything touching `MCP_MODE`, which is being held `off` in production pending
  the assessment outcome.
