# MCP Data-Flow & Egress Inventory

Audit scope: `Sources/APIServer/MCP/`. Base snapshot at `VERSION` 0.4.435;
**refreshed 2026-07 at `VERSION` 0.4.667**. The per-tool flows below remain
accurate for the base catalog; the tools added since, the second (admin
diagnostic) surface's read paths, and the upstream-writer sweep of the
diagnostic stores are covered by `mcp-student-data-audit-2026-07.md` (§2.2 for
the admin source→fields table, §3 for the free-text findings and their
remediations) and the `tool-inventory.md` addenda. One flow-relevant note
from that refresh: `SupportFileURLFetcher` (instructor-supplied support-file
URLs) is an MCP-tree outbound HTTP call added since the base snapshot —
SSRF-guarded (blocked-address classifier), redirects disallowed, and it
fetches instructor content only.

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
| `list_courses` | enrolments, courses | course codes, names, terms and course keys (enrolled only) | No | Confidential |
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
| `get_validation_result` | validation submission + its result; `validation_variants` batch | per-test outcomes; per-variant verdicts + synthetic seeds + failing outcomes (all reference-solution runs); **`submissionID`/`userID` dropped** (`GetValidationResultTool.swift:18-24`) | No (instructor reference run; variant seeds are derived constants, not student seeds) | Restricted |
| `update_assignment` | assignment | echo of saved metadata | No | Confidential |
| `set_grading_mode` | assignment, setup | echo of mode | No | Confidential |
| `set_activity` | assignment, setup | echo of the activity block | No | Confidential |
| `run_tournament` | assignment, setup, enrollments, submissions (ids only) | run id, schedule, entrant and round counts, status — no student identifier | No | Confidential |
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

Every result above that names a course also returns the course key and term
(`courseKey`, `courseTerm`). These are course metadata, the same values that
`list_courses` returns. They contain no student data.

## LTI 1.3 flows (2026-09)

LTI is a second inbound source of student identity and a second outbound
grade transport beside Valence (`docs/lti-1-3.md`). It is not part of the
MCP surface; it is listed here because the LTI design note requires the
launch claims, AGS and NRPS to be in this inventory before a production
registration. Direction is relative to Chickadee.

| Flow | Direction | Data that crosses | What Chickadee stores | Student PII? | Classification |
|------|-----------|-------------------|-----------------------|--------------|----------------|
| Login (`POST /lti/login`) | LMS → Chickadee | issuer, client ID, `login_hint`, `lti_message_hint`, `target_link_uri` | `lti_login_states`: a SHA-256 of the `state` value, the nonce, the platform ID, a 5-minute expiry; reaped hourly | `login_hint` is an opaque LMS value and is not stored | Confidential |
| Launch (`POST /lti/launch`) | LMS → Chickadee, as a signed `id_token` verified against the platform's JWKS | subject, name, email, roles, deployment ID, context (ID, label, title), resource link, `custom` (`assignment`, optionally `username`), the AGS and NRPS endpoint claims | `lti_identities`: (platform, subject) → account. A created account carries the username (an opaque `lti-` hash, or the trusted `username` custom parameter), the display name and the email from the claims. The course records `lti_context_id`, `lti_line_items_url` and `lti_memberships_url`. Roles are mapped to the course role and not stored | **Yes** (name, email, LMS subject) | Restricted |
| Deep Linking (`/lti/deep-link`) | LMS → Chickadee (request), Chickadee → LMS (signed response) | request: the launch claims above plus the return URL and `data`; response: the chosen assignments' titles, launch URLs and `custom.assignment` | `lti_deep_link_requests`: a SHA-256 of the picker ticket, platform, course, the staff account, return URL, `data`, a 30-minute expiry; reaped hourly | No (instructor content) | Confidential |
| Grades through AGS | Chickadee → LMS, authenticated by a client-credentials JWT signed with `.lti-tool-key` | line item: `resourceId` (assignment public ID), label (title), `scoreMaximum`; score: the student's LMS subject, `scoreGiven`, `scoreMaximum`, activity and grading progress, timestamp | `lti_grade_syncs`: (student, test setup), pending flag, last synced time, last failure sentence. No grade is stored on the row; the sweep computes it when it sends. `assignments.lti_line_item_url` | The LMS subject and the grade | Restricted |
| Roster through NRPS | LMS → Chickadee, same client-credentials token | membership: each member's LMS subject, roles, name, email, `lis_person_sourcedid` (student number when the platform sends it) | The membership is read per "Check against LEARN" request or "Link students" action, and then discarded. "Link students" stores one `lti_identities` row (platform, subject → account) for each course student whose Chickadee student number matches exactly one LMS learner; nothing else from the membership is kept | **Yes**, in transit only | Restricted |

The platform registration itself (`lti_platforms`: issuer, client ID,
deployment IDs, the platform's auth, token and JWKS URLs, an optional token
audience) is operator configuration and holds no personal data.

## GitHub flows (2026-10)

GitHub submission (`docs/github-submissions.md`) adds GitHub as a second
source of submission content beside the upload form, and as a place a
public-tier result can be posted. It is not part of the MCP surface; it is
listed here because the design note's privacy review (its slice 0) requires
every item that crosses to be in this inventory, and its "What reaches
GitHub" table is the authoritative per-item list. Direction is relative to
Chickadee. Every flow is off until an admin registers an App, and every
student flow needs the student's own click.

| Flow | Direction | Data that crosses | What Chickadee stores | Student PII? | Classification |
|------|-----------|-------------------|-----------------------|--------------|----------------|
| App registration (`/admin/github`, the manifest flow) | Chickadee → GitHub, then GitHub → Chickadee | out: the deployment's base URL, callback URLs, App name and permissions; in: the App ID, client ID, client secret, private key, webhook secret | `github_apps`: the IDs and the public facts; the secrets in the 0600 `.github-app-secrets` file | No | Confidential |
| Account link (`/github/link`, OAuth with PKCE) | Chickadee → GitHub (the authorization), GitHub → Chickadee (the user) | out: that a Chickadee user authorizes the App; in: the user's GitHub ID and login | `github_account_links`: (user, GitHub ID, login). The user token is revoked at once and never stored | The GitHub login, chosen by the student | Confidential |
| Submit a commit (`/github/submit`) | GitHub → Chickadee | the repository and branch names, the head commit's SHA and message, the commit's files as a tarball | The files as the submission zip; the repository ID, `owner/name` and the SHA on the submission row. Names and messages are read for the page and not stored | No (the student's own repository) | Confidential |
| Course repositories (`/instructor/github`, `Make my repository`) | Chickadee → GitHub | an instructor's authorization and organization role (read once); a repository named `{assignment-slug}-{github-login}` in the course organization, the template's files, an invitation to the student's login; the archived state at term end | `github_course_organizations`: organization ID, login, installation ID; `github_assignment_templates`; `github_course_repositories`: repository ID, `owner/name`, whether the invitation succeeded | **Yes**: the student's GitHub login, in the repository name, visible to the organization's owners and members with access | Confidential |
| Push webhook (`POST /github/webhook`, verified by `X-Hub-Signature-256`) | GitHub → Chickadee | the repository ID and head SHA; commit messages, author and committer names and emails, and the pusher's login and email arrive and are **discarded** | The time and the SHA on the course-repository row. Nothing is graded from a push | **Yes**, in transit only | Restricted |
| Commit status (opt-in per assignment, private repositories only) | Chickadee → GitHub | "n/m public tests passed", "No public tests" or "Build failed", a success or failure state, the context `chickadee/{assignment-slug}`, a link to the results page | Nothing new | The public-tier count the student already sees | Confidential |

No GitHub flow sends a grade, a release- or secret-tier result, a Chickadee
username, a name, an email address or a student number to GitHub. The
outbound hosts are `api.github.com` and `github.com`; the one inbound
endpoint is `/github/webhook`.

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
