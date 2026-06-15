# Chickadee MCP Server — Pre-Approval Security & Privacy Audit

Prepared for the UW Information Risk Assessment (IRA) and Information Steward
review. **Phase 1 (read-only) audit.** No code was modified; this report and the
five companion documents in `docs/compliance/` are the deliverables.

- Repository: `JimWallace/Chickadee` — branch `claude/focused-curie-y0gaf8`
- Snapshot: `VERSION` **0.4.435**
- Scope: the MCP server under `Sources/APIServer/MCP/` and the auth, audit, and
  data-access code it depends on.

Companion documents:
- `tool-inventory.md` — one row per tool (36 tools)
- `data-flow-inventory.md` — per-tool reads / off-boundary payload / PII
- `policy46-classification.md` — Policy 46 class per outbound data type
- `remediation-plan.md` — P0/P1/P2 with acceptance criteria
- `trust-boundary.md` — architecture note + Mermaid figure

---

## Executive summary

Chickadee's MCP server is a **well-bounded, special-purpose content-authoring
surface** with genuine authentication, per-course authorization, and a tool
catalog that contains no general escape hatch. It is much closer to
approval-ready than most first submissions. There is **one material
architectural gap** to close and a small number of audit/egress refinements.

**The single most important correction to the audit brief's framing:**
Chickadee **is the MCP server**; it does **not** call any external model/LLM
API. There is no model-provider client, API key, or outbound model call
anywhere in the codebase (verified across `Sources/` and `Package.swift`). The
data path to a third-party model lives entirely in the *connecting agent* (the
Claude connector), which runs outside Chickadee's process and outside the
UW-hosted trust boundary. Therefore:

- The off-boundary content is **whatever a tool returns** to the agent, so the
  governing controls are the **bounded tool surface** and the **student-data
  wall** — not a model-API egress filter (which does not, and need not, exist
  in Chickadee).
- The provider-side data-handling controls (zero-retention / no-training,
  region) are a **contract/configuration property of the connector**, to be
  confirmed in the paperwork — not something Chickadee code can set.

**Headline status by control area:**

| # | Control area | Status |
|---|--------------|--------|
| 1 | Bounded capability surface | **Pass** (one documented, bounded escape hatch) |
| 2 | Data flow & egress (minimisation) | **Pass / Risk** (identity stays server-side; reference-solution egress is the item to minimise) |
| 3 | Student-data wall | **Gap** (holds by convention, not architecturally) — **highest priority** |
| 4 | AuthN / AuthZ / Audit | **Pass** for authN+authZ; **Gap** on audit completeness |
| 5 | Network egress control | **Gap** (no app/deployment allowlist; no model endpoint involved) |
| 6 | Secrets & model-provider config | **Pass** |
| 7 | Policy 46 classification | **Pass** (table delivered; no student PII in scope) |

No P0 finding is a live data leak today. The P0 work is to make the
student-data wall **demonstrable from configuration** rather than provable only
by reading every handler — which is exactly the bar this submission set ("a
reviewer can verify every claim directly from the repo").

---

## Control 1 — Bounded capability surface — **Pass**

The catalog registers 36 typed tools (`MCPServerRegistration.swift:18-55`).
Every tool declares a typed `Input`/`Output`; the dispatcher decodes raw
JSON-RPC into the typed `Input` before calling the handler
(`ContentTool.swift:122-145`), so there is no untyped "run this request"
surface.

We checked specifically for the five unassessable capabilities and found none
unbounded (full table in `tool-inventory.md`):

- **No in-process code execution.** No `Process`/`eval` in tool handlers.
  `preview_personalization` evaluates instructor expressions in a **separate,
  environment-scrubbed `python3` subprocess** (the existing
  `PersonalizationEvaluator`), not in the server process.
- **No raw/dynamic SQL.** All DB access uses Fluent's typed query builder; no
  `SQLDatabase`/`raw(` under `MCP/`.
- **No shell-out, no fetch-any-URL.** No tool issues an outbound request.

**The one escape hatch — `author_script` — is bounded** (`AuthorScriptTool.swift`):
it accepts a bare `filename` (sanitised, no path separators, `:187-192`) and
verbatim `content`, writes it into *that assignment's* test-setup zip
(`:298`, `:303-334`), is course-scoped (`:194`), refuses to overwrite generated
scripts (`:199-203`), and re-runs validation on save (`:244`). The content is
**not executed at MCP-call time** — it runs only later, in the **Worker**, under
the `ScriptRunner` sandbox (Linux `unshare` namespaces / macOS `sandbox-exec`).
This is the same capability a human instructor already has when uploading a test
script; the residual is recorded in `tool-inventory.md` for the IRA.

---

## Control 2 — Data flow & egress (minimisation) — **Pass / Risk**

Full per-tool trace in `data-flow-inventory.md`.

- **Instructor identity never egresses.** No tool places the acting subject's
  name, email, UW ID, or student number in its return payload (verified by
  searching all handler outputs). Identity is used only for authz
  (`ToolContext.requireEligibleSubject`) and the audit row
  (`actorUsername = "<subject>-MCP"`, `MCPDispatcher.swift:226-236`), both
  server-side. **Pass.**
- **`get_validation_result` is minimised correctly** — it drops `submissionID`
  and `userID` and returns only the instructor's reference-solution outcomes
  (`GetValidationResultTool.swift:18-24`).
- **Risk:** the reference solution / answer key (Policy 46 *Restricted*) is
  returned by `get_solution`, `update_solution`, and materialised in
  `preview_personalization`. This is legitimate for those tools, but it is the
  most sensitive artifact crossing to the agent. Minimisation lever in
  `remediation-plan.md` P1-3.

---

## Control 3 — Student-data wall — **Gap (highest priority)**

**This is the finding that matters most for approval.**

### Call graph (MCP handler → data access)

```
tools/call (MCPDispatcher.swift:185)
  └─ tool.invoke (ContentTool.swift:133)
       └─ <Tool>.execute(input, context)
            ├─ context.authorizedAssignment*/authorizeCourseAccess (ToolContext.swift:67-115)
            │     ├─ requireEligibleSubject → APIUser.query (ToolContext.swift:44-57)   [PII row, authz only]
            │     └─ userIsEnrolled → APICourseEnrollment.query (CourseAccessHelpers.swift:35-40)
            └─ data access on context.db  (== request.db, ToolContext.swift:35)
                 ├─ authoring: APICourse / APIAssignment / APITestSetup / APICourseSection
                 └─ submissions/results ONLY via .filter(kind == .validation)
                       GetValidationResultTool.swift:125,166-180 ; loadExistingSolution (get/update_solution)
```

### What the wall is, and where it leaks conceptually

- **By scope:** tokens carry only `content:read` / `content:write`; nothing in
  `ContentScope` grants student data (`ContentScope.swift:1-11`).
- **By handler discipline:** tool handlers query the authoring store and, for
  submissions/results, **filter to `kind == .validation`** — the instructor's
  own reference-solution runs, never a student submission.
- **The gap:** `ToolContext.db` is `request.db` (`ToolContext.swift:35`) — the
  **same full-privilege connection** used by the whole app. The MCP path can,
  in principle, read every table: `submissions`, `results`, `grade_overrides`,
  roster/PII on `users`, diagnostics, etc. The two student-data tables it *does*
  open (`submissions`, `results`) are kept safe only by an application-level
  `.filter(\.$kind == .validation)`. A future handler that omits that filter, or
  a query bug, reaches student rows. The authz layer also necessarily reads
  `APIUser` (which carries email/studentID/userIdentifier) — legitimately, and
  without egressing it, but it shows the connection is unrestricted.

**Conclusion:** "the service is *incapable* of reading submissions, grades, or
roster PII" is **not demonstrable from configuration** today. It is true of the
current code by convention. The brief's bar — architectural enforcement, not a
comment — is **not yet met.**

**Remediation landed:** both forms now exist. (1) In-process boundary —
`MCPStudentDataBoundary` is the single validation-filtered accessor to the
`submissions`/`results` tables, and `MCPStudentDataWallTests` fails the build if
any tool handler names a student-data model directly (a compile-/test-time
wall, verifiable from the repo). (2) Deployment-time DB wall — an optional
dedicated connection pool (`MCP_DATABASE_USER`/`MCP_DATABASE_PASSWORD`,
`DatabaseID.mcp`) lets the MCP path run as a least-privilege role with **no**
access to student tables and validation-only RLS on `submissions`/`results`
(`deploy/sql/mcp-least-privilege-role.sql`); the content-edit re-grade was moved
to the privileged pool so the role can fully wall off student submissions
without breaking auto-regrade. The operator provisions the role; the in-process
boundary is enforced unconditionally.

---

## Control 4 — Authentication, authorization, audit

### 4a. Authentication — **Pass**

Every `/mcp` request is gated by `MCPBearerAuthMiddleware`
(`MCPServerRegistration.swift:125-126`), which verifies an ES256 JWT's
signature + `exp`, enforces issuer and audience (RFC 8707 — the token must be
minted for *this* resource, `MCPBearerAuthMiddleware.swift:35`), requires at
least one content scope, and clamps scopes to the `MCP_MODE` ceiling **per
request** (`:49-58`). No authenticated principal ⇒ the transport aborts
(`MCPRoutes.swift:82-84`).

Per-route reachability:

| Route | Auth | Notes |
|-------|------|-------|
| `POST /mcp` | **Bearer (required)** | tool dispatch; `MCPServerRegistration.swift:125` |
| `GET/DELETE /mcp` | n/a | 405 (stateless transport) `MCPRoutes.swift:127-134` |
| `GET /.well-known/oauth-protected-resource` | **Public (by spec)** | RFC 9728 metadata; no secrets `MCPMetadataRoutes.swift:34` |
| `GET /.well-known/oauth-authorization-server` | **Public (by spec)** | RFC 8414 metadata `MCPMetadataRoutes.swift:46` |
| `GET /.well-known/jwks.json` | **Public** | **public** ES256 key only `MCPMetadataRoutes.swift:65` |
| `GET /oauth/authorize` | **Session (human login)** | consent screen `MCPServerRegistration.swift:156-157` |
| `POST /oauth/authorize` | Consent-token + rate-limit | cookie-independent (Safari/ITP); `:162-167` |
| `POST /oauth/token` / `revoke` / `register` | Rate-limited back-channel | PKCE S256; `:166-170` |
| Admin agent management (`MCPAgentsRoutes`) | **Admin role** | `req.auth.require(APIUser)` + role; `MCPAgentsRoutes.swift:21,71` |

No tool-bearing route is reachable unauthenticated. The three public
`.well-known` endpoints are required to be public by the OAuth/MCP specs and
expose only discovery metadata and the public signing key. **Risk (minor):**
the DNS-rebinding `Host`/`Origin` guards default to "allow any" and only *warn*
in production when unset (`MCPServerRegistration.swift:181-192`) — see P2-2.

### 4b. Authorization (per-resource ownership) — **Pass**

Every handler that accepts a course/assignment/section identifier authorizes it
through `authorizeCourseAccess` / `authorizedAssignment*`
(`ToolContext.swift:67-115`), which requires the token subject to hold an
**enrolment row in that specific course** — admins included for the *agent*
path, so agent reach ⊆ the human's enrolled courses
(`CourseAccessHelpers.swift:1-58`). Verified across all 36 tools (citations in
`tool-inventory.md`). `clone_assignment` correctly authorizes **both** source
and target courses (`CloneAssignmentTool.swift:95,117`). Listing tools scope
their output to enrolled courses (`ListCoursesTool.swift:57`). Students are
rejected at the tool layer regardless of token (`ToolContext.swift:52-55`).
The residual risk is **regression** on a future tool — closed by the registry-
driven guard test in P0-2.

### 4c. Token handling — **Pass**

- **Minting/signing:** ES256, key persisted mode 0600, auto-generated on first
  start (`MCPTokenAuthority.swift:33-59`).
- **Lifetime:** browser-flow access tokens default **10 min**
  (`accessTokenTTLSeconds = 600`, `MCPConfig.swift:55,84`) so revoking a grant
  takes effect quickly; admin-minted tokens default 24h (`:80`). Authorization
  grants (refresh validity) default **120 days** (`:56,85`).
- **Revocation:** `POST /oauth/revoke`; grants carry a `revoked` flag and
  refresh tokens rotate with prior-hash **reuse detection**
  (`mcp.refresh_reuse_detected`, `APIAuditLogEntry.swift:143`); the human's role
  is re-checked at consent and on refresh (`MCPOAuthRoutes.swift:190,351`).
- **Read-only clamp** is applied per request, so flipping `MCP_MODE` to
  `read_only` strips write from existing tokens with no revocation
  (`MCPMode.swift:11-15`, `MCPBearerAuthMiddleware.swift:49-58`).
- **Tokens are never logged.** No `logger.*` call under `MCP/` emits a token,
  code, or secret (verified). The dispatcher logs only the connecting client's
  name/version on `initialize` (`MCPDispatcher.swift:273-279`).

### 4d. Audit logging — **Gap**

Every authorized tool call writes an `mcp.tool_called` row to the durable
`audit_log` table (`MCPDispatcher.swift:208,226-236`; model
`APIAuditLogEntry.swift`), and the streaming `validate_assignment` path audits
too (`MCPRoutes.swift:273`). Records carry actor (`<subject>-MCP`), the acting
agent (`via_agent`), timestamp, remote IP, and user-agent. Retention is **90
days** by default, configurable via `AUDIT_LOG_RETENTION_DAYS`, swept hourly
(`AuditLogReaperService.swift`) — a defensible FIPPA/PIPEDA posture. **Tool
arguments are never logged.**

Three gaps against "every tool call is audited with actor/params-classification/
outcome":

1. **Outcome is not recorded.** The audit fires *before* `tool.invoke`
   (`MCPDispatcher.swift:208` precedes `:210`), so a row never reflects
   success/failure.
2. **No target resource.** The row carries only `{tool, via_agent}` — not which
   assignment/course was acted on — even though `AuditLogger.record` supports
   `targetType`/`targetID`. A reviewer can see *that* `update_solution` ran, not
   *on what*.
3. **Best-effort durability.** `AuditLogger.record` swallows DB-write failures
   so the action proceeds (`AuditLogger.swift:49-55`); a tool can therefore run
   without a persisted row if the write fails.

Remediation: `remediation-plan.md` P1-1 (outcome + target, arguments still
excluded) and P1-2 (write-failure policy).

---

## Control 5 — Network egress control — **Gap (deployment)**

There is **no application-level egress allowlist** in the repository — no Squid
allowlist, iptables rules, or NetworkPolicy. The only outbound-traffic knob is
an **optional forward proxy**, `OUTBOUND_HTTP_PROXY`
(`Configuration/OutboundProxyConfig.swift`; applied in `APIServerApp.swift`),
which routes egress through a gateway but does not restrict destinations.

Cross-checked against the data-flow analysis, the server's **only** outbound
destinations are:

| Destination | Purpose | Code |
|-------------|---------|------|
| OIDC IdP (UW DUO) | discovery, JWKS, token, revocation | `OIDCConfiguration.swift`, `SSOAuthRoutes.swift`, `AuthRoutes.swift` |
| BrightSpace / D2L | grade sync (Valence HMAC) | `Services/BrightSpaceAPIClient.swift` |
| `uwaterloo.ca` calendar | academic-dates `.ics` (cached 24h) | `Services/UWImportantDatesService.swift` |
| operator webhook (optional) | health alerts | `Services/AlertNotifier.swift` |
| API server (internal) | worker poll/report/artifacts | `Sources/Worker/*` |

**None of these is a model API** — consistent with the finding that Chickadee
makes no model call. No telemetry, analytics, or runtime CDN fetches were found
(browser libraries are vendored, per `CLAUDE.md`). The gap is that egress
restriction is left entirely to the network layer with no artifact in the repo
to verify. **Remediation landed:** `deploy/egress-allowlist.md` now documents
the deployment-layer allowlist (Squid / nftables / NetworkPolicy options)
limited to the five destinations above — explicitly *no* model endpoint — for
the operator to apply in the hosting environment.

---

## Control 6 — Secrets & model-provider configuration — **Pass**

- **No hard-coded secrets.** All credentials load from environment via the
  centralised `AppConfig` tree (`Configuration/`); a scan of `Sources/` found no
  credential literals. (Secret *values* were not printed during this audit.)
- **Redaction.** The startup summary replaces secret-bearing fields with
  `[redacted]`/`[set]` and there is a CI grep guardrail to keep it honest
  (`AppConfig.logSummary`).
- **Committed config is placeholders only.** `.env.example`, `deploy/.env.example`,
  `docker-compose.yml`, `Dockerfile` carry `YOUR_*`/`change-me`/`[redacted]`
  placeholders; `.env` is git-ignored.
- **MCP signing key** auto-generated, mode 0600, at `MCP_SIGNING_KEY_PATH`
  (`MCPTokenAuthority.swift:47-59`).
- **No model-provider configuration exists** — no `ANTHROPIC_API_KEY`/
  `OPENAI_API_KEY`, no LLM SDK in `Package.swift`, no client base-URL or
  retention/no-training headers. This is expected: Chickadee does not call a
  model. The provider data-handling terms (zero-retention, no-training, region)
  are properties of the **connector** that talks to Chickadee and must be
  confirmed in the paperwork, not in this codebase. Rotation note to add in
  P0-3.

---

## Control 7 — Policy 46 classification — **Pass**

Delivered as `policy46-classification.md`. Ten distinct outbound data types,
each with a provisional class and rationale. The reference solution / answer
key, secret-tier tests, support files, personalization expressions, and
validation outcomes are **Restricted** (the high-water mark); problem
statements and metadata are **Confidential**; server capability info is
**Public**. **No data type carries student PII, grades, or submissions** — the
sensitivity here is academic-integrity, not privacy-of-individuals — which is a
direct consequence of the student-data wall (once P0-1 makes it architectural).

---

## Prioritised findings (index)

| ID | Control | Finding | Status | Remediation |
|----|---------|---------|--------|-------------|
| AUDIT-3 | Student-data wall | MCP runs on the full-privilege `request.db`; wall is by convention | **Gap (P0)** | P0-1 |
| AUDIT-4b | AuthZ | Per-course ownership enforced on all 36 tools; regression risk | **Pass (verify)** | P0-2 |
| AUDIT-6 | Secrets | Clean; no model key; rotation undocumented | **Pass (verify)** | P0-3 |
| AUDIT-4d-i | Audit | Outcome not recorded (audit precedes invoke) | **Gap (P1)** | P1-1 |
| AUDIT-4d-ii | Audit | Target resource not recorded | **Gap (P1)** | P1-1 |
| AUDIT-4d-iii | Audit | Audit write is best-effort; tool can run without a row | **Risk (P1)** | P1-2 |
| AUDIT-2 | Egress minimisation | Reference solution (Restricted) egresses via 3 tools | **Risk (P1)** | P1-3 |
| AUDIT-5 | Network egress | No app/deployment allowlist (no model endpoint involved) | **Gap (P2)** | P2-1 |
| AUDIT-4a | Transport | DNS-rebinding guards default to allow-any (prod warns only) | **Risk (P2)** | P2-2 |

---

## Definition-of-done check against the approval bar

| Approval requirement | Current state |
|----------------------|---------------|
| Every tool special-purpose; no unbounded escape hatch | **Met** — 36 typed tools; `author_script` bounded + sandboxed |
| From configuration alone, cannot read submissions/grades/PII | **Not yet** — P0-1 makes it architectural |
| Every route authenticated; every resource ownership-checked | **Met** — bearer gate + per-course enrolment on all 36 tools |
| Every tool call audited; no secrets/raw payloads in logs | **Partial** — audited, no secrets/args logged; missing outcome + target (P1-1/P1-2) |
| Outbound traffic allowlisted to the model API only | **Reframed** — no model egress exists; allowlist Chickadee's 5 real destinations (P2-1) |
| Every outbound data type Policy-46 classified | **Met** — `policy46-classification.md` |
| Six `docs/compliance/` artifacts, internally consistent, repo-verifiable | **Met** — delivered |

**Phase 1 stops here.** Recommended approval-blocking work before submission:
**P0-1** (architectural student-data wall) and **P1-1** (audit outcome +
target). The rest are strong-to-have and largely documentation/deployment.
Awaiting your go-ahead before any Phase 2 code change.
