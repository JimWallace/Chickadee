# MCP Assignment-Authoring Roadmap

Status: **largely delivered**. Goal: let MCP agents help instructors **create
and edit assignments**, built out in phases. Every tool phase (1–5) plus the SSE
streaming track has shipped; this document is kept as the design record and the
sequencing/rationale behind the work. The "where we are today" and
sequencing/open-question sections below are updated to mark what landed; the
design-principle sections (§2–§5) remain the rationale that still governs new
tools.

It builds on the MCP server foundation already shipped: the OAuth 2.1 bearer
flow, `content:read` / `content:write` scopes, per-tool scope enforcement, and
**course-scoping** (an agent may only touch courses its account is enrolled in —
added in the `mcp-course-scoping-and-hardening` work, PR #704).

---

## 1. Where we are today

The original vertical slice (two tools, proving the auth/transport/dispatch
pipeline) has grown into the full feature. The live tool catalog
(`MCPToolCatalog.live` in
`Sources/APIServer/MCP/Transport/MCPServerRegistration.swift`) now ships
thirty-four tools, all `content:read` / `content:write` scoped and
course-scoped:

| Tool | Scope | Capability |
|------|-------|------------|
| `list_courses` | `content:read` | Courses the subject may act on |
| `get_server_info` | `content:read` | Deployed version + MCP mode/advertised scopes (liveness + capability probe) |
| `list_assignments` | `content:read` | A course's assignments (id, title, slug, open/closed, due date) |
| `list_course_sections` | `content:read` | A course's assignment groups (id, name, default grading mode, order) |
| `get_assignment` | `content:read` | One assignment's full detail (incl. gradingMode + course section) |
| `get_suite` | `content:read` | Full test-suite definition: items, tiers, points, deps, sections, plus each script's raw body, each family's full spec (cases' args/expected), and each notebook check's spec |
| `get_notebook` | `content:read` | The starter notebook (.ipynb JSON) |
| `get_solution` | `content:read` | The reference solution notebook (.ipynb JSON), resolved from the validation submission |
| `get_global_inputs` | `content:read` | Assignment personalization: global variables + per-student expressions |
| `preview_personalization` | `content:read` | Resolve a seed's `name → value` map + a starter-notebook `{{placeholder}}` audit |
| `validate_assignment` | `content:read` | Watch validation to completion; live SSE progress |
| `update_assignment` | `content:write` | Metadata: title, due date, visibility (closed/preview/open) |
| `set_grading_mode` | `content:write` | Set an assignment's grading path (worker vs browser); no regrade/close |
| `update_suite` | `content:write` | Script metadata: tier, points, displayName, dependsOn, section |
| `update_global_inputs` | `content:write` | Replace the assignment's global personalization variables/expressions |
| `update_section_variables` | `content:write` | Replace a section's scoped variables/expressions |
| `create_suite_section` / `rename_suite_section` / `delete_suite_section` | `content:write` | Manage an assignment's test-suite sections (display groups) |
| `move_suite_item` | `content:write` | Move a script/family/check into a suite section, or ungroup it |
| `create_pattern_family` | `content:write` | Create a new pattern family: kind, function, cases (args/expected/hint), defaults (tier/points/`defaultHint`) |
| `update_pattern_family` | `content:write` | Family defaults (tier/points/`defaultHint`) + per-case args/expected/hint (incl. per-student `$ref`s), enable/disable |
| `delete_suite_item` | `content:write` | Remove a script, family (+ its cases), or notebook check from the suite |
| `author_notebook_check` | `content:write` | Create/replace a notebook check (DataFrame shape/columns/equality, figures, AST, …) |
| `author_script` | `content:write` | Escape hatch: create/replace a hand-written test (prefer a pattern family / notebook check) or a non-graded support file |
| `update_notebook` | `content:write` | Replace the starter notebook |
| `update_solution` | `content:write` | Replace the reference solution and re-validate |
| `create_course_section` | `content:write` | Create a course section (assignment group) with a default grading mode |
| `rename_course_section` | `content:write` | Rename a course section and/or change its default grading mode |
| `delete_course_section` | `content:write` | Delete a course section (assignments in it are ungrouped, not deleted) |
| `reorder_course_sections` | `content:write` | Set the display order of a course's sections |
| `set_assignment_course_section` | `content:write` | Place an assignment into a course section (adopts its grading mode), or ungroup it |
| `clone_assignment` | `content:write` | Duplicate an assignment (closed, unvalidated) |
| `create_assignment` | `content:write` | New notebook-based assignment from scratch |

Every content-edit write tool (suite/family/check/script/notebook/solution)
re-runs validation and **closes** a currently-open assignment so students can't
submit against a not-yet-revalidated suite — reported in the tool result as
`assignmentClosed`. Metadata-only edits (`update_assignment`,
`set_grading_mode`, section organization) do not.

In addition to tools, the server exposes **resources**: `resources/list` /
`resources/read` surface each accessible assignment's raw `test.properties.json`
manifest at `chickadee://assignment/<publicID>/manifest` (the verbatim authoring
spec; `get_suite` is the structured view — and now carries the same full detail,
including script bodies and pattern-family cases). See
`Sources/APIServer/MCP/Resources/MCPResourceProvider.swift`.

The legacy `update_assignment_title` tool folded into `update_assignment`.

### The authoring domain (what a full assignment is)

- **Metadata** — title, due date, open/closed, display names, per-course slug.
- **A test setup** (`APITestSetup`) — a zip of shell-script test suites plus a
  `test.properties.json` manifest (`Core.TestProperties`).
- **Suite structure** — ordered `TestSuiteEntry` across four tiers, grouped into
  `TestSuiteSection`s, a `dependsOn` graph, and pattern-generated test families
  (`PatternFamily` / `PatternCase` / `PatternKind`).
- **Notebook(s)** — starter + solution notebooks (JupyterLite / Pyodide),
  generalized inputs, per-student personalization.
- **Side effects** — saving an edited assignment enqueues a validation run, and
  if the manifest bytes changed, **re-queues every student submission** for
  regrade.

---

## 2. Design principles (apply to every phase)

1. **One source of truth for authoring logic.** Tools must reuse the same code
   the web UI uses, not reimplement it, or they will drift (skip validation,
   miss the regrade fan-out, break `spec_hash` / `TestSetupCache` keys, etc.).
   See Phase 0.
2. **Course-scoping on every write.** Each tool calls
   `ToolContext.authorizeCourseAccess(courseID, tool:)` (admins global; everyone
   else must be enrolled). This is already enforced for the existing tools.
3. **Blast-radius transparency.** Any edit that changes the manifest re-grades
   all student submissions. The tool result must report the count (and ideally
   support a `dryRun` preview) so neither the agent nor the human is surprised.
4. **Close the validation loop.** Edits enqueue a validation run; tools should
   return the validation status (or a handle to poll) so an agent can confirm
   its change actually compiles/passes before declaring success.
5. **Respect read-only states.** Closed assignments load read-only in the editor
   (v0.4.166). Tools either honor that or require an explicit reopen.
6. **Canonical generation only.** All script/family changes flow through
   `applyPatternFamilies` so generated bytes and cache keys stay correct.

---

## 3. Phase 0 — the authoring service layer (foundation)

**Why first:** without it, every create/edit tool either duplicates orchestration
or drifts from the UI. This is pure backend, fully CI-testable, no behavior
change.

### What's already reusable (good news)

These are already `Database`-based and callable from a tool directly:

- `applySuiteEdit(setup:body:on db:)` — `Sources/APIServer/Routes/Web/SuiteEditHelpers.swift`
  (the core of `PUT /suite`: authored items → `applyPatternFamilies`).
- `applyPatternFamilies(...)` — the canonical generator.
- `retestAllSubmissionsForSetup(setupID:triggeredBy:on db:force:)` —
  `Sources/APIServer/Routes/Web/RunnerValidationHelpers.swift`.
- `assignmentByPublicID(_:on:)`, `uniqueAssignmentSlug(...)` —
  `Sources/APIServer/Routes/Web/AssignmentSlugHelpers.swift`.

### What is still `Request`-coupled (the seams to extract)

- `saveEditedAssignment(req:)` — `PublishedAssignmentRoutes+SaveEdit.swift`:
  the metadata-save orchestration (title/due/open + validation enqueue).
- `scheduleValidationAfterSuiteEdit(req:assignment:)` — `RunnerValidationHelpers.swift`:
  loads the solution + requirement spec and enqueues a validation submission;
  reaches `req.application` for runner availability.
- `createAssignmentWithUniquePublicID(req:...)` — `AssignmentSlugHelpers.swift`.
- New-assignment publish — `DraftAssignmentRoutes+NewAssignment.swift`.
- Suite-section CRUD — `PublishedAssignmentRoutes+SuiteSections.swift`.

> Note: `ToolContext` already carries the live `Request` (`context.request`), so
> tools *can* call `req`-based helpers. But the **orchestration sequences** (the
> ordered "apply edit → enqueue validation → retest-if-manifest-changed" glue)
> live inline in the route handlers; those are what we extract.

### Deliverable

A new `Sources/APIServer/Services/AssignmentAuthoringService.swift` (or a small
set of free functions) exposing `Database`/`Application`-based operations:

- `updateAssignmentMetadata(...)` — title/due/open + validation enqueue.
- `applySuiteChange(...)` — wraps `applySuiteEdit` + validation + conditional
  retest, returning a summary (incl. affected-submission count).
- `applyFamilyChange(...)` — pattern-family add/edit/delete.
- `createAssignment(...)` — allocate id/slug, persist setup + manifest, enqueue
  validation.

Then refactor the web handlers to call these (thin wrappers). Existing 1446-test
suite guards against regressions; add direct service unit tests.

**Validation-enqueue caveat:** validation needs `Application` (runner
availability). The service takes `app`/`db`; `ToolContext` already exposes both
via `context.request`. Decide whether validation is synchronous-enqueue
(return a handle) — recommended — vs. fire-and-forget.

---

## 4. Tool phases

### Phase 1 — Read the full picture (low risk)

- **`get_assignment`** (`content:read`) — full detail: metadata, sections,
  suites by tier (script + generated), pattern families, `dependsOn`, due date,
  open state, validation status, runner requirements. Backed by `APIAssignment`
  + `APITestSetup.decodedManifest()`.
- **`list_courses`** (`content:read`) — courses the subject is enrolled in
  (admins: all), so an agent can discover where it may act.

### Phase 2 — Metadata edits (low risk)

- **`update_assignment`** (`content:write`) — due date, open/close, display
  name (title folds in here; deprecate `update_assignment_title` or keep as an
  alias). Calls `updateAssignmentMetadata`. No manifest change → no regrade.

### Phase 3 — Test-suite authoring (medium risk, highest value) ⭐

- **`get_suite`** / **`update_suite`** — tiers, points, order, display names,
  dependencies, sections. Wraps `applySuiteChange` (→ `applySuiteEdit`).
- **Pattern families** — `add/edit/delete_pattern_case` (or one
  `update_pattern_family`) for `.boundaryEquality` / `.approximateEquality` /
  `.variableEquality`. Wraps `applyFamilyChange` (→ `applyPatternFamilies`).
- Manifest changes here trigger validation + regrade; the tool result reports
  the affected-submission count (principle #3).

### Phase 4 — Create an assignment (high risk)

Needs an **input-model decision** (see §5). Recommended first cut:
**clone-and-edit** — `clone_assignment(sourcePublicID, newTitle, courseCode)`
duplicates an existing assignment's setup + notebook, then the agent uses Phase
1–3 tools. Sidesteps "produce a valid notebook/scripts from nothing." A
full `create_assignment` (structured spec) follows.

### Phase 5 — Notebook content (high risk, least CI-testable)

Starter/solution notebook get/set, generalized inputs, personalization. The
notebook model is JupyterLite/Pyodide-centric. Slice last and small; likely the
agent supplies `.ipynb` JSON / source text and the server validates. Per the
"slice untestable frontend work" rule, keep these PRs small and dev-verifiable.

---

## 5. The Phase-4 input-model decision

How does an agent "create" an assignment?

- **(a) Structured spec** — agent supplies title/course/requiredFiles/suites/
  pattern-families/starter-notebook-as-text; server assembles zip + manifest +
  notebook. Most flexible, most validation surface.
- **(b) Clone-and-edit** *(recommended first)* — duplicate an existing
  assignment, then edit via Phase 1–3 tools. Safest; composes with earlier
  phases.
- **(c) Template** — server-defined templates the agent fills in.

Ship (b) first; layer (a) on once Phase 3 tools are proven.

---

## 6. Sequencing / PR plan — **all shipped**

1. ✅ **Phase 0 + Phase 1.** `AssignmentAuthoringService` extracted; web handlers
   refactored to use it; `get_assignment` + `list_courses` shipped.
2. ✅ **Phase 2.** `update_assignment` (metadata).
3. ✅ **Phase 3a.** `get_suite` / `update_suite`.
4. ✅ **Phase 3b.** Pattern-family editing (`update_pattern_family`).
5. ✅ **Phase 4a.** `clone_assignment`.
6. ✅ **Phase 4b.** `create_assignment` (structured spec).
7. ✅ **Phase 5.** Notebook content: `get_notebook` (read) + `update_notebook`
   (write).

Plus, beyond the original plan: the SSE streaming track (§8) and the
`validate_assignment` tool that closes the validation loop (§7), and MCP
resources for manifests (§1).

Each PR held to: `content:*` scope + `authorizeCourseAccess`, swift-format +
SwiftLint `--strict` clean, tests green.

---

## 7. Open questions

- ✅ **Validation feedback shape** — *resolved.* Shipped as the
  `validate_assignment` tool: write tools enqueue validation as a side effect,
  and an agent then calls `validate_assignment` to bounded-wait (default 30s,
  clamped 1–120) for the terminal status — or, over an SSE connection carrying a
  `progressToken`, receive live `queued → running → done` progress before the
  result (§8). The agent can also poll `get_assignment`'s `validationStatus`.
- ✅ **Notebook input format** — *resolved.* The agent supplies full `.ipynb`
  JSON (`update_notebook` / `create_assignment`); the server normalizes it for
  the in-browser kernel.
- ✅ **Tool granularity** — *resolved.* `update_suite` takes per-script metadata
  edits and `update_pattern_family` takes family-level edits; both re-save
  through the same `applySuiteEdit` the `PUT /suite` web path uses.
- **Destructive-edit confirmation** — *partially addressed.* Manifest-changing
  content edits now **automatically re-grade** every existing student submission
  against the new suite (gated on a real manifest change, idempotent), matching
  the human "Retest all" button — so prior grades no longer silently go stale
  (`retestSubmissionsAfterContentEdit`). Still open: a `dryRun` preview, and
  surfacing the affected-submission count in the tool result rather than only the
  server log (design principle #3).

---

## 8. Transport track: SSE / streaming progress — **shipped**

**Delivered in two PRs:** #724 made the `/mcp` POST response negotiable to an
SSE stream (`Accept: text/event-stream`); #726 added the worker→stream bridge so
`validate_assignment` emits live `notifications/progress` (`queued → running →
done`) before the final result when the call carries a `progressToken`. The
transport stays stateless (no `Mcp-Session-Id` / `Last-Event-ID` resumability);
the standalone server-initiated GET stream remains unimplemented (405). The
design notes below are retained as the rationale.

**Target client:** the **Claude connector**, which speaks Streamable HTTP with
SSE — so the streaming UX pays off, and resumability is not required.

The `/mcp` POST returns either a single JSON response or an SSE stream
(`text/event-stream`) by content negotiation; GET/DELETE 405
(`streamingUnsupported`). The SSE form lets the server emit
`notifications/progress` during a long tool call and then the final result.

**What it buys us:** a tight, live agent loop on validation —
`queued → assigned → running → 3/4 passed → done` — with progress events acting
as keepalives that reset the client's tool-call timeout, so multi-minute
validations don't trip the ceiling. This is the proper upgrade to the §7 hybrid.

**Why it's a parallel track, not a blocker:**

- The bounded-wait hybrid works **without** SSE and the tool contract is
  **forward-compatible** — the same tools can later stream progress instead of
  briefly blocking, with no change to inputs/outputs. Deferring SSE costs
  nothing architecturally.
- It's a transport-level change to the security-sensitive `MCPRoutes` surface,
  so it deserves its own focused PR rather than riding inside authoring work.

**The real costs (in rough order of effort):**

1. **Worker → stream bridge (the hard part).** Validation runs on the separate
   runner daemon and reports by updating the submission row. To stream progress
   the server must observe those `pending → assigned → running → done`
   transitions — either DB-poll the submission while the stream is open, or add
   a lightweight in-process status-change signal.
2. **Reverse-proxy buffering.** SSE breaks under nginx/squid default buffering.
   Need `proxy_buffering off` + `X-Accel-Buffering: no` on `/mcp`. Verify
   against the dev box's *actual* (hand-customized) compose/proxy config, not
   just the repo's — this is the kind of thing that works locally and fails
   deployed.
3. **Vapor streamed response** — detect `Accept: text/event-stream`, switch the
   POST response to SSE, write JSON-RPC framed as SSE events, handle client
   disconnect / `notifications/cancelled`, close cleanly.
4. **Stay stateless** — a basic non-resumable SSE-per-call is enough; do **not**
   adopt `Mcp-Session-Id` / `Last-Event-ID` replay (keeps the single-process
   model). The standalone GET SSE stream stays unimplemented (405) — not needed
   for the validation use case.

**Sequencing:** slot around Phase 2–3, once there's a long-running tool worth
streaming. First PR ≈ streamed POST response + the worker→stream bridge + the
proxy-config fix + tests. Bearer auth is unaffected (the SSE response is just a
streamed reply to the already-authenticated POST).
