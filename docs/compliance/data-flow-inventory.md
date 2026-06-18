# MCP Data-Flow & Egress Inventory

Audit scope: `Sources/APIServer/MCP/`. Snapshot at `VERSION` 0.4.435.

## The off-boundary path is not where the brief assumes

The audit brief asks us to "find every call site that sends data off-boundary
to the external model API — the outbound HTTP client call." **There is no such
call site in Chickadee.** This was verified two ways:

1. No code under `Sources/APIServer/MCP/` issues any outbound HTTP request. A
   search for `client.get/post/...`, `HTTPClient`, `URLSession` across the MCP
   tree returns nothing.
2. No model-provider client or API key exists anywhere in the codebase — no
   `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`, no Anthropic/OpenAI SDK in
   `Package.swift`, no base-URL/retention configuration (see
   `secrets & model-provider` section of `ira-audit-report.md`).

Chickadee **is the MCP server**. An external agent (e.g. the Claude connector)
connects *to* Chickadee's `/mcp` endpoint over HTTP/SSE
(`Sources/APIServer/MCP/Transport/MCPRoutes.swift`). The agent reads tool
results and forwards them to *its own* model provider. That model call happens
**inside the agent, outside Chickadee's process and outside this trust
boundary.**

Consequence for the data-flow analysis: the thing that "leaves toward the
model" is **whatever a tool returns over the MCP transport to the connected
agent.** Chickadee's control point is therefore *what each tool is allowed to
return* — the bounded surface and the student-data wall — not a model-API
egress filter it does not have. The columns below treat the tool's **return
payload** as the off-boundary content.

Chickadee's own outbound calls (OIDC/DUO, BrightSpace/D2L, the UW calendar
feed, the optional alert webhook, internal worker traffic) are unrelated to MCP
and carry no MCP content; they are catalogued in `ira-audit-report.md` §5.

## Instructor identity in tool output

Confirmed **identity stays server-side.** No tool places the acting
instructor's name, email, UW ID, or student number in its return payload. A
search of all tool handlers for `.email` / `preferredName` / `studentID` /
`userIdentifier` / `.username` in outputs found only test-script *display
names* (authored content), never user PII. The subject identity is used only
for authorization (`ToolContext.requireEligibleSubject`) and for the audit
record (`actorUsernameOverride: "<subject>-MCP"`,
`MCPDispatcher.swift:226-236`), both of which stay in the server/DB.

## Per-tool data flow

"Off-boundary payload" = bytes returned to the connecting agent.
Classification column references `policy46-classification.md`.

| Tool | Reads (in-boundary) | Off-boundary payload (returned to agent) | Contains student PII? | Classification |
|------|---------------------|------------------------------------------|-----------------------|----------------|
| `get_server_info` | none | version, MCP mode, scopes | No | Public |
| `list_courses` | enrolments, courses | course codes + names (enrolled only) | No | Confidential |
| `list_course_sections` | course, sections | section names | No | Confidential |
| `list_assignments` | assignments | titles, public IDs, open/closed | No | Confidential |
| `get_assignment` | assignment, section | title, due date, state, grading mode | No | Confidential |
| `get_suite` | test-setup manifest + zip | **all test scripts incl. secret tier**, family specs, hints | No (instructor content) | Restricted |
| `get_notebook` | starter notebook | starter `.ipynb` | No | Confidential |
| `get_solution` | validation/solution submission | **reference solution `.ipynb` (answer key)** | No (instructor content) | Restricted |
| `get_support_files` | setup zip helpers | helper file bodies | No | Restricted |
| `get_global_inputs` | manifest inputs | global + section inputs, per-student expressions | No | Confidential |
| `get_achievements` | manifest achievements | composable awards (badges/goals/records), built-in defaults until curated | No | Confidential |
| `preview_personalization` | manifest; `python3` eval | resolved per-seed values for the *previewed* seed | No (synthetic/instructor) | Restricted |
| `validate_assignment` | enqueues run; status | `passed`/`failed`/`no-runner` | No | Confidential |
| `get_validation_result` | validation submission + its result | per-test outcomes; **`submissionID`/`userID` dropped** (`GetValidationResultTool.swift:18-24`) | No (instructor reference run) | Restricted |
| `update_assignment` | assignment | echo of saved metadata | No | Confidential |
| `set_grading_mode` | assignment, setup | echo of mode | No | Confidential |
| `update_suite` | manifest | reconciled suite state | No | Restricted |
| `author_script` | setup zip | echo (filename, tier, validation status) | No | Restricted |
| `delete_suite_item` | manifest + zip | reconciled suite state | No | Restricted |
| `move_suite_item` | manifest | reconciled suite state | No | Confidential |
| `create_pattern_family` | manifest | family spec + generated filenames | No | Restricted |
| `update_pattern_family` | manifest | family spec + generated filenames | No | Restricted |
| `author_notebook_check` | manifest | check spec + generated filename | No | Restricted |
| `update_notebook` | starter notebook | echo (cell count) | No | Confidential |
| `update_solution` | solution submission | echo (filename, validation status) | No | Restricted |
| `update_global_inputs` | manifest | echo of saved inputs | No | Confidential |
| `update_achievements` | manifest | reconciled awards list (display-only; no regrade/close) | No | Confidential |
| `update_section_variables` | manifest | echo of saved vars | No | Confidential |
| `create_suite_section` | manifest | section id | No | Confidential |
| `rename_suite_section` | manifest | echo | No | Confidential |
| `delete_suite_section` | manifest | reconciled state | No | Confidential |
| `create_course_section` | course | section id | No | Confidential |
| `rename_course_section` | section | echo | No | Confidential |
| `delete_course_section` | section | echo | No | Confidential |
| `reorder_course_sections` | sections | echo of order | No | Confidential |
| `set_assignment_course_section` | assignment, section | echo | No | Confidential |
| `create_assignment` | course | new public ID | No | Confidential |
| `clone_assignment` | source + target setup | new public ID | No | Confidential |

## Models the MCP surface touches vs. never touches

**Touched (authoring + authz):** `APICourse`, `APICourseEnrollment` (authz read
only), `APICourseSection`, `APIAssignment`, `APITestSetup`, `APIUser` (authz:
username → id → role only), and `APISubmission`/`APIResult` **filtered to
`kind == .validation`** (the instructor's own reference-solution runs;
`GetValidationResultTool.swift:166-180`, `loadExistingSolution`).

**Never touched by any tool:** student `APISubmission` (non-validation),
student `APIResult` (grades), `APIGradeOverride`, `APIAssignmentExtension`,
`APIAssignmentParticipation`, `APIAssignmentPersonalizationSeed` content,
`APIClientDiagnostic`, `APISubmissionDiagnostics`, `JobExecutionMetric`,
`APIClassAchievement`, `APIUserActivityEvent`, `APIBrightSpaceSyncLog`,
`APIPreEnrollment`, `APIUserActivityEvent`.

**Caveat (see student-data wall finding):** "never touched" is true of the
*current* handler code, but it is enforced by which models each handler chooses
to query, on the **same full-privilege database connection** (`ToolContext.db`
= `request.db`). It is not yet enforced architecturally. The two student-data
tables the MCP surface *does* open — `submissions` and `results` — are reached
only through `.filter(\.$kind == .validation)`; a future handler that omits
that filter would reach student rows. That gap is the P0 item in
`remediation-plan.md`.
