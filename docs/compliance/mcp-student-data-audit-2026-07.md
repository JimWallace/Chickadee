# MCP Surfaces — Student-Data Access Audit (2026-07)

Prepared for the privacy / Information Steward review of Chickadee's two MCP
surfaces. The question under audit, as posed by the maintainer:

> Confirm that the MCP endpoints have absolutely no access, direct or inferred,
> to any student data.

- Repository: `JimWallace/Chickadee`, snapshot `VERSION` **0.4.667**
- Scope: the **content-authoring MCP surface** (`POST /mcp`, 51 tools) and the
  **admin diagnostic MCP surface** (`POST /admin-mcp`, 19 tools), the auth and
  data-access layers they depend on, and — new in this audit — the **upstream
  writers** that feed the diagnostic data sources those tools read.
- Method: every tool handler in `Sources/APIServer/MCP/Tools/` and
  `Sources/APIServer/MCP/Admin/Tools/` was read; every returned DTO was checked
  field-by-field; the auth/consent/token path was traced; the enforcement tests
  were reviewed; and the *writers* of the log/diagnostic stores the admin tools
  expose were swept for student identifiers entering as free text.
- Relationship to prior work: this supersedes the data-flow portions of
  `docs/compliance/ira-audit-report.md` (Phase 1, v0.4.435, 36 content tools,
  **admin surface not yet built**). Every P0/P1 remediation from
  `docs/compliance/remediation-plan.md` was re-verified against current code
  (§6). The admin diagnostic surface has never been through a compliance pass
  before this document — it is the main new ground covered here.

---

## Executive summary

**The architecture is sound and the guarantee is real for structured data.**
Both surfaces enforce "no student data" in depth: a source-scan-tested
in-process boundary, an optional database-role wall with row-level security,
disjoint OAuth audiences/scopes, per-course enrollment authorization, consent
gates that exclude students, and per-tool PII tests that seed student rows and
assert their identifiers never appear in serialized tool output. No MCP tool
returns a student identity, submission, grade row, or enrollment record, and no
non-MCP route accepts an MCP bearer token.

**The residual risk is free text.** Every finding in this audit is a case of a
student-linked value riding inside a *prose string* that the structured
defenses cannot see: log messages interpolating usernames/IPs/submission IDs
into the `query_logs` ring buffer, and the BrightSpace sync-error `detail`
embedding the pushed grade value and raw D2L response text. These are narrow,
concretely fixable, and two of the three are latent (BrightSpace sync is not
yet enabled in production). None is reachable by a student or instructor
token — every affected tool is behind the admin-only surface.

**Recommendation:** fix F-1 and F-2 (small, mechanical changes listed with each
finding) before submitting to the privacy team; the remaining findings are
hardening and documentation. With F-1/F-2 closed, the claim "no student data is
reachable through either MCP surface, directly or by inference" is accurate and
demonstrable from the repository.

| ID | Surface | Finding | Severity | Status today |
|----|---------|---------|----------|--------------|
| F-1 | Admin (`query_logs`) | Warning+ log **messages** can carry student usernames, institutional IDs, submission IDs, and client IPs; metadata redaction does not apply to message text | **Medium** | Live |
| F-2 | Admin (`get_brightspace_sync_status`, `get_health_alerts`) | Sync-error `detail` free text embeds the pushed **grade value** and raw D2L response body | **Medium** | Latent (BrightSpace sync not enabled in prod) |
| F-3 | Admin (`get_request_metrics`) | `pathPrefix` filters **raw** paths before ID normalization → existence oracle for concrete submission/setup IDs | Low | Live |
| F-4 | Admin (`get_browser_diagnostics`) | Samples return the full raw User-Agent; `message`/`stack` are client-supplied and only client-side-constrained | Low | Live |
| F-5 | Both | Small-cell aggregate inference (per-bucket distinct counts, count deltas across windows) | Low / accepted | Live |
| F-6 | Content | Wall guard test scans `MCP/Tools/` only and does not forbid `APIUser` / enrollment models (authz uses them legitimately) | Info / hardening | — |
| F-7 | Admin | Admin surface runs on the owner DB pool (by recorded design decision); guarantee is code-level DTOs + tests, not DB-enforced | Info / recorded | — |
| F-8 | Both | Compliance-record drift: `tool-inventory.md` says 36 content tools (now **51**); the 19 admin tools appear in no compliance doc; `CLAUDE.md` says 40 | Info / docs | — |
| F-9 | Deployment | Repo cannot prove prod env: `MCP_DATABASE_USER` (DB wall), `MCP_ALLOWED_HOSTS/ORIGINS`, `AUDIT_LOG_RETENTION_DAYS` need operator confirmation | Verify | — |

---

## 1. Threat model and what "student data" means here

The party outside the trust boundary is the **connecting agent** (e.g. the
Claude connector) and, transitively, its model provider. The humans who can
hold tokens are course staff and admins, who already see student data through
the session-authenticated web UI — that surface is out of scope. The guarantee
under audit is specifically: **nothing that crosses the MCP boundary to the
agent identifies a student or reveals a student's academic record**, so that
enabling an agent never widens where student data flows.

"Student data" is read broadly, per FIPPA/PIPEDA practice:

- **Direct identifiers** — username, email, student number / `orgDefinedId`,
  internal user UUID, D2L user ID.
- **Academic record** — submissions and their contents, per-test results,
  grades and grade overrides, achievement awards, extensions, participation.
- **Behavioural / technical PII** — login times attributable to a person,
  client IP addresses, device fingerprints.
- **Inferred access** — aggregates or oracles from which any of the above can
  be recovered (small cells, existence probes, free-text side channels).

Submission IDs and per-student personalization seeds are treated as
**pseudonymous student identifiers**: not identities by themselves, but stable
keys attributable to one student, so the bar applied is "do not emit them
either." The tools' own DTO designs already hold themselves to this bar
(e.g. `GetValidationResultTool` drops `submissionID`; `GetRunnerDetailTool`
omits per-job rows precisely because they carry username + submission id).

---

## 2. The two surfaces and how the guarantee is enforced

### 2.1 Content-authoring surface — `POST /mcp`, 51 tools

Catalog: `MCPToolCatalog.live`
(`Sources/APIServer/MCP/Transport/MCPServerRegistration.swift`). All tools are
typed `Input`/`Output` structs; there is no untyped escape hatch. Enforcement
is layered:

1. **In-process student-data boundary (unconditional).**
   `MCPStudentDataBoundary` (`Sources/APIServer/MCP/Tools/MCPStudentDataBoundary.swift`)
   is the *only* sanctioned access from the tool surface to `submissions` /
   `results`, and each accessor hard-filters `kind == .validation` — the
   instructor's own reference-solution runs. No tool accepts a raw submission
   ID. `MCPStudentDataWallTests` scans every file in `MCP/Tools/` and fails the
   build if any handler names `APISubmission`, `APIResult`,
   `APIGradeOverride`, `APIClientDiagnostic`, `JobExecutionMetric`,
   `APIClassAchievement`, `APIAchievementResult`, `APIUserActivityEvent`,
   `APIBrightSpaceSyncLog`, `APIPreEnrollment`, `APIAssignmentParticipation`,
   or `APIAssignmentExtension` outside the boundary file.

2. **Database-role wall (deployment option, defence in depth).** With
   `MCP_DATABASE_USER`/`MCP_DATABASE_PASSWORD` set, every content-tool query
   runs on a dedicated pool (`ToolContext.db` → `DatabaseID.mcp`) as the
   `chickadee_mcp` Postgres role (`deploy/sql/mcp-least-privilege-role.sql`):
   deny-by-omission on every student-data table (`grade_overrides`,
   `client_diagnostics`, `job_execution_metrics`,
   `assignment_personalization_seeds`, `achievement_results`, `audit_log`,
   `brightspace_sync_log`, …) and **row-level security** on
   `submissions`/`results`/`result_collections` restricting SELECT to
   `kind = 'validation'` rows. Even a future filter-omission bug returns zero
   student rows. `MCPLeastPrivilegeGrantSyncTests` keeps the SQL file in sync
   with the tables the boundary actually reads. Note the role *does* hold
   SELECT on `users` and `course_enrollments` — required for authorization —
   so non-exposure of identity rests on the code layer (see F-6).

3. **Per-course authorization, agent ⊆ human.** Every resource-accepting tool
   routes through `authorizeCourseAccess` / `authorizedAssignment*`
   (`ToolContext.swift`): the token subject must hold an enrollment row in the
   target course — **admins included** on the agent path. Writes additionally
   pass `evaluateCourseWrite` (per-course TA/instructor floor + archived
   block), the same policy core the web uses. `MCPAuthorizationCoverageTests`
   source-scans every tool file and fails the build if one omits the check.

4. **Students cannot appear on this surface at all.** Consent to authorize an
   agent requires staff-in-≥1-course (`MCPOAuthSurface.ResolvedSurface.permits`:
   `isStaffAnywhere`), re-checked at consent submit and on every refresh; and
   `ToolContext.requireEligibleSubject` re-refuses a plain-student subject on
   every call, so the guarantee does not rest on token issuance alone.

5. **Deliberate, bounded wall crossings.** Two side effects intentionally
   touch student rows and are explicitly routed to the privileged pool
   (`ToolContext.mainDB` / `request.db`), never the MCP pool, and return no
   row data to the agent:
   - the **content-edit auto-regrade** (`ContentEditClose.swift`,
     `retestSubmissionsAfterContentEdit`) — flips student submissions to
     pending after a suite edit; the agent sees only `submissionsRequeued`, an
     integer count;
   - the **acting account's own personalization-seed bookkeeping**
     (`update_global_inputs` / `update_section_variables` /
     `preview_personalization`) — ensures the *staff* account's seed only.
   `MCPSeedMainPoolTests` / `MCPDatabasePoolTests` pin the pool routing.

6. **Per-student personalization exposes no student.** Seeds are 32 CSPRNG
   bytes per (user, assignment) (`AssignmentSeedStore.generateSeedHex`) —
   *not* derived from identity, so a seed neither reveals nor is derivable
   from who a student is. The seeds table is denied to the MCP role and no
   tool returns another user's seed. `preview_personalization` evaluates an
   agent-supplied hex seed (or the acting account's own), so it previews a
   *hypothetical* student; it cannot enumerate or target real ones.

7. **Validation results only.** `get_validation_result` resolves the run from
   the assignment via the boundary (linked validation submission, else newest
   `kind == .validation` for the setup), and its DTO drops `submissionID` /
   `userID`. `get_notebook` returns the starter template (placeholders
   unresolved), never a student's substituted copy. `get_achievements` returns
   instructor-authored *definitions*; per-student awards live in
   `achievement_results`, which is wall-test-forbidden and DB-denied.

### 2.2 Admin diagnostic surface — `POST /admin-mcp`, 19 tools

Catalog: `AdminMCPToolCatalog.live`. Design record: `docs/admin-mcp.md`
(decision §4: **code-allowlist DTOs asserted by per-tool PII tests**, no
dedicated DB role for this surface — see F-7). Enforcement:

1. **Admin-only, twice.** Consent for the admin resource requires `isAdmin`
   (`MCPOAuthSurface`), and every DB-touching tool re-resolves the subject and
   re-checks `isAdmin` per call (`AdminToolContext.requireAdminSubject`) — an
   instructor or student with a somehow-obtained token is refused at the tool
   layer. The per-tool tests assert the instructor-subject refusal for each
   tool.

2. **Read-only by type construction.** `DiagnosticScope` has exactly one case,
   `diagnostics:read`; there is no write scope to grant, and the surface stays
   read-only under `MCP_MODE=read_write`.

3. **Token isolation between surfaces.** Disjoint RFC 8707 audiences
   (`…/mcp` vs `…/admin-mcp`) enforced by each bearer middleware; a content
   token cannot call admin tools and vice versa. No route outside the two MCP
   endpoints reads `bearerAuthorization` at all, so MCP tokens are inert
   against the web UI and REST API (and web sessions are inert against MCP —
   the bearer middlewares accept only bearer tokens).

4. **PII-laden sources are exposed as aggregates or hand-allowlisted DTOs.**
   The table below is the per-tool posture, verified against each handler:

| Tool | Source | What crosses to the agent | Student-data posture |
|------|--------|---------------------------|----------------------|
| `get_deployment_info` | static config | version, env name, modes, scopes | clean (DB-free) |
| `get_deploy_status` / `get_deploy_history` | deployer status/history files | versions, deploy events | clean |
| `get_metrics_snapshot` / `get_metrics_card_series` / `get_metrics_timeseries` | aggregate builders | counts, percentiles, utilization | aggregates only |
| `get_active_users_series` | `ActivityChartService` | distinct-user counts per bucket | counts only (F-5) |
| `get_instructor_card_series` | `instructorCardSeries` | per-bucket submission/active-student/assignment/browser-error counts for one course | counts only; enrolled-student lookup is internal scoping; PII test seeds a student and asserts absence (F-5) |
| `get_queue_state` | submissions table | pending/in-flight/stuck **counts**, oldest age | counts/ages only |
| `list_runners` / `get_runner_detail` | worker rows, `job_execution_metrics`, `runner_snapshots` | runner identity/capabilities; **aggregate** timing/status over recent jobs | per-job rows (username + submission id) deliberately omitted; PII test asserts user UUID, submission id, and the substring `username` absent |
| `get_storage_usage` | storage scan | bytes by component; per-assignment bytes + submission **count** | aggregates; assignment/course IDs are instructor content |
| `get_request_metrics` | `request_metrics` | status-class counts, latency summary, slowest routes with id segments → `:id` | normalized (but see F-3); table carries no user_id |
| `get_health_alerts` | rule evaluation | firing flags, summaries, threshold numbers | clean except BrightSpace `last_error` free text (F-2) |
| `get_browser_diagnostics` | `client_diagnostics` | counts by kind/source/check/browser/appVersion, funnels, recent samples (message/stack/UA) | `user_id` column omitted + PII-tested; free-text caveats (F-4) |
| `list_connected_agents` | `oauth` grants | agent name, scopes, **owner username**, timestamps, revoked | owners are staff/admins by consent gate — never students; no token material |
| `get_brightspace_sync_status` | `brightspace_sync_log` | status counts + recent **error** samples (detail, setup, title, org unit) | `username`/`points`/`user_id` columns deliberately omitted + PII-tested; `detail` free text re-imports the grade (F-2) |
| `query_audit_log` | `audit_log` | **counts only** by action/category | no row, actor, IP, or metadata ever loaded beyond the action column — strongest posture; chosen precisely because actors can be students |
| `query_logs` | in-process ring buffer | warning+ log events: level, label, **message**, redacted metadata | metadata PII keys dropped at capture; message free text is the gap (F-1) |

5. **Admin tool calls are themselves audited** — one `admin_mcp.tool_called`
   row per call with tool name + outcome (`AdminMCPDispatcher`), so use of the
   diagnostic surface is reviewable after the fact.

### 2.3 Token and transport properties common to both

- ES256 JWTs minted by `MCPTokenAuthority`; browser-flow access tokens default
  **600 s** (`MCPConfig.accessTokenTTLSeconds`), so grant revocation and role
  loss take effect within minutes; scopes are re-clamped to the `MCP_MODE`
  ceiling **per request**.
- Refresh tokens rotate with prior-hash reuse (theft) detection; codes and
  consent tokens are single-use via atomic conditional UPDATE.
- Production refuses to mount either MCP transport with open Host/Origin
  guards unless explicitly overridden
  (`mcpTransportGuardRefusal`, reused by `registerAdminMCPRoutes`).
- Tool *arguments* are never written to the audit log or logs; audit rows for
  content writes are persisted **fail-closed** before the write and stamped
  with the outcome after (`MCPDispatcher`, `MCPAuditFailClosedTests`,
  `MCPAuditTargetOutcomeTests`).

---

## 3. Findings

Severity reflects exposure *through the MCP surfaces to the agent*; every
affected tool is admin-consent-gated, which is why nothing here rates High.

### F-1 (Medium) — `query_logs` free text can carry student identifiers

The ring buffer (`RingBufferLogHandler`) captures **every** warning+ log event
process-wide and drops known PII **metadata keys** at capture. Message strings
are stored verbatim, and several warning+ call sites interpolate
student-linked values into the message:

| Call site | What enters the buffer |
|-----------|------------------------|
| `Routes/Web/AuthRoutes.swift:102` | `Login locked for user '<username>' …` — lockout subjects are typically **students** |
| `Routes/Web/EnrollCSVHelper.swift:306,313,320` | `… failed to enroll <username> in <courseID>…` — roster usernames |
| `Services/BrightSpaceGradeSyncService.swift:95-96` | `… failure for row(s) <ids>: <error>` — result-row IDs, and the error can be `userNotFound(orgDefinedId:)` → **institutional student ID** in text |
| `Services/BrightSpaceSyncSweep.swift:378` | `BrightSpace grade push 404 for user <UUID> …` — internal user UUID |
| `Middleware/LoginRateLimitMiddleware.swift:94`, `MCP/Transport/MCPOAuthRateLimitMiddleware.swift:31` | `… rate limit exceeded for IP <ip>` — client IPs |
| `Routes/ResultRoutes.swift:56`, `Routes/BrowserResultRoutes.swift:65`, `Services/StuckSubmissionReaperService.swift:52` | `… submission=<submissionID>` — pseudonymous submission IDs |

The tool's self-description ("student identifiers are dropped at capture")
overclaims relative to message text; the design record (`docs/admin-mcp.md`
§8) flagged exactly this residual.

**Remediation (mechanical):**
1. At each site above, move the identifier out of the message and into
   structured metadata (`logger.warning("Login locked", metadata:
   ["username": …])`). Console/ops logging keeps full fidelity — the ring
   buffer's `redact` already drops those keys, so the fix is
   capture-side-complete without touching the handler.
2. Add the missing keys to `RingBufferLogHandler.piiKeys` (`ip`, `remote_ip`,
   `org_defined_id`, `user`) while doing so.
3. Add a guard test in the spirit of the existing source scans: grep warning+
   call sites for `\(username`-style interpolations of known identifier
   variables, or at minimum pin the six sites above.
4. Re-word the `query_logs` description to claim exactly what is true
   ("metadata PII keys dropped; messages are infrastructure text, kept clean
   by convention and test").

### F-2 (Medium, latent) — BrightSpace error `detail` embeds the grade and raw D2L body

`BrightSpaceSyncSweep.swift:331-334` writes, on a failed push:

```
"Pushed <points> pts to '<item>' (max …); D2L rejected it: <error.localizedDescription>"
```

- `<points>` is the student's **grade** — the very column the tool
  deliberately omits (`GetBrightSpaceSyncStatusTool` drops `points`), re-imported
  via prose. The row is (student, assignment)-scoped; no identity accompanies
  it through this surface, but "a grade value + assignment + timestamp" is
  more than the DTO design intends to emit, and identity linkage via external
  knowledge (e.g. LEARN-side logs) cannot be excluded.
- `error.localizedDescription` for `gradePushFailed` includes the **raw D2L
  response body** (`BrightSpaceAPIClient.swift`, `case .gradePushFailed(status:,
  body:)`), whose contents are D2L's to choose and can echo user-specific
  detail. `userLookupFailed`/`userNotFound` variants embed `orgDefinedId`.

The same string is re-surfaced by `get_health_alerts` as the
`brightspace_sync_failing` rule's `last_error` detail
(`ServerHealthAlertService.swift:392-393`), so it crosses on two tools.

The existing PII test seeds `username`/`points` **columns** and passes because
the leak is in the `detail` string, which the test's seeded rows left benign.

**Status:** latent — BrightSpace sync awaits production credentials
(`docs/brightspace-setup.md`), so no real student grade has crossed yet.

**Remediation:** build `detail` without the points value ("Grade push to
'<item>' rejected: HTTP <status>" + an error *class*); truncate/classify the
D2L body rather than embedding it; keep `orgDefinedId` out of
`BrightSpaceSyncError.description` (carry it in a non-described field for the
web UI if needed). Strengthen the PII test to seed a `detail` containing a
sentinel points value and orgDefinedId and assert absence. Close this before
BrightSpace sync is enabled in production.

### F-3 (Low) — `get_request_metrics` `pathPrefix` is an existence oracle for concrete IDs

`GetRequestMetricsTool` normalizes id-like path segments to `:id` **for
output**, but the `pathPrefix` input filters **raw stored paths**
(`query.filter(\.$path ~~ prefix)` then `hasPrefix`) before normalization. An
agent can therefore probe `pathPrefix: "/submissions/sub_ab12cd34"` and learn
from `total > 0` whether that concrete submission ID was active in a window —
confirming existence/timing of a specific pseudonymous identifier the output
layer is designed to withhold. Submission IDs are random enough that blind
guessing is impractical; the oracle matters when an ID is already known from
elsewhere, which is exactly the linkage scenario the normalization exists to
prevent.

**Remediation:** apply `normalizePath` *before* the prefix comparison (filter
on normalized routes), or reject prefixes containing id-shaped segments using
the existing `isIdentifierSegment`.

### F-4 (Low) — `get_browser_diagnostics` raw User-Agent in samples; client-supplied free text

- Each returned sample includes the **full raw UA string** (up to 512 chars).
  The tool already computes a coarse, deliberately PII-safe `byBrowser` label
  ("Safari/iOS") for exactly this reason; the raw UA in samples reintroduces a
  device-fingerprint-adjacent value that, combined with small cohorts, weakens
  the aggregate posture. **Remediation:** return `browserLabel(forUserAgent:)`
  in samples too (keep raw UA out), or truncate to product tokens.
- `message`/`stack` are stored verbatim (1 KB / 4 KB caps) from an
  authenticated client POST (`ClientDiagnosticsRoutes`). The
  "infrastructure text only, never student code" property is real but
  **enforced only by our client JS**: capture is wired to editor-load,
  kernel-boot, and pipeline paths; student Python exceptions become
  `TestOutcome`s rather than thrown JS errors, and the submit-flow breadcrumb
  sends only `elapsed_ms` + ≤200 chars of pipeline error
  (`Public/browser-runner.js`, `recordSubmitPhase`). A hostile or buggy client
  can still post arbitrary text into a row an admin agent will later read.
  Residual, not a defect; record it as a known property (the server cannot
  distinguish infrastructure text from other text) and keep the caps.

### F-5 (Low, accepted) — small-cell aggregates and window differencing

Counts-only tools can support inference at small n: a course with one enrolled
student makes `get_instructor_card_series`' per-bucket "active students"
series that student's activity timeline; `query_audit_log` with 1-hour windows
localizes *when* (never who) auth events occurred; `submissionsRequeued` (a
content-tool side-effect count) reveals how many students have submissions on
an assignment. None of these yields an identity through the MCP surfaces
themselves (no roster is exposed anywhere to join against); the linkage
requires out-of-band knowledge that course staff already hold with full
fidelity via the web UI. Recommend recording this as an accepted residual in
the submission; optionally floor distinct-count buckets (suppress 1–2) if the
Steward asks for k-anonymity on principle.

### F-6 (Info / hardening) — wall-test scan scope and the identity models

`MCPStudentDataWallTests` scans `Sources/APIServer/MCP/Tools/` only, and its
forbidden-model list excludes `APIUser` / `APICourseEnrollment` because the
authorization layer (in-scope `ToolContext.swift`) must query them. Verified
today: no tool file touches `APIUser` outside `ToolContext`/`UpdateSolutionTool`
(both resolve the *acting* subject only), and `Transport/` / `Resources/`
(outside the scan) touch only courses/assignments and the acting subject. But
a future tool that queried `APIUser` or listed enrollments would not trip the
wall test, and the DB role cannot catch it (`users`/`course_enrollments` are
SELECT-granted for authz). **Remediation:** extend the scan to `Transport/` +
`Resources/`, and forbid `APIUser`/`APICourseEnrollment`/`userIsEnrolled`
outside an explicit allowlist (`ToolContext.swift`, `UpdateSolutionTool.swift`,
`MCPCourseGuidance.swift`).

### F-7 (Info / recorded decision) — admin surface has no DB-level wall

`AdminToolContext.db` is the shared owner pool; the admin surface's guarantee
is the hand-built DTO allowlist + per-tool PII tests, per the revised decision
in `docs/admin-mcp.md` §4 ("code allowlist, no new DB role"). This is a
defensible, documented posture — the tests are genuinely strong (seeded
student rows, serialized-output assertions, per-tool instructor-refusal
tests) — but the privacy submission should state plainly that for this surface
the enforcement is application-layer. If the Steward requires DB-enforced
hardening later, the design of record is PII-free SQL views granted to the
*existing* `chickadee_mcp` role (admin-mcp.md §4.1), not a second role.

### F-8 (Info / docs) — compliance record drift

`docs/compliance/tool-inventory.md` and `data-flow-inventory.md` describe 36
content tools (v0.4.435); the catalog is now **51**, and the **19 admin tools
appear in no compliance document** — `docs/admin-mcp.md` §9 itself requires
the compliance record be updated before the admin surface is enabled in
production. `CLAUDE.md`'s prose says 40. This document provides the current
census (§2); the companion inventories should be refreshed or superseded
before submission, and the P2-3 checklist item ("re-run the census when a tool
is added") extended to cover `AdminMCPToolCatalog.live`.

### F-9 (Verify at deployment) — properties the repo cannot prove

For the submission, the operator should attest the production environment:

1. `MCP_DATABASE_USER=chickadee_mcp` is set and
   `deploy/sql/mcp-least-privilege-role.sql` has been applied (turns the
   content-surface DB wall on; `docker-compose.yml` does not set it by
   default — only the `.env.example` templates carry it, commented out).
   Verification queries are at the bottom of the SQL file.
2. `MCP_ALLOWED_HOSTS` / `MCP_ALLOWED_ORIGINS` are set (production refuses to
   mount otherwise unless `MCP_ALLOW_OPEN_GUARDS=true` — confirm it is not).
3. `AUDIT_LOG_RETENTION_DAYS` matches the retention the submission states
   (default 90).
4. The deployment-layer egress allowlist (`deploy/egress-allowlist.md`) is
   applied; Chickadee itself calls no model API (re-verified: no model-provider
   client or key exists in `Sources/` or `Package.swift`).

---

## 4. Inference-channel review (the "indirect access" question)

Checked explicitly, beyond the per-tool DTO review:

- **Join keys.** No tool emits usernames, user UUIDs, emails, student numbers,
  submission IDs, or seeds (findings F-1/F-2 free-text paths aside). Without a
  key, cross-tool joins reduce to timestamp correlation over aggregates (F-5).
- **Existence oracles.** Tool inputs that filter server-side were reviewed for
  probe value: `get_browser_diagnostics testSetupID` and
  `get_instructor_card_series courseCode` filter instructor-content
  identifiers (in scope for an admin); `get_request_metrics pathPrefix` is the
  one that probes below the output layer's abstraction (F-3).
- **Error-message side channels.** Content-tool errors return
  argument-derived, instructor-content detail ("No assignment found with
  public ID…"); none was found that reflects student-row state. The
  `executionFailed` wrapper in `get_validation_result` stringifies DB errors —
  under the least-privilege role those are permission-denied texts, not row
  data.
- **Personalization.** Seeds are CSPRNG (not identity-derived), unreachable
  through both walls; previews are by-seed, not by-student; per-student
  expression *results* delivered to grading (`_ck_inputs`) never transit MCP.
- **Free text.** The systemic pattern behind F-1/F-2/F-4: prose fields
  (`message`, `stack`, `detail`, interpolated log strings) are where
  structured defenses end. The remediations above close the two live/latent
  importers; the durable control is the write-side convention "identifiers go
  in metadata, never in message/detail prose" plus the guard tests.

---

## 5. What an agent can see, in plain terms

Worth stating for the submission, because it is the intuition the architecture
delivers:

- A **content agent** (staff-authorized) sees and edits instructor-authored
  course content — assignments, suites, scripts, notebooks, solutions,
  achievements *definitions*, personalization *specs* — plus the instructor's
  own validation-run outcomes. It cannot name a student, list an enrollment,
  see a submission or grade, or learn a seed. Its reach is clamped to the
  courses its human is enrolled in, per request.
- An **admin diagnostic agent** sees operational health: versions, deploys,
  runner fleet, queue depth, metrics series, browser-error breakdowns,
  grade-sync *health*, audit-log *counts*, and warning+ *log lines*. The log
  lines are the one place today where a student-linked string can transit
  (F-1) — everything else is counts, aggregates, or hand-allowlisted
  infrastructure fields, each pinned by a test that seeds a student and
  asserts their identifiers never serialize.

---

## 6. Re-verification of the prior audit's remediations (v0.4.435 → v0.4.667)

| Item | Claim in `remediation-plan.md` | Verified now |
|------|-------------------------------|--------------|
| P0-1 | Boundary chokepoint + wall test; optional least-privilege pool + RLS | ✅ `MCPStudentDataBoundary` + `MCPStudentDataWallTests`; `deploy/sql/mcp-least-privilege-role.sql` + `MCPDatabasePoolTests` + `MCPLeastPrivilegeGrantSyncTests`; regrade + seed bookkeeping routed to owner pool (`ContentEditClose.swift`, `ToolContext.mainDB`) |
| P0-2 | Authorization coverage guard | ✅ `MCPAuthorizationCoverageTests` (source scan, all tool files, explicit unscoped allowlist = `GetServerInfoTool` only) |
| P0-3 | Signing key git-ignored + rotation documented | ✅ `.mcp-signing-key` ignored; `deploy/README.md` |
| P1-1 | Audit outcome + target | ✅ `MCPDispatcher` records target + stamps outcome post-invoke; `MCPAuditTargetOutcomeTests` |
| P1-2 | Fail-closed audit for writes | ✅ write tools persist the row pre-invoke and fail closed; reads best-effort; `MCPAuditFailClosedTests` |
| P1-3 | Solution egress confined | ✅ wall test's `loadExistingSolution` scan restricts the answer key to `get_solution` |
| P2-2 | Prod transport-guard refusal | ✅ `mcpTransportGuardRefusal`, reused by the admin mount |

The admin surface additionally implements the design record's commitments:
counts-only audit log, aggregates-only job metrics, allowlisted browser/BS
DTOs, redacted ring buffer, per-tool PII + role-refusal tests, and
`admin_mcp.tool_called` auditing.

---

## 7. Recommended order of work before submission

1. **F-1** — move identifiers to metadata at the six named call sites, extend
   `piiKeys`, add the guard test, fix the `query_logs` description. (Small,
   self-contained; closes the only live Medium.)
2. **F-2** — sanitize the BrightSpace `detail` writer + error descriptions,
   strengthen the PII test. (Must land before BrightSpace sync is enabled;
   cheap now, awkward after.)
3. **F-3 / F-4** — normalize-before-filter; sample-level `browserLabel`
   instead of raw UA. (Each is a few lines.)
4. **F-6** — widen the wall test's scan + forbid identity models outside the
   authz allowlist. (Keeps the architectural guarantee ahead of future tools.)
5. **F-8** — refresh/supersede the compliance inventories with the current
   70-tool census; state F-7's application-layer posture explicitly.
6. **F-9** — operator attestation of the production env properties.

With 1–2 done and 5–6 written up, the submission can truthfully state: *no MCP
tool returns student identity, submissions, results, grades, enrollment, or
seeds; the two student-data tables the content surface can reach are
validation-filtered in code, by test, and (when configured) by database RLS;
the admin surface exposes aggregates and allowlisted infrastructure fields
pinned by tests that seed student data and assert its absence; and the known
free-text importers have been closed.*
