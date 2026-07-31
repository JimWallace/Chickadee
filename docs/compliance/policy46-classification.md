# Policy 46 Data Classification — MCP Outbound Data Types

Provisional classification of every distinct data type the MCP surface can
return to a connecting agent (and thus, downstream, to that agent's model
provider). For the Information Steward to confirm.

Classification scheme follows UW Policy 46 (Information Management) data
classes: **Public**, **Confidential**, **Restricted**, **Highly Restricted**.
These are provisional engineering assessments, not an official ruling.

> Reminder of where this data goes (see `data-flow-inventory.md`): Chickadee
> never calls a model API itself. Each item below leaves the boundary only when
> a tool returns it to the connected agent, which then forwards it to its model
> provider. The agent and its provider are governed by the connector's own
> contract/configuration, confirmed during the paperwork — not by Chickadee
> code.

| # | Data type | Source / tool | Provisional class | Rationale |
|---|-----------|---------------|-------------------|-----------|
| 1 | **Reference solution (answer key)** | `get_solution`, `update_solution`, materialised in `preview_personalization` | **Restricted** | Disclosure before/with an open assessment defeats grading integrity for the whole cohort; the single most sensitive authoring artifact. Treat as the high-water mark. |
| 2 | **Secret-tier & release-tier test scripts** | `get_suite`, `get_validation_result` (all tiers), `author_script`, family/check tools | **Restricted** | Secret tests are by design never shown to students; release tests are hidden until the deadline. Early disclosure enables gaming the autograder. |
| 3 | **Support / helper files** | `get_support_files`, `author_script` (support) | **Restricted** | Frequently embed solution logic (e.g. generators, `solution.py`) that the reference solution imports. Same sensitivity as the answer key. |
| 4 | **Personalization inputs & per-student expressions** | `get_global_inputs`, `update_global_inputs`, `update_section_variables`, `preview_personalization` | **Restricted** | Expressions can encode the solution (`expected = solution.foo(...)`); resolved values can reveal per-student answers. No real student identity is included, but the answer-deriving logic is. |
| 5 | **Validation-run outcomes** | `get_validation_result`, `validate_assignment` | **Restricted** | These are the *instructor's* reference-solution run, deliberately stripped of `submissionID`/`userID` (`GetValidationResultTool.swift:18-24`). Per-test pass/fail of secret tiers is still sensitive pre-deadline; no student data. |
| 6 | **Public-tier test scripts** | `get_suite`, `author_script` (public) | **Confidential** | Shown to students at submission time, so lower sensitivity — but still pre-release course material, not public web content. |
| 7 | **Problem statement / starter notebook** | `get_notebook`, `update_notebook` | **Confidential** | Assignment prompts are course material; sensitive until released, generally not classified above Confidential once an assignment is open. |
| 8 | **Assignment metadata** (title, due date, open/closed, grading mode, slug) | `get_assignment`, `list_assignments`, `update_assignment`, `set_grading_mode` | **Confidential** | Course-operational data; not public, no PII. |
| 9 | **Course & section structure** (course code, name, section names, ordering) | `list_courses`, `list_course_sections`, course/suite-section tools | **Confidential** | Course-operational; reveals which courses the account can reach. No PII. |
| 10 | **Server capability metadata** (version, MCP mode, scopes) | `get_server_info` | **Public** | Non-sensitive operational metadata; no course or user data. |
| 11 | **Achievements / awards configuration** (badges, class goals, records) | `get_achievements`, `update_achievements` | **Confidential** | Instructor-authored, server-evaluated, display-only awards shown to students; course-operational config. A `testPass` condition can name a test file, but encodes no answer logic and no PII. |

## Notes for the Information Steward

- **No student PII, grades, submissions, or roster data appear in any row.**
  The MCP surface is architected to exclude them (see student-data wall
  finding). Items 1–5 are *instructor-authored* sensitivity, not student
  personal information — the FIPPA exposure here is academic-integrity, not
  privacy-of-individuals.
- **Highest-sensitivity items are 1–5 (Restricted).** If the deployment wants
  to minimise what reaches the third-party model, the lever is payload
  minimisation: the reference solution (item 1) is only needed by
  `get_solution`/`update_solution`/personalization preview, not by the
  metadata or structural tools. See P1 in `remediation-plan.md`.
- **No item is assessed Highly Restricted**, because the surface carries no
  student personal information, financial data, or special-category data. If
  the Steward classifies the reference solution as Highly Restricted for a
  given course, the read tools that return it (`get_solution`,
  `get_validation_result`, `preview_personalization`) are the controlled set to
  gate or disable via `MCP_MODE=read_only` plus selective tool exposure.

## Addendum (2026-07): admin diagnostic surface data types

The read-only admin diagnostic surface (`/admin-mcp`, 19 tools — see
`tool-inventory.md` addendum and `mcp-student-data-audit-2026-07.md`) adds
these outbound data types. Consent for this surface requires the admin role.

| # | Data type | Source / tool | Provisional class | Rationale |
|---|-----------|---------------|-------------------|-----------|
| 12 | **Operational aggregates** (queue depth, job/status counts, latency percentiles, utilization series, distinct-user counts, storage bytes) | metrics/queue/storage/series tools | **Confidential** | Deployment-operational numbers; no identity, no content. Small-cell inference is the recorded residual (audit F-5). |
| 13 | **Runner fleet & deploy state** (runner ids/hostnames/capabilities, deploy versions/events) | `list_runners`, `get_runner_detail`, deploy tools | **Confidential** | Infrastructure topology and CD state; operationally sensitive, no personal information. |
| 14 | **Warning+ log events & browser-error reports** (level, label, message, redacted metadata; error message/stack, coarse browser label) | `query_logs`, `get_browser_diagnostics` | **Confidential** | Infrastructure free text. Student identifiers are excluded by capture-side redaction plus the write-side hygiene convention (audit F-1, pinned by `LogMessageHygieneTests`); browser samples carry the coarse browser/OS label, never the raw User-Agent (F-4). |
| 15 | **Audit-log aggregate counts** (totals by action/category) | `query_audit_log` | **Confidential** | Counts only, by construction — no row, actor, IP, or metadata is ever loaded. |
| 16 | **Grade-sync health** (status counts; error samples: sanitized detail, assignment, org unit) | `get_brightspace_sync_status`, `get_health_alerts` | **Confidential** | Student username, grade (points), and user id columns are omitted; the `detail` string is sanitized at write to exclude the pushed grade, orgDefinedId, and untruncated D2L bodies (audit F-2). |
| 17 | **MCP grant metadata** (agent name, scopes, owner username, timestamps) | `list_connected_agents` | **Confidential** | The owner is the authorizing staff/admin account (consent-gated — never a student); employee-identity metadata for audit/attribution, no token material. |

No admin-surface data type carries student personal information; row 17 is the
only personal information at all (the authorizing staff member's username).
