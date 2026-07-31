# UW AI-Tool Approval — Readiness Plan for the Chickadee MCP Surfaces

Companion to `mcp-student-data-audit-2026-07.md`. Maps the University of
Waterloo approval process for AI tools using University data
([IST: Responsible use of AI tools — approval support](https://uwaterloo.ca/information-systems-technology/about/policies-standards-and-guidelines/responsible-use-ai-tools-university-data/approval-support))
onto Chickadee's current state: what each step will ask, which repo artifact
answers it, and the gaps to close before intake.

UW's pathway, as published: **(1)** initiation and scoping with early
Information Steward engagement, **(2)** Information Risk Assessment + Privacy
Impact Assessment (intake to IST Information Security Services and Legal &
Immigration Services; a PIA is mandatory when personal information is
involved), **(3)** contracting and procurement, **(4)** approval and
onboarding (limited-use cases get unit-level approval), **(5)** ongoing
review/revalidation (five-year cycle, contract renewal, or major
vendor/feature/data-handling change). Tools are classified **Approved**
(contract + IRA/PIA; suitable for Confidential/Restricted data), **Reviewed
for Limited Use** (IRA/PIA, no contract; publicly-sourced data only),
**Unreviewed**, or **Problematic**.

---

## 0. The framing decision (settle this first)

Get agreement with the Steward/IST up front on **what is being reviewed**:

- **Chickadee is not the AI tool.** It is the UW-hosted system of record. It
  calls no model API — there is no model-provider client, key, or SDK in the
  codebase (re-verified in the 2026-07 audit; original finding in
  `ira-audit-report.md` §Executive summary). Chickadee's role in the review is
  to **bound what any connected AI tool can access**, which is exactly what
  the student-data audit demonstrates.
- **The AI tool under the framework is the connecting agent** — the Claude
  connector (or any MCP client) and, transitively, its model provider. The
  vendor-side properties the process evaluates (retention, no-training, data
  residency, contract terms) attach to *that* tool, through procurement — not
  to Chickadee code.
- **The data that reaches the AI tool is precisely the MCP tool payloads.**
  This is the whole point of the architecture: the review does not need to
  reason about "an AI with access to a student-records system," because the
  boundary makes student records unreachable. The audit + Policy 46
  classification enumerate everything that can cross.

**Critical-path item outside this repo:** determine the current UW
classification of the intended connector (e.g. Claude). If it is not
**Approved** (contract + completed IRA/PIA), the default "Reviewed for
Limited Use — publicly-sourced data only" posture would not cover
instructor-authored course content, which classifies **Confidential /
Restricted** under Policy 46 (answer keys and secret tests are the high-water
mark — `policy46-classification.md`). In that case the options are:
(a) procurement of enterprise terms for the connector (no-training,
bounded retention), or (b) an explicitly scoped limited-use approval that
accepts the Restricted content classes crossing, with the student-data wall
as the compensating control. Raise this in the very first Steward
conversation — everything else can proceed in parallel, but this decides the
contracting track.

---

## 1. Step 1 — Initiation and scoping: answers to bring

| Scoping question | Answer (with evidence) |
|------------------|------------------------|
| Intended use | An agent authors course content (assignments, test suites, notebooks, reference solutions) on an instructor's behalf, and reads operational diagnostics on an admin's behalf. Two separate MCP surfaces; catalog census 51 + 19 tools (`mcp-student-data-audit-2026-07.md` §2). |
| User groups & access roles | Course staff (per-course TA/instructor) for content; admins for diagnostics. Students are excluded at consent AND per-call (`MCPOAuthSurface.permits`, `requireEligibleSubject`). Agent reach ⊆ the human's enrolled courses, re-checked per request. |
| Data classification of what crosses | Instructor-authored content: problem statements Confidential; reference solutions / secret tests / personalization expressions **Restricted** (`policy46-classification.md`, to be refreshed — audit F-8). Student personal information: **none by design** once audit F-1/F-2 land; the evidence chain is §2 of the audit. Staff PI: the authorizing account's username for attribution only. |
| Where data lives / flows | System of record: UW-hosted (self-hosted deployment). Outbound destinations are five known non-model endpoints (`deploy/egress-allowlist.md`). What reaches the AI tool: MCP tool payloads only, over the OAuth-gated endpoints. Agent-side handling is governed by the connector's contract (Step 3). |
| Business need | Course-content authoring/maintenance assistance and operational diagnosis without widening student-data exposure; the alternative (human copy/paste into an AI tool) has strictly worse data-handling properties. |

**Steward engagement:** bring (a) the framing decision above, (b) the
connector-classification question, (c) the Policy 46 table for sign-off that
Restricted-but-not-student-PI content may cross under the contemplated tool
classification, and (d) the audit's F-5 note (small-cell aggregates) for an
explicit accepted-residual decision.

## 2. Step 2 — IRA / PIA: the submission package

The IRA/PIA intake (IST Help Portal / LIS) will ask about security controls,
vendor practices, retention, and privacy risk. The repo-side package:

1. **`mcp-student-data-audit-2026-07.md`** — the central claim ("no student
   data, direct or inferred") with per-tool evidence, findings, and the
   enforcement-test inventory. Submit only after F-1 and F-2 are closed so the
   claim is unqualified.
2. **Refreshed companions** (audit F-8): `tool-inventory.md` and
   `data-flow-inventory.md` regenerated for the 51-tool content catalog;
   admin-surface addenda for both; `policy46-classification.md` extended with
   the admin surface's data types (operational aggregates → Public/Internal;
   log/diagnostic text → Confidential); `trust-boundary.md` updated with the
   second audience (`/admin-mcp`) and the admin-only consent gate.
3. **PIA scoping answer, pre-drafted:** personal information *involved* in
   Chickadee at large (student records) vs. personal information *accessible
   to the AI tool* (none by design; staff attribution identity only). The PIA
   is expected to be mandatory regardless — the pre-drafted distinction is
   what keeps its scope tractable.
4. **Security-controls summary** (all already documented in the audit §2):
   OAuth 2.1 + PKCE with per-grant revocation; ES256 access tokens, 600 s
   TTL; disjoint audiences; per-request scope clamping; per-course
   authorization; consent role gates; fail-closed audit rows with outcome;
   production transport-guard refusal; single-use codes/consent tokens;
   refresh rotation with theft detection.
5. **Retention story:** audit log 90 days default (`AUDIT_LOG_RETENTION_DAYS`,
   hourly reaper); `query_logs` ring buffer is in-process and dies with the
   process; OAuth rows reaped hourly; diagnostic tables are operational
   records under existing schedules. Vendor-side retention belongs to Step 3.
6. **Verification evidence:** the enforcement tests
   (`MCPStudentDataWallTests`, `MCPAuthorizationCoverageTests`, per-tool PII
   tests, `MCPLeastPrivilegeGrantSyncTests`) and the RLS script
   (`deploy/sql/mcp-least-privilege-role.sql`) — the "reviewer can verify
   every claim from the repo" property both audits were written to.

## 3. Step 3 — Contracting and procurement (vendor side)

Owned by Procurement & Contract Services; the repo can only pin what the
product needs from the contract:

- No training on submitted content; bounded retention; the data classes that
  will cross (Confidential/Restricted instructor content, per the Policy 46
  table) named in the data-protection terms.
- Confirm whether an existing UW agreement already covers the connector
  (Step 0's classification question) before negotiating anything new.
- Chickadee-side commitments the contract can rely on: no model egress from
  the server, the egress allowlist, and the student-data wall.

## 4. Step 4 — Approval and onboarding: secure-configuration attestation

The expected path is a **limited-use, unit-level approval** first (one or two
pilot courses), enterprise later if wanted. The onboarding artifact is the
deployment attestation from audit F-9, executed on prod:

1. `MCP_DATABASE_USER=chickadee_mcp` set; `mcp-least-privilege-role.sql`
   applied; the SQL file's verification queries run and recorded.
2. `MCP_ALLOWED_HOSTS` / `MCP_ALLOWED_ORIGINS` set; `MCP_ALLOW_OPEN_GUARDS`
   unset.
3. `MCP_MODE` decision recorded (start `read_only`; move to `read_write` as a
   deliberate step — the per-request clamp makes rollback instant).
4. `AUDIT_LOG_RETENTION_DAYS` matching the PIA's stated retention.
5. Egress allowlist applied at the deployment layer.
6. BrightSpace sync remains disabled until F-2 is closed (its own enablement
   is a data-handling change — see Step 5).

## 5. Step 5 — Ongoing review: keep the record current by construction

Revalidation triggers to write into the unit's process, wired to mechanisms
the repo already has:

- **Tool-census drift:** extend the P2-3 checklist so any change to
  `MCPToolCatalog.live` or `AdminMCPToolCatalog.live` requires a compliance-doc
  touch in the same PR (the audit's F-8 remediation; a count-sync guard test
  in the spirit of `MCPInstructionsCatalogSyncTests` makes it automatic).
- **Data-handling changes that trigger re-review:** enabling BrightSpace sync;
  flipping `MCP_MODE` to `read_write` in prod; any new tool that widens a DTO;
  any change to the consent role gates; connector/vendor change (that one is
  UW's own five-year/contract-renewal trigger).
- **Standing evidence:** the enforcement tests run on every PR, so the
  architectural claims in the submission stay continuously verified between
  revalidations.

## 6. Ordered gap list before intake

1. Close audit **F-1** (log free-text identifiers) and **F-2** (BrightSpace
   detail) — the submission's central claim should need no asterisk.
2. Refresh the compliance companions to the 70-tool census (**F-8**).
3. Pre-draft the PIA scoping answer (§2.3 above).
4. Execute and record the deployment attestation (**F-9** / §4).
5. Resolve the connector's UW classification (§0) and open the Steward
   conversation with the §1 table.

Items 1–4 are repo/operator work and can land this week; item 5 is the
institutional critical path and should start immediately in parallel.
