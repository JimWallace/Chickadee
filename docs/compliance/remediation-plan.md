# MCP Pre-Approval Remediation Plan

Prioritised remediation for the findings in `ira-audit-report.md`. **P0** =
student-data wall / authz / secrets; **P1** = audit logging / payload
minimisation; **P2** = docs & polish. Each item states the concrete change and
its acceptance criteria.

## Implementation status (this branch)

The in-repo items have been implemented; the split items await an
infrastructure or policy decision (noted per item).

| Item | Status | Notes |
|------|--------|-------|
| P0-1 | **Done** (option 1) | `MCPStudentDataBoundary` chokepoint + wall guard test. Option 2 (DB role) deferred — needs DB provisioning. |
| P0-2 | **Done** | `MCPAuthorizationCoverageTests` source-scan guard. |
| P0-3 | **Done** | `.mcp-signing-key` git-ignored; rotation documented in `deploy/README.md`. |
| P1-1 | **Done** | Audit records outcome + target resource; arguments still never logged. |
| P1-2 | **In progress** | Policy chosen: write tools fail closed if their audit row can't persist; reads degrade best-effort with an error marker. |
| P1-3 | **Done** | Solution-resolver guard test (answer key read only via `get_solution`). |
| P2-1 | **Done** (artifact) | `deploy/egress-allowlist.md` documents the Squid / nftables / NetworkPolicy options; operator applies it. |
| P2-2 | **Done** | Production refuses to mount `/mcp` with open Host/Origin guards unless `MCP_ALLOW_OPEN_GUARDS=true`. |
| P2-3 | **Done** | Compliance docs cross-linked; tool count corrected to 36. |

Status legend: the **current state** of each control is in `ira-audit-report.md`.
Items marked *(verify-only)* found no defect — the work is to add a test/doc
that *proves* the property so a reviewer doesn't have to take it on faith.

---

## P0 — Student-data wall, authorization, secrets

### P0-1 — Make the student-data wall architectural, not conventional
**Finding:** AUDIT-3 (Gap). MCP tools run on `request.db` (`ToolContext.swift:35`),
the same full-privilege connection as the rest of the app. "Cannot read student
submissions/grades" holds only because each handler chooses safe models and
filters `kind == .validation`. It is not demonstrable from configuration.

**Change (pick one; recommended first):**
1. **Repository boundary (recommended, in-process).** Introduce a narrow
   `AuthoringStore` protocol that exposes *only* the authoring + authz models
   (`APICourse`, `APICourseEnrollment` read-only, `APICourseSection`,
   `APIAssignment`, `APITestSetup`, and a `validationSubmission(for:)` accessor
   that hard-codes the `kind == .validation` filter). Give `ToolContext` an
   `AuthoringStore` instead of a raw `Database`. Tool handlers can then no
   longer name `APISubmission`/`APIResult`/`APIUser`(PII)/grade models at all —
   the wall becomes a compile-time fact.
2. **Least-privilege DB role (defence in depth, deployment).** A dedicated
   Postgres role for the MCP path with `SELECT` on authoring/enrolment tables
   and *no* `SELECT` on `submissions` (except a view filtered to
   `kind='validation'`), `results`, `grade_overrides`, `client_diagnostics`,
   etc. Requires a second connection/pool selected when serving `/mcp`.

**Acceptance criteria:**
- A new test attempts to read a student (`kind != .validation`) submission and a
  grade row through the MCP `ToolContext`/store and **fails to compile** (option 1)
  or **is denied by the DB** (option 2).
- The `submissions`/`results` access that *does* remain (validation runs,
  reference solution) routes through a single named accessor with the
  `kind == .validation` filter baked in; grep shows no `.filter(\.$kind ==` in
  individual tool handlers.
- `swift build` + `swift test` green.

### P0-2 — Lock in per-resource ownership coverage *(verify-only)*
**Finding:** AUDIT-4b (Pass). Every resource-accepting handler already routes
through `authorizeCourseAccess` / `authorizedAssignment*`
(`ToolContext.swift:67-115`), confirmed across all 36 tools. The risk is
**regression**: a future tool could forget the check.

**Change:** add a guard test that, for every tool in `MCPToolCatalog.live`,
asserts a call with a resource ID the subject is *not* enrolled in returns
`notAuthorized`. Drive it off the registry so a newly-added tool is covered
automatically (or fails the test until it authorizes).

**Acceptance criteria:** the test enumerates `MCPToolCatalog.live` and fails if
any resource-accepting tool returns a non-`notAuthorized` result for a
non-enrolled course. Green on the current tree.

### P0-3 — Secrets: confirm clean, document rotation *(verify-only)*
**Finding:** AUDIT-6 (Pass). No hard-coded secrets; all from env; redacted in
the startup summary with a CI grep guard; `.env*` examples carry placeholders
only; no model-provider API key exists. The MCP ES256 signing key is
auto-generated at `MCP_SIGNING_KEY_PATH`, mode 0600 (`MCPTokenAuthority.swift:47-59`).

**Change:** none to code. Add an operator note to `deploy/README.md` covering
signing-key rotation (delete file → restart mints a new key → in-flight tokens
fail closed) and confirm `.mcp-signing-key` is in `.gitignore`.

**Acceptance criteria:** rotation steps documented; `.gitignore` check confirmed;
no secret value ever printed in this work.

---

## P1 — Audit logging & payload minimisation

### P1-1 — Record tool-call outcome and target resource
**Finding:** AUDIT-4d (Gap). `mcp.tool_called` is written **before**
`tool.invoke` (`MCPDispatcher.swift:208`) and carries only `{tool, via_agent}`.
The audit therefore cannot show whether the call **succeeded or failed**, nor
**which assignment/course** it acted on (`AuditLogger.record` already supports
`targetType`/`targetID`, but the MCP path passes neither).

**Change:** in `MCPDispatcher.toolsCallResult`, capture the outcome
(success / tool-error / internal-error) and write the audit record *after*
invocation with `targetType`/`targetID` set to the assignment public ID or
course code from the decoded arguments, plus an `outcome` metadata field. Keep
arguments themselves out of the log (only the resource identifier — which is
authoring metadata, not sensitive content — and the outcome). Mirror the same
in the streaming `validate_assignment` path (`MCPRoutes.swift:273`).

**Acceptance criteria:**
- A passing and a failing tool call each produce exactly one `mcp.tool_called`
  row; the row records `outcome` and the target resource id.
- No tool argument *values* (script bodies, notebook content, solution text)
  appear in any audit row — asserted by a test.
- `swift test` green.

### P1-2 — Guarantee an audit record exists (or fail closed)
**Finding:** AUDIT-4d (Risk). `AuditLogger.record` swallows DB-write failures by
design (`AuditLogger.swift:49-55`), so a tool can in principle execute without a
persisted audit row. Acceptable for most web actions; weaker than "every tool
call is audited."

**Change:** decide policy with the Steward. Minimal option: on an MCP audit
write failure, emit a structured `logger.error` with a stable
`mcp_audit_write_failed` marker (so the external log sink still captures the
attempt) — keep the action proceeding. Strict option (if required): for write
tools, fail the call closed when the pre-write audit row cannot be persisted.

**Acceptance criteria:** chosen policy implemented and documented; a test
simulates an audit-write failure and asserts the chosen behaviour.

### P1-3 — Payload minimisation for the reference solution
**Finding:** AUDIT-2 (Risk). The reference solution (Restricted, item 1 in
`policy46-classification.md`) leaves the boundary via `get_solution`,
`update_solution`, and `preview_personalization`. Other tools do not need it
and don't send it (already minimal). The lever is keeping the most sensitive
artifact out of payloads where it isn't strictly needed.

**Change:** confirm (and test) that no metadata/structural tool returns
solution bytes; document that `MCP_MODE=read_only` plus omitting `get_solution`
from a deployment's exposed set removes answer-key egress entirely for courses
that classify it Highly Restricted. (Selective per-tool exposure is a small
addition to `MCPToolCatalog` if the Steward requires it.)

**Acceptance criteria:** a test asserts only the three named tools can emit
solution content; the deployment knob is documented.

---

## P2 — Documentation & polish

### P2-1 — Network egress allowlist at the deployment layer
**Finding:** AUDIT-5 (Gap, deployment). No app-level egress allowlist; only the
optional `OUTBOUND_HTTP_PROXY` forward proxy. The server's *only* outbound
destinations are the OIDC IdP (DUO), BrightSpace (D2L), the UW calendar feed,
and an optional alert webhook — **none is a model API**.

**Change:** add a deployment-layer egress allowlist (Squid allowlist or
container/host firewall / NetworkPolicy) limited to those destinations, and
document it under `deploy/`. Note explicitly that no model-API destination is
required from Chickadee.

**Acceptance criteria:** `deploy/` documents the allowlisted hosts; the audit
report's §5 references the concrete artifact.

### P2-2 — Production transport guards on by default
**Finding:** AUDIT-4a (Risk). `MCP_ALLOWED_HOSTS` / `MCP_ALLOWED_ORIGINS`
default to empty ("allow any"); a startup warning fires in production when unset
(`MCPServerRegistration.swift:181-192`) but does not block.

**Change:** set both in the production env template and document them; optionally
upgrade the production-unset case from a warning to a refusal to mount `/mcp`.

**Acceptance criteria:** production deploy template sets both; documented in
`deploy/`.

### P2-3 — Keep the compliance docs current
**Change:** wire a note into `docs/mcp-authoring-roadmap.md` pointing at
`docs/compliance/`, and add a checklist item to re-run the tool census when a
tool is added to `MCPToolCatalog.live` (the count is 36 today; the prose digest
in `CLAUDE.md` lagging at "34" is the kind of drift to avoid).

**Acceptance criteria:** cross-links exist; tool count in `tool-inventory.md`
matches `MCPToolCatalog.live`.
