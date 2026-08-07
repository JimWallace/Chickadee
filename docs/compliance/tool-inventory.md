# MCP Tool-Surface Inventory

Audit scope: the Model Context Protocol (MCP) surfaces under
`Sources/APIServer/MCP/`. Base snapshot taken at `VERSION` **0.4.435**;
**refreshed 2026-07 at `VERSION` 0.4.667** (see the addendum section at the
end and `mcp-student-data-audit-2026-07.md` for the full re-audit).

This is a complete, one-row-per-tool inventory of the MCP capability surface,
walked from the live registry (`MCPToolCatalog.live`,
`Sources/APIServer/MCP/Transport/MCPServerRegistration.swift`) down to each
tool's handler. As of the 2026-07 refresh (plus `delete_support_file`) the content catalog
registers **54 tools** (the table below plus the six-tool addendum), and a second,
admin-only diagnostic surface (`AdminMCPToolCatalog.live`) registers
**19 read-only tools** — inventoried in the addendum. The registries are the
source of truth; a census re-count is required whenever either changes
(remediation P2-3).

## How to read this table

- **Scope** — the OAuth scope the dispatcher requires before invoking
  (`requiredScopes`). Only two scopes exist: `content:read` and `content:write`
  (`Sources/APIServer/MCP/Tools/ContentScope.swift:8-11`). Neither grants
  student data, grades, enrolment management, or administration.
- **Resource arg** — the client-supplied identifier the handler accepts.
- **Authz** — the per-resource ownership check the handler runs. `course-enrol`
  means `ToolContext.authorizeCourseAccess` / `authorizedAssignment*`, which
  resolves the resource's `courseID` and requires the token subject to hold an
  enrolment row in that course (`Sources/APIServer/MCP/Tools/ToolContext.swift:67-115`).
  `eligible-only` means `requireEligibleSubject` (instructor/admin/mcp account,
  never a student) with no single resource to scope to (the listing is then
  filtered to enrolled courses).
- **Touches** — the Fluent models / on-disk artifacts the handler reads or writes.

## Read tools (`content:read`) — 14

| Tool | Handler (`file`) | Resource arg | Authz | Reads / touches | Output |
|------|------------------|--------------|-------|-----------------|--------|
| `get_server_info` | `GetServerInfoTool.swift:36` | — | scope only (DB-free) | none (static `appConfig.mcp`) | version, mode, advertised scopes |
| `list_courses` | `ListCoursesTool.swift:23` | — | eligible-only → enrolled filter | `APICourseEnrollment`, `APICourse` | enrolled courses (code, name) |
| `list_course_sections` | `CourseSectionTools.swift:38` | `courseCode` | course-enrol | `APICourse`, `APICourseSection` | section list |
| `list_assignments` | `ListAssignmentsTool.swift:30` | `courseCode` | course-enrol (`:89`) | `APICourse`, `APIAssignment` | assignment list (id, title, state) |
| `get_assignment` | `GetAssignmentTool.swift:39` | `assignmentPublicID` | course-enrol (`:87`) | `APIAssignment`, `APICourseSection` | metadata, grading mode, section |
| `get_suite` | `GetSuiteTool.swift:79` | `assignmentPublicID` | course-enrol (`:187`) | `APITestSetup` manifest + zip | full suite: script bodies, family specs, checks |
| `get_notebook` | `GetNotebookTool.swift:32` | `assignmentPublicID` | course-enrol (`:62`) | `APITestSetup` starter notebook | starter `.ipynb` |
| `get_solution` | `GetSolutionTool.swift:34` | `assignmentPublicID` | course-enrol (`:68`) | validation/solution submission (`kind==.validation`) | **reference solution `.ipynb`** |
| `get_support_files` | `GetSupportFilesTool.swift:53` | `assignmentPublicID` | course-enrol (`:111`) | `APITestSetup` zip helper files | support file bodies |
| `get_global_inputs` | `GetGlobalInputsTool.swift:27` | `assignmentPublicID` | course-enrol (`:78`) | `APITestSetup` manifest (inputs) | global + section inputs |
| `get_achievements` | `GetAchievementsTool.swift:25` | `assignmentPublicID` | course-enrol (`:61`) | `APITestSetup` manifest (achievements) | composable awards (built-in defaults until curated) |
| `preview_personalization` | `PreviewPersonalizationTool.swift:53` | `assignmentPublicID` | course-enrol (`:116`) + eligible (`:161`) | manifest; runs `python3` eval subprocess | per-seed resolved values |
| `validate_assignment` | `ValidateAssignmentTool.swift:36` | `assignmentPublicID` | course-enrol (`:82`) | enqueues validation run; reads `validationStatus` | passed/failed/no-runner |
| `get_validation_result` | `GetValidationResultTool.swift:69` | `assignmentPublicID` | course-enrol (`:113`) | validation submission + its `APIResult` only | per-test outcomes (no student identity) |

## Write tools (`content:write`) — 26

| Tool | Handler (`file`) | Resource arg | Authz | Writes / touches |
|------|------------------|--------------|-------|------------------|
| `create_assignment` | `CreateAssignmentTool.swift:39` | `courseCode` | course-enrol (`:100`) | new `APIAssignment` + `APITestSetup` |
| `clone_assignment` | `CloneAssignmentTool.swift:40` | source + target `assignmentPublicID`/`courseCode` | course-enrol on **both** (`:95`, `:117`) | new `APIAssignment` + `APITestSetup` |
| `update_assignment` | `UpdateAssignmentTool.swift:47` | `assignmentPublicID` | course-enrol (`:136`) | `APIAssignment` (title/due/open-close) |
| `set_grading_mode` | `SetGradingModeTool.swift:31` | `assignmentPublicID` | course-enrol (`:73`) | `APIAssignment` grading mode |
| `set_submission_mode` | `SetSubmissionModeTool.swift:36` | `assignmentPublicID` | course-enrol (`:76`) | `APITestSetup` manifest (submission mode) |
| `set_assignment_language` | `SetAssignmentLanguageTool.swift:39` | `assignmentPublicID` | course-enrol (`:87`) | `APITestSetup` manifest (declared language) |
| `update_suite` | `UpdateSuiteTool.swift:46` | `assignmentPublicID` | course-enrol (`:116`) | `APITestSetup` manifest (suite metadata) |
| `author_script` | `AuthorScriptTool.swift:58` | `assignmentPublicID` + `filename` | course-enrol (`:194`) | **verbatim file into setup zip** (escape hatch — see below) |
| `delete_suite_item` | `DeleteSuiteItemTool.swift:49` | `assignmentPublicID` + item | course-enrol (`:103`) | `APITestSetup` manifest + zip |
| `delete_support_file` | `DeleteSupportFileTool.swift:49` | `assignmentPublicID` + `filename` | course-enrol (`:110`) | `APITestSetup` manifest + zip |
| `move_suite_item` | `MoveSuiteItemTool.swift:53` | `assignmentPublicID` + item | course-enrol (`:111`) | `APITestSetup` manifest (placement only) |
| `create_pattern_family` | `CreatePatternFamilyTool.swift:131` | `assignmentPublicID` | course-enrol (`:312`) | `APITestSetup` manifest + generated scripts |
| `update_pattern_family` | `UpdatePatternFamilyTool.swift:123` | `assignmentPublicID` | course-enrol (`:329`) | `APITestSetup` manifest + generated scripts |
| `author_notebook_check` | `AuthorNotebookCheckTool.swift:124` | `assignmentPublicID` | course-enrol (`:297`) | `APITestSetup` manifest + generated check |
| `update_notebook` | `UpdateNotebookTool.swift:37` | `assignmentPublicID` | course-enrol (`:82`) | starter notebook in `APITestSetup` |
| `update_solution` | `UpdateSolutionTool.swift:39` | `assignmentPublicID` | course-enrol (`:90`) + eligible (`:94`) | **reference solution** submission |
| `update_global_inputs` | `UpdateGlobalInputsTool.swift:38` | `assignmentPublicID` | course-enrol (`:113`) + eligible (`:118`) | `APITestSetup` manifest (inputs) |
| `update_achievements` | `UpdateAchievementsTool.swift:35` | `assignmentPublicID` | course-enrol (`:81`) | `APITestSetup` manifest (achievements; display-only, no regrade/close) |
| `update_section_variables` | `UpdateSectionVariablesTool.swift:35` | `assignmentPublicID` | course-enrol (`:115`) + eligible (`:118`) | `APITestSetup` manifest (section vars) |
| `create_suite_section` | `SuiteSectionTools.swift:39` | `assignmentPublicID` | course-enrol (`:84`) | `APITestSetup` manifest (sections) |
| `rename_suite_section` | `SuiteSectionTools.swift:115` | `assignmentPublicID` | course-enrol (`:164`) | `APITestSetup` manifest (sections) |
| `delete_suite_section` | `SuiteSectionTools.swift:202` | `assignmentPublicID` | course-enrol (`:244`) | `APITestSetup` manifest (sections) |
| `create_course_section` | `CourseSectionTools.swift:117` | `courseCode` | course-enrol (`:632`) | new `APICourseSection` |
| `rename_course_section` | `CourseSectionTools.swift:318` | section id | course-enrol (`:586`) | `APICourseSection` |
| `delete_course_section` | `CourseSectionTools.swift:409` | section id | course-enrol (`:586`) | `APICourseSection` (assignments ungrouped) |
| `reorder_course_sections` | `CourseSectionTools.swift:483` | `courseCode` | course-enrol (`:632`) | `APICourseSection` order |
| `set_assignment_course_section` | `CourseSectionTools.swift:208` | `assignmentPublicID` + section | course-enrol (`:247`, `:453`) | `APIAssignment` section ref |
| `reorder_section_items` | `AssignmentOrderingTools.swift` | `courseCode` + `orderedItems` | course-enrol (`resolveCourseIDForWrite`, TA+) | `APIAssignment` + `APICourseContentItem` order (`sort_order`) |
| `reorder_assignments` | `AssignmentOrderingTools.swift` | `courseCode` | course-enrol (`resolveCourseIDForWrite`, TA+) | `APIAssignment` order (`sort_order`) |
| `list_content_items` | `CourseContentItemTools.swift` | `courseCode` | course-enrol (`resolveCourseID`) | `APICourseContentItem` (read) |
| `create_content_item` | `CourseContentItemTools.swift` | `courseCode` | course-enrol (`resolveCourseIDForWrite`, TA+) | new `APICourseContentItem` |
| `update_content_item` | `CourseContentItemTools.swift` | content-item id | course-enrol (`authorizeCourseWriteAccess`, TA+) | `APICourseContentItem` |
| `delete_content_item` | `CourseContentItemTools.swift` | content-item id | course-enrol (`authorizeCourseWriteAccess`, TA+) | `APICourseContentItem` |
| `reorder_content_items` | `CourseContentItemTools.swift` | `courseCode` | course-enrol (`resolveCourseIDForWrite`, TA+) | `APICourseContentItem` order (`sort_order`) |

## Escape-hatch / general-capability audit

Each tool has a typed `Input`/`Output` decoded by the dispatcher
(`ContentTool.swift:122-145`); handlers never see untyped JSON, so there is no
"run this raw request" surface. We specifically searched for the five
unassessable capabilities:

| Capability | Present? | Evidence |
|------------|----------|----------|
| Arbitrary code execution in the MCP process | **No** | No `Process`/`exec`/`eval` in any tool handler. `preview_personalization` runs `python3` in a **separate, env-scrubbed** subprocess (the existing `PersonalizationEvaluator`), not in-process. |
| Raw / dynamically-constructed SQL | **No** | All DB access is Fluent's typed query builder. No `SQLDatabase`/`raw(`/string-built SQL anywhere under `MCP/`. |
| Shell-out | **No** | No shell invocation in tool handlers. |
| Arbitrary file read/write | **Bounded** | Writes are confined to a specific assignment's test-setup zip / support dir; filenames are sanitised to a bare name (`sanitizeSuiteFilename`, `AuthorScriptTool.swift:187-192`) so no path traversal. |
| Fetch-any-URL (SSRF) | **No** | No tool issues an outbound HTTP request. The MCP server makes **zero** outbound model/LLM calls (see `data-flow-inventory.md`). |

### The one escape hatch: `author_script`

`author_script` (`AuthorScriptTool.swift`) is the deliberate raw-authoring
channel the other write tools omit. Exact contract:

- **Input it accepts** (`AuthorScriptTool.swift:28-40`): `assignmentPublicID`,
  `filename` (bare name, no separators), `content` (full script body, written
  **verbatim**), and optional `tier`/`points`/`displayName`/`dependsOn`/`sectionID`.
- **How the input is stored**: the body is written into that assignment's
  test-setup zip (test tier → through the same `applySuiteEdit` path the web
  editor uses, `:298`; support tier → direct zip write, `:303-334`). It is
  **not executed at MCP-call time.**
- **How/where it is executed**: only later, by the **Worker**, when the
  assignment's tests run — under the `ScriptRunner` boundary
  (`UnsandboxedScriptRunner` in dev; `SandboxedScriptRunner` with macOS
  `sandbox-exec` / Linux `unshare` namespaces in production, per `CLAUDE.md`).
  Swift never imports a language runtime; everything runs as a subprocess
  behind the sandbox.
- **Bounds**: course-scoped authorization (`:194`); cannot overwrite
  pattern-family / notebook-check generated scripts (`:199-203`, mirrors the
  web 409); saving re-runs validation and closes the assignment until it passes
  (`:244`). The agent can author arbitrary test logic, but only into a course
  it is enrolled in, and that logic executes only inside the existing grading
  sandbox — the same trust model as a human instructor uploading a test script.

**Residual to record in the IRA**: an authorised agent can introduce arbitrary
Python/shell that later runs in the grading sandbox. This is identical to the
existing instructor capability and is mitigated by (a) course-scoped authz,
(b) the `ScriptRunner` sandbox at execution time, and (c) the audit trail. It
is *not* a new in-process execution surface.

---

## Addendum (2026-07, v0.4.667): tools added since the base snapshot

Six content tools joined `MCPToolCatalog.live` after v0.4.435. Same
conventions as the tables above; every one routes through the standard
authorization chokepoints (pinned registry-wide by
`MCPAuthorizationCoverageTests`).

| Tool | Handler (`file`) | Resource arg | Authz | Reads / touches | Output |
|------|------------------|--------------|-------|-----------------|--------|
| `list_assignment_versions` | `AssignmentVersionTools.swift` | `assignmentPublicID` | course-enrol | `APIAssignmentVersion` (content snapshots) | version list (id, timestamp, actor label) |
| `get_assignment_version` | `AssignmentVersionTools.swift` | `assignmentPublicID`, version id | course-enrol | `APIAssignmentVersion` | one snapshot's content (suite/notebook state) |
| `restore_assignment_version` | `RestoreAssignmentVersionTool.swift` | `assignmentPublicID`, version id | course-enrol write (TA+) | `APIAssignmentVersion`, `APITestSetup` | restored content; closes + revalidates via `finalizeContentEdit` |
| `set_dataset` | `SetDatasetTool.swift` | `assignmentPublicID`, filename | course-enrol write (TA+) | `APITestSetup` manifest (`TestProperties.datasets`) | dataset specs after edit (file, sampleSize) |
| `set_time_limit` | `SetTimeLimitTool.swift` | `assignmentPublicID` | course-enrol write (TA+) | `APITestSetup` manifest (`timeLimitSeconds`) | updated limit |
| `set_minimum_runner_version` | `SetMinimumRunnerVersionTool.swift` | `assignmentPublicID` | course-enrol write (TA+) | `APIAssignmentRequirement` | updated requirement |

All six return instructor-authored content or configuration only; none touches
a student-data model (enforced by `MCPStudentDataWallTests`, whose scan now
also covers `Transport/` + `Resources/` and confines identity models to the
authorization layer — 2026-07 audit F-6).

## Addendum (2026-07): the admin diagnostic surface (19 tools)

A second, **read-only** MCP surface at `POST /admin-mcp`
(`AdminMCPToolCatalog.live`, design record `docs/admin-mcp.md`), mounted with
the content surface but separated by OAuth audience and scope
(`diagnostics:read` only — the scope enum has no write case). Consent requires
`isAdmin` and every DB-touching tool re-checks the subject per call
(`AdminToolContext.requireAdminSubject`). Every tool's returned DTO was
verified field-by-field in `mcp-student-data-audit-2026-07.md` §2.2 (which
carries the full source→fields→posture table); per-tool PII tests seed student
rows and assert their identifiers never serialize (`AdminMCPToolsTests`).

| Tool | Source | PII posture |
|------|--------|-------------|
| `get_deployment_info` | static config (DB-free) | clean |
| `get_deploy_status` / `get_deploy_history` | deployer status/history files | clean |
| `get_metrics_snapshot` / `get_metrics_card_series` / `get_metrics_timeseries` | dashboard aggregate builders | aggregates only |
| `get_active_users_series` | `ActivityChartService` | distinct counts per bucket only |
| `get_instructor_card_series` | `instructorCardSeries` (one course) | per-bucket counts only; PII-tested |
| `get_queue_state` | submissions table | counts/ages only |
| `list_runners` / `get_runner_detail` | worker rows, `job_execution_metrics` | aggregates; per-job rows (username + submission id) deliberately omitted; PII-tested |
| `get_storage_usage` | storage scan | per-assignment byte/count aggregates |
| `get_request_metrics` | `request_metrics` | routes normalized to `:id`; prefix filter matches normalized routes (audit F-3) |
| `get_health_alerts` | live rule evaluation | counts/thresholds; BrightSpace `last_error` writer-sanitized (audit F-2) |
| `get_browser_diagnostics` | `client_diagnostics` | `user_id` omitted; samples carry the coarse browser/OS label, never the raw User-Agent (audit F-4); PII-tested |
| `list_connected_agents` | OAuth grants | owner is the authorizing staff/admin (consent-gated), never a student; no token material |
| `get_brightspace_sync_status` | `brightspace_sync_log` | `username`/`points`/`user_id` columns omitted; `detail` sanitized at write (audit F-2); PII-tested |
| `query_audit_log` | `audit_log` | counts by action/category only — no row, actor, IP, or metadata ever loaded |
| `query_logs` | in-process warning+ ring buffer | PII metadata keys dropped at capture; message hygiene pinned by `LogMessageHygieneTests` (audit F-1) |

Admin tool calls are themselves audited (`admin_mcp.tool_called`, with
outcome).
