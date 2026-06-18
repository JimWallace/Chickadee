# Admin Diagnostic MCP Surface — Design

Status: **proposed / design record**. This document captures the architecture
for a second, admin-scoped MCP service whose purpose is *operational
diagnosis* — letting an authorized agent inspect server health, telemetry, and
error reports to help diagnose bugs. It is deliberately **read-only** and
**never exposes student data**.

Decisions locked with the maintainer:

1. **Separate MCP service**, not more tools on the existing `/mcp` endpoint.
2. **Read-only.** Diagnosis only; "fixing bugs" happens through code changes and
   PRs, never through a live mutation surface.
3. **Design doc first** — this file. No code until it's reviewed.
4. **Auth: reuse the OAuth flow** (same as the content endpoint), gated on
   `isAdmin` — see §3.3.
5. **PII wall: code allowlist (revised — no new DB role).** The guarantee is
   hand-built DTOs that never include student identifiers, asserted by per-tool
   PII tests; `query_logs` reads an in-memory redacted ring buffer (no DB). A
   dedicated admin DB role was dropped as disproportionate (only one tool reads
   a PII-adjacent table). If DB-enforced hardening is ever wanted, extend the
   *existing* MCP least-privilege pool with PII-free views — no second role. See
   §4.

It builds on the shipped content-authoring MCP server (OAuth 2.1 bearer flow,
`ContentScope`, per-tool scope enforcement, course-scoping). Where this design
diverges from that server, the divergence is the point: the two surfaces have
*opposite* access models and must not share an enforcement path.

---

## 1. Motivation and the data-reality problem

The trigger is a recurring browser error the maintainer can see but can't easily
diagnose from the running deployment. More generally, the agent (running in a
remote container) can read the **code** but has no window into **production
telemetry** — runner health, job metrics, browser-error reports, server logs.
The admin MCP surface is that window.

Two facts from the codebase audit reshape the work:

- **The richest diagnostic sources are PII-laden.** `job_execution_metrics`,
  `client_diagnostics`, `audit_log`, and the structured stdout logs all carry
  `user_id` / `submission_id`. The clean sources (`runner_snapshots`,
  `WorkerActivityStore`, the `/admin/metrics` aggregates,
  `CompatibilityCounterStore`) carry none. So "no student data" is the
  load-bearing constraint, and it has to be enforced structurally, not by
  convention (see §4).

- **The browser-error pipeline captures almost no diagnosable signal today.**
  `client_diagnostics` stores only `kind` (`preflight_fail` /
  `watchdog_timeout`), `failedChecks` (symbolic names like `kernel-unhealthy`),
  and `user_agent`. There is **no error message, no stack trace, no console
  output**, and **no `window.onerror` / `unhandledrejection` capture at all**.
  Several failure modes (blank iframe, a kernel that never starts without
  printing "Kernel Unknown", silent package-load failures) never reach the
  server. A perfect tool reading this table would report *that* a cohort hit
  errors, never *why*.

The practical consequence: **the tools are necessary but not sufficient.** There
is a capture/enrichment track (§6) that has to land alongside (or just before)
the read tools, or the read tools have nothing useful to return. This is
especially true for the motivating browser error.

---

## 2. Why a separate service, not more tools on `/mcp`

The existing MCP server is built around one invariant, stated explicitly in
`Sources/APIServer/Helpers/CourseAccessHelpers.swift` and enforced in
`ToolContext.authorizeCourseAccess`:

> *Agent scope ⊆ human scope, enforced by course enrollment, with no admin
> bypass.* Every content tool calls `authorizeCourseAccess(courseID)` →
> `userIsEnrolled()`. Even an admin's agent stays enrollment-scoped.

Admin diagnostics are the **opposite** model: deployment-wide, not course-scoped.
They *deliberately violate* that invariant. That is exactly why they must not be
more entries in `MCPToolCatalog.live`:

- **Token-confusion isolation.** The bearer middleware
  (`MCPBearerAuthMiddleware`) authorizes by RFC 8707 audience (`claims.aud`
  must contain `expectedAudience`). Giving the admin surface a **distinct
  audience/resource** means a `content:*` token literally cannot call an admin
  tool — the audience check rejects it before any handler runs, and vice versa.
  One scope-clamping bug in one surface can't leak into the other.

- **Different scope vocabulary.** Content scopes (`content:read` /
  `content:write`) describe authoring authority. Admin diagnostics need
  `diagnostics:read` — a different meaning entirely. Mixing them in one
  `ContentScope` enum and one `MCP_MODE` ceiling muddies both.

- **Different consent/role gate.** Content consent requires `isInstructor`
  (`MCPOAuthRoutes`, multiple sites). Admin tools require `isAdmin`.

- **Different `instructions` and catalog.** The `initialize` handshake ships
  `MCPServerInstructions.text` describing the *content-authoring* domain. The
  admin surface needs its own instructions describing the *diagnostic* domain
  and the no-student-data guarantee.

- **Independent enablement.** A deployment should be able to run the instructor
  surface without the admin surface, and vice versa, via separate env flags.

The transport/JSON-RPC machinery, by contrast, is generic and worth reusing
(§3.4).

---

## 3. Architecture

### 3.1 Endpoint, mode, config

| Aspect | Content MCP | Admin MCP |
|--------|-------------|-----------|
| Endpoint | `POST /mcp` | `POST /admin-mcp` |
| Enable flag | `MCP_MODE` (`off`/`read_only`/`read_write`) | **same `MCP_MODE`** (all-or-nothing) |
| Resource / audience | `…/mcp` | `…/admin-mcp` (distinct) |
| Issuer | `PUBLIC_BASE_URL` | same issuer, different resource |
| Signing key / authority | `mcpTokenAuthority` | **shared** (separated by audience) |
| Config struct | `MCPConfig` | none — derived from `MCPConfig` |
| Catalog | `MCPToolCatalog.live` | `AdminMCPToolCatalog.live` |

**Tied to `MCP_MODE` (decided during build).** There are **no `ADMIN_MCP_*`
settings**. The admin surface mounts (read-only) exactly when MCP is mounted —
`read_only` *or* `read_write` — and is off when MCP is off. It reuses the content
surface's DNS-rebinding guards (`MCP_ALLOWED_HOSTS` / `MCP_ALLOWED_ORIGINS` /
`MCP_ALLOW_OPEN_GUARDS`), issuer, access-token TTL, and **signing key/authority**
(`mcpTokenAuthority`); separation between the two surfaces is by **token
audience** (`…/mcp` vs `…/admin-mcp`), not a separate key. The admin resource is
derived as `<origin>/admin-mcp`.

**Always read-only — even under `MCP_MODE=read_write`.** The admin surface only
ever advertises and honors `diagnostics:read` (`DiagnosticScope` has no write
case; `adminMCPAdvertisedScopes` is the single source). So `read_write` gives the
*content* surface read+write while the admin surface stays read-only.

**Path note:** the endpoint is `/admin-mcp`, **not** `/admin/mcp` — the latter is
already the admin *web page* that manages content-MCP service accounts and
connected agents (`AdminMCPRoutesTests`). A hyphenated top-level path avoids the
collision and keeps the bearer-gated transport out of the session-gated `/admin`
web group. The audience matches the path.

Note there is **no `read_write`** for the admin surface — read-only is a
hard property of the surface, not a mode toggle, so the enum can't even express
mutation.

### 3.2 Scopes and the read-only posture

A new, narrow scope vocabulary:

```swift
enum DiagnosticScope: String, CaseIterable, Sendable {
    case read = "diagnostics:read"
}
```

Read-only is enforced three ways, defense in depth:

1. The scope enum has no write case.
2. `AdminMCPMode` has no `read_write`; its `scopeCeiling` is `{.read}`.
3. Every admin tool is a pure read — no tool in `MCPToolCatalog.adminLive`
   performs a mutating Fluent query, asserted by a guard test analogous to the
   content-side template guards.

### 3.3 Authentication: reuse the OAuth flow (decided)

**Decision: the admin surface authenticates the same way the content endpoint
does** — the browser OAuth 2.1 + PKCE + DCR flow — with the consent gate raised
from `isInstructor` to `isAdmin`. One auth mechanism across both MCP surfaces
means one mental model, one set of discovery endpoints, per-grant revocation,
refresh-token rotation with theft detection, and per-client audit attribution —
all already built and hardened for the content surface.

What this decision implies (the work to do):

- **Two-resource consent.** `/oauth/authorize` branches the role gate on the
  requested resource (RFC 8707 `resource` / requested scopes): an authorization
  targeting `…/admin/mcp` requires `isAdmin`; one targeting `…/mcp` keeps the
  existing `isInstructor` check. The role is re-checked at consent submit and on
  every refresh, exactly as today (`MCPOAuthRoutes`).
- **Distinct audience.** Tokens for the admin resource carry `aud = …/admin/mcp`
  and the `diagnostics:read` scope; the admin bearer middleware enforces that
  audience, so a content token can't call admin tools and vice versa (§2).
- **Discovery.** A second `.well-known/oauth-protected-resource` describes the
  admin resource (the `MCPMetadataRoutes` pattern), advertising
  `diagnostics:read` under `ADMIN_MCP_MODE`.
- **DCR.** Dynamic client registration is shared; requested scopes are still
  clamped to each resource's advertised ceiling.

Recorded alternative (not chosen): admin-minted service tokens — a button on the
admin panel minting a `diagnostics:read` bearer via `MCPTokenAuthority`. Simpler
plumbing and no two-resource consent, but it diverges from "works like our other
endpoint" and offers only coarse, rotate-the-key revocation. Revisit only if a
headless/CI consumer makes the interactive consent flow impractical.

Every admin tool call is written to the `audit_log` (new `AuditAction` cases,
e.g. `admin.diagnostic_queried`, or reuse `mcpToolCalled` with
`targetType = "diagnostics"`), so admin diagnostic access is itself auditable.

### 3.4 Reuse vs. new

**Reuse as-is** (genuinely generic transport):

- `MCPDispatcher` JSON-RPC envelope handling (`initialize`, `tools/list`,
  `tools/call`, `ping`), if the dispatcher can be made scope-agnostic (see
  below).
- `MCPRoutes` transport with the Host/Origin DNS-rebinding guards.
- `MCPMetadataRoutes` pattern for a second `.well-known/oauth-protected-resource`
  describing the admin resource (required — §3.3 reuses the OAuth flow).
- `MCPOAuthRoutes` for the consent/token/refresh/DCR flow, extended with the
  two-resource role gate (`isAdmin` on the admin resource).
- `MCPTokenAuthority` for minting/verifying ES256 tokens (parameterized by
  audience).

**New / parallel** (the auth + scope + context layer, where the two surfaces
differ):

- `AdminMCPConfig`, `AdminMCPMode`, `DiagnosticScope`.
- An admin bearer middleware (or a generalized `MCPBearerAuthMiddleware`):
  today it hardcodes `ContentScope.allCases` and
  `appConfig.mcp.mode.scopeCeiling` (lines ~49–50). It must be parameterized
  over the scope set + ceiling + audience so a second instance serves the admin
  resource.
- An `AdminToolContext` analogous to `ToolContext` but with **no course
  authorization** — instead `requireAdminSubject(tool:)` confirming the token
  subject resolves to an `isAdmin` user. No `authorizeCourseAccess`.
- An admin tool protocol + registry. `ContentTool`/`ToolRegistry`/`AnyContentTool`
  are tied to `Set<ContentScope>` and `ToolContext`. Two options:
  - **(a) Generalize** the dispatcher/registry/tool protocol over an
    `MCPScope` protocol (`RawRepresentable<String> & CaseIterable & Sendable`)
    and a context type. Most reuse, but it touches the shipped content stack.
  - **(b) Parallel thin stack** (`DiagnosticTool`, `DiagnosticToolRegistry`,
    `AdminToolContext`) that shares only the dispatcher's JSON-RPC plumbing.
    More duplication, but zero risk to the shipped surface.

  Lean **(b)** for v1 (isolation over DRY while the content surface is in
  production), and revisit (a) as a later refactor if the duplication bites.
  The exact factoring is an implementation detail to settle in the build phase.

---

## 4. The student-data wall (PII boundary)

This is the part that must be right.

> **Decision (revised during build): code allowlist, no new DB role.** The
> sections below describe the *maximal* hybrid (DB views + a dedicated role).
> In practice that was disproportionate: only `get_browser_diagnostics` reads a
> PII-adjacent table (`client_diagnostics`); `query_logs` uses an in-memory
> redacted ring buffer, and the metrics/health tools return aggregates. So the
> shipped guarantee is the **code allowlist** (§4.3) — hand-built DTOs that omit
> student identifiers, asserted by per-tool PII tests (e.g. the seeded
> `user_id` must not appear anywhere in `get_browser_diagnostics` output). The
> DB-view layer below is retained as the design of record for *if* DB-enforced
> hardening is ever required — and even then it would **extend the existing MCP
> least-privilege pool**, not add a second role.

### 4.1 Principle (aspirational): redact at the database, not only in the DTO

The content MCP already demonstrates the strongest pattern: an optional dedicated
least-privilege DB pool (`MCP_DATABASE_USER` / `MCP_DATABASE_PASSWORD` →
`DatabaseID.mcp`, selected by `ToolContext.db`) so "no student data" is enforced
by the Postgres role, not only the in-process boundary
(`docs/compliance/` documents this for the IRA).

The admin surface should follow the same playbook, with a twist: it *needs* to
read diagnostic tables that contain student FKs, so the role can't simply be
denied those tables. Instead:

- Define **PII-free SQL views** over the diagnostic tables — e.g.
  `diag_browser_errors_v`, `diag_job_metrics_v`, `diag_runner_snapshots_v` —
  that project only non-PII columns (drop `user_id`, drop raw `submission_id` or
  replace it with a salted hash; keep `test_setup_id` since that maps to
  instructor content, timings, statuses, counts, `user_agent`, error text).
- Grant a dedicated `ADMIN_MCP_DATABASE_USER` role `SELECT` on **only those
  views** (and the already-clean `runner_snapshots`), nothing else.
- Admin tools read the views. The result: even a tool bug can't return
  `user_id` — the column isn't reachable through the role.

If the dedicated role isn't configured (dev), tools fall back to the shared pool
but build the *same* redacted DTOs in code (allowlist of fields, never a raw
model row). The DB views are the production guarantee; the DTO allowlist is the
floor.

### 4.2 PII classification of the candidate sources

| Source | PII today | Exposed via admin tool as |
|--------|-----------|---------------------------|
| `runner_snapshots` | none | as-is (clean) |
| `WorkerActivityStore` (in-mem) | none | as-is (clean) |
| `CompatibilityCounterStore` (in-mem) | none | as-is (clean) |
| `/admin/metrics` aggregates | none | as-is (clean) |
| `job_execution_metrics` | `user_id`, `submission_id` | **aggregates only** (status counts, percentiles, per-stage timing, cache-hit rate) — no row-level identifiers |
| `client_diagnostics` (+ §6 enrichment) | `user_id` | drop `user_id`; keep `kind`, `failedChecks`, error text, `user_agent`, `test_setup_id`, timestamps; optional salted-hash actor key for "same client, N hits" |
| structured logs (stdout) | `user_id`, `submission_id` | redacted ring buffer (§6): PII metadata keys dropped or hashed |
| `audit_log` | `actor_user_id`, `actor_username` | **excluded from v1** (actors can be students on login events); if surfaced later, aggregate counts by action only |
| submission contents / grades / enrollment | — | **never** — out of scope entirely |

### 4.3 Per-tool rule

Every admin tool returns a hand-built, allowlisted DTO. Code review checklist
item: *does this DTO contain any column that can identify a student?* If yes, the
tool is wrong. A unit test asserts the serialized output of each tool against a
seeded DB containing known student rows and fails if any student identifier
appears.

---

## 5. Proposed tool catalog (read-only)

All `diagnostics:read`. Names are provisional.

| Tool | Returns | PII posture |
|------|---------|-------------|
| `get_deployment_info` | Version/build, `ADMIN_MCP_MODE`, advertised scopes, uptime, redacted env summary (the startup-summary view), feature flags | clean |
| `get_runner_health` | Per-runner liveness from `runner_snapshots` + `WorkerActivityStore`: id, hostname, version, active/max jobs, capacity, last poll/heartbeat | clean |
| `get_queue_state` | Pending/assigned counts, oldest-pending age, stuck-submission count (the reaper's view) | aggregate, clean |
| `get_job_metrics_summary` | `job_execution_metrics` over a window: status counts, queue-wait/execution percentiles, per-stage timing breakdown, test-setup cache-hit rate, compatibility counters | aggregate, no row identifiers |
| `get_browser_diagnostics` | `client_diagnostics` (post-§6): counts by `kind`/`failedChecks`/`user_agent` over a window **plus recent redacted samples** incl. error message/stack | `user_id` dropped |
| `query_logs` | Recent structured log records from the in-process ring buffer (§6), filterable by event name / level / time window | PII metadata redacted |
| `get_health_alerts` | Current `ServerHealthAlertService` rule states (which are firing) + configured thresholds | clean |
| `get_metrics_card_series` | The time-series (sparkline) data behind the admin dashboard's five operational cards — per-bucket max queue depth, jobs processed, max load, p95 queue-wait, p95 execution — for every window (24h / 7d / 30d). The windowed series behind `get_metrics_snapshot` | aggregate, no row identifiers |
| `get_metrics_timeseries` | Flexible-window operational time-series (`metricsTimeSeriesSnapshot`): per-bucket runner utilization, **HTTP request count + P95 latency**, completed jobs, test status counts, queue-wait/execution P95. Arbitrary window/bucket | aggregate, no row identifiers |
| `get_active_users_series` | The admin dashboard's "Active Users" chart: distinct active users per bucket over a trailing window (`ActivityChartService`) | aggregate, distinct counts only |
| `get_instructor_card_series` | The instructor dashboard's four cards for one course (by `courseCode`): per-bucket submissions, active students, active assignments, browser errors (`instructorCardSeries`) | aggregate counts only; enrolled-student lookup is internal scoping, no identity reaches the output |
| `get_queue_state` | Current worker-queue state: pending depth (worker-eligible + total), in-flight, oldest-pending age, stuck-submission count (the reaper's view), recent-window peak depth | aggregate, clean |
| `list_runners` | The runner fleet (`makeWorkerRows`): id, hostname, version, load, jobs processed, rolling avg execution/queue-wait | clean |
| `get_runner_detail` | One runner's identity + capability profile + aggregate timing breakdown (avg execution/queue-wait/overhead/per-stage, cache-hit rate, status counts) + recent snapshots | aggregate only; the per-job rows the web page shows (username + submission id) are deliberately omitted |
| `get_storage_usage` | On-disk footprint (`AdminRoutes.makeStorageContext`): bytes by component + DB + per-assignment breakdown | assignment/course identifiers + byte/count aggregates; no student data |
| `get_request_metrics` | HTTP request-timing aggregates (`request_metrics`): total, status-class counts, overall duration summary, slowest routes by P95 | id-like path segments normalized to `:id`; no row-level identifier |
| `list_connected_agents` | MCP OAuth grants (`MCPAgentsRoutes.grantRows`, all-grants view): agent name, scopes, owner, authorized/last-used/expires/revoked | owner is the authorizing instructor/admin — never a student; no refresh-token secret |
| `get_brightspace_sync_status` | BrightSpace grade-sync health (`brightspace_sync_log`): counts by status + recent error samples (D2L error detail) | **student username + grade (points) hard-dropped**; status/detail/assignment/org-unit/timestamp only |
| `query_audit_log` | Audit-log activity as **counts only** by action + category over a window (`audit_log`) | counts only — no row, actor, IP, or metadata is ever returned (actors can be students), so the guarantee holds by construction |

A `get_deployment_info` / capability-probe tool mirrors the content surface's
`get_server_info` and lets the agent confirm the surface is live and what it can
see before doing anything.

---

## 6. Track 1 — enrich capture so the tools have signal

Read tools are only as good as the data. Two enrichment work-items, both of
which stand on their own merit (they improve the existing instructor browser-
error card and ops logging too).

### 6.1 Browser-error capture

Today `Public/notebook-preflight.js` / `notebook.js` POST only a `kind` +
`failedChecks` to `POST /api/v1/client-diagnostics`
(`ClientDiagnosticsRoutes.swift`). Enrichment:

- Add `window.onerror` and `window.addEventListener('unhandledrejection', …)`
  handlers on the **editor / notebook-load** path, plus a positive "kernel
  failed with this error" beacon in the watchdog's failure branch, so the
  silent failure modes (kernel never starts, blank iframe) actually report
  *something*.
- Extend the request body + `client_diagnostics` table with `message`
  (truncated ~1 KB) and `stack` (truncated ~4 KB), and an optional `phase` /
  `source` discriminator. New migration; keep the existing per-(user, setup,
  kind) rate limiter.
- **Care on the grading path.** Editor/kernel-boot errors are infrastructure
  (JupyterLite/Pyodide) and safe to capture verbatim. Errors thrown *during
  browser grading of a student submission* (`browser-runner.js`) can contain
  student code in the traceback — capture conservatively there (message class
  only, or omit) so we don't smuggle student content into a "no student data"
  table.

The payoff: `get_browser_diagnostics` can then show the actual error text behind
the motivating bug, not just a `watchdog_timeout` count.

### 6.2 Structured log access

Logs are stdout-only today (`OperationalDiagnostics` emits
`logger.info("observability", metadata:)`; no custom handler, nothing
queryable). Add a bounded **in-process ring buffer**:

- A `LogRingBuffer` actor holding the last N records (e.g. 2 000), fed by a
  custom `LogHandler` (or a multiplex alongside the console handler) that
  captures `observability` events plus `warning`/`error` level lines.
- Each record: timestamp, level, label, message, and **redacted** metadata —
  PII keys (`user_id`, `submission_id`, …) dropped or salted-hashed at capture
  time, so the buffer is born clean.
- `query_logs` reads it with event/level/time filters. Survives until restart
  (fine for live debugging).
- Durable alternative, recorded for later: a retention-bounded `server_logs`
  table (reaper like `AUDIT_LOG_RETENTION_DAYS`) if we want logs to persist
  across restarts. Start with the ring buffer.

---

## 7. Implementation sequencing

Each step is independently shippable and reviewable. Phase 2 (the surface
itself) is split into thin slices so the architecture can be reviewed before the
OAuth and DB-wall work lands.

1. **Capture (Track 1).** ✅ **Done** (PR #942). Browser-error enrichment (§6.1):
   `editor_error` kind + message/stack/source on `client_diagnostics`,
   `window.onerror`/`unhandledrejection` capture, kernel-failure evidence. The
   log ring buffer (§6.2) is deferred to land alongside `query_logs` (step 4).
2. **Scaffold the admin surface.** Split into:
   - **2a — dispatch-layer foundation.** ◀ **This slice.** `AdminMCPMode` /
     `DiagnosticScope` / `AdminMCPConfig` (+ `AppConfig` wiring + startup
     summary), `AdminToolContext` (`requireAdminSubject`), the `DiagnosticTool`
     protocol / registry, `AdminMCPDispatcher` (tools-only, read-only),
     `AdminMCPServerInstructions`, `AdminMCPToolCatalog`, and the first tool
     `get_deployment_info` — proven end to end at the dispatch layer with unit
     tests. **Nothing is mounted**, so there is zero production impact while the
     architecture is reviewed.
   - **2b — HTTP mount + bearer.** ✅ **Done.** Mounts `POST /admin-mcp` behind
     `ADMIN_MCP_MODE` with `AdminMCPBearerAuthMiddleware` enforcing the admin
     audience + `diagnostics:read` (separate signing key from the content
     surface), the admin `.well-known/oauth-protected-resource/admin-mcp`
     discovery, the production DNS-rebinding fail-safe, and admin tool-call
     audit (`admin_mcp.tool_called`). Tokens minted via `MCPTokenAuthority`
     (admin audience) for tests; production issuance is 2c.
   - **2c — two-resource OAuth consent.** ✅ **Done (OAuth part).**
     `MCPOAuthRoutes` is now resource-aware: the RFC 8707 `resource` parameter
     (or the requested scope's namespace) selects the surface, and the flow
     branches the scope ceiling, role gate (`isInstructor` for content,
     `isAdmin` for the admin resource — re-checked at consent submit and on
     every refresh), signing authority, audience, and TTL accordingly. No
     migration: the disjoint scope namespaces (`content:*` vs `diagnostics:*`)
     let every post-authorize step derive the surface from the stored scope.
     **Known limitation:** the shared `/oauth/*` authorization server is mounted
     by the content registration, so admin OAuth issuance currently requires
     `MCP_MODE` to also be on; an admin-only deployment can still use a
     directly-minted admin token. The PII-free DB views + least-privilege role
     are deferred to land with the PII-adjacent data tools (Phase 4).
3. **Clean-source tools.** ✅ **Done (first pass).** Shipped `get_metrics_snapshot`
   (the dashboard `InternalMetricsResponse` aggregate — runner loads, queue
   depth, job status counts, duration percentiles, compatibility counters) and
   `get_health_alerts` (live `evaluateHealthRules`), both admin-gated via
   `requireAdminSubject` and PII-free. These cover the originally-listed
   `get_runner_health` / `get_queue_state` / `get_job_metrics_summary` in one
   snapshot; finer-grained splits can follow if an agent wants them.
4. **`get_browser_diagnostics` + `query_logs`.**
   - `get_browser_diagnostics` ✅ **Done.** Reads `client_diagnostics` (the
     enriched browser-error reports from step 1): counts by kind/source/failed-
     check over a window + recent samples with the actual message/stack.
     Admin-gated; the returned DTO omits `user_id` (code-allowlist guarantee),
     asserted by a per-tool PII test. No DB role (§4 decision).
   - `query_logs` ✅ **Done.** Built as a **shared `AdminEventSink`** (bounded
     in-process ring buffer, per-process / until-restart) fed by a
     `RingBufferLogHandler` multiplexed alongside Vapor's real `ConsoleLogger`
     in the logging bootstrap — console output is unchanged. Captures warning+
     only, drops PII metadata keys at capture. `query_logs` is its first
     consumer (filter by level / substring / window); future event-driven admin
     queries reuse the same sink. Graduates to a retention-bounded table if
     durability / multi-instance history is ever needed.
5. **Dashboard sparkline series.** ✅ **Done.** The time-series data behind the
   instructor/admin dashboard sparklines, exposed verbatim from the same builders
   the dashboards poll: `get_metrics_card_series` (the five admin operational
   cards, `metricsCardSeries`), `get_active_users_series` (the "Active Users"
   chart, `ActivityChartService.chartData`), and `get_instructor_card_series`
   (one course's four cards, `instructorCardSeries`). `get_metrics_snapshot`
   gives the point-in-time numbers; these give the windowed series behind them.
   All admin-gated and PII-free: the operational/active-users series carry only
   per-bucket aggregates, and the instructor series is course-scoped by an
   explicit `courseCode` filter (not a session) but returns only per-bucket
   counts — the enrolled-student/setup lookup is internal scoping, no student
   identifier reaches the output, asserted by a per-tool PII test.
6. **Diagnostic-surface coverage round.** ✅ **Done.** Eight more tools so an
   agent has parity with the admin web dashboards' operational views, each
   reusing the same builder its page uses: `get_metrics_timeseries`
   (flexible-window series + HTTP request latency), `get_queue_state`,
   `list_runners` + `get_runner_detail` (capability profile + aggregate
   per-stage timing — never the per-job rows), `get_storage_usage`,
   `get_request_metrics` (id-like path segments normalized), `list_connected_agents`
   (MCP OAuth grants), `get_brightspace_sync_status` (grade-push health, student
   username + grade dropped), and `query_audit_log` (counts only — no actor / IP
   / metadata). The three identity/grade-adjacent sources (audit log, brightspace
   sync, per-job runner metrics) are realized as counts/aggregates/redacted DTOs
   so the no-student-data guarantee holds by construction; each is asserted by a
   per-tool PII test.

---

## 8. Risks and open questions

- **Scope-type refactor blast radius.** Generalizing `MCPBearerAuthMiddleware` /
  the dispatcher over a scope protocol touches shipped code. The parallel-stack
  option (§3.4b) avoids that at the cost of duplication. Settle this in phase 2.
- **Redaction completeness.** Stack traces and log messages are free text and
  can incidentally contain identifiers (a username in an error string). The
  ring buffer redacts *known* metadata keys but can't guarantee free-text is
  clean. Mitigation: capture from infrastructure paths (not student-code
  execution), truncate, and treat the DB-view wall as the real boundary for
  structured columns.
- **Two-resource OAuth consent.** §3.3 reuses the OAuth flow (decided), which
  means `/oauth/authorize` must branch its role gate on the requested resource.
  The main risk is getting that branch right so an admin-resource consent can
  never be satisfied by an instructor-only session; covered by tests that assert
  an `isInstructor`-but-not-`isAdmin` user is refused the admin resource.
- **Does the agent need anything beyond read?** Read-only is the decision. If a
  diagnosis routinely needs an action (e.g. "reap these stuck jobs"), that's a
  separate, explicitly-authorized proposal — not a quiet expansion of this
  surface.

## 9. Compliance and documentation touchpoints

A new MCP surface that reads diagnostic data must be reflected in the IRA
compliance record before it's enabled in production:

- `docs/compliance/tool-inventory.md` — add the admin tool catalog.
- `docs/compliance/data-flow-inventory.md` — the new read paths + the PII-free
  view layer.
- `docs/compliance/trust-boundary.md` — the second resource/audience and the
  admin-only access gate.
- `docs/compliance/policy46-classification.md` — confirm the surface stays clear
  of Policy 46 student data.
- `CLAUDE.md` "MCP server" design-decision section — note the second,
  admin-scoped, read-only surface and its separate audience/scope/mode.
- A `changelog.d/` fragment per the release process (no `VERSION` bump in-PR).
