# AI-Assisted Feedback on Written Reasoning

Design note for a feature that lets an instructor use their own AI agent to
draft feedback on a student's written reasoning. The agent connects through the
MCP server. A person on the course staff reviews each draft before a student
sees it.

The feature is for small, formative activities. It is not for major
assignments, and it does not change a grade.

## Status

| slice | what | state |
|---|---|---|
| 0 | This design note | in review |
| 1 | Opt-in flags (course: admin; assignment: instructor), the `feedback:*` scopes, the three MCP tools, the staff review page, the student view, the compliance updates | planned |
| 2 | A stored rubric per assignment, served to the agent with the reflections | not started |
| 3 | A student opt-out, if the Information Steward requires one | not started |

## The problem

An autograder checks answers that a program can verify. In data science, much
of what an instructor wants to assess is the decision and the reasoning behind
it: why a student dropped a set of outliers, why they chose a median and not a
mean, what a plot does and does not show. No test script can grade that text.

An instructor in the School of Public Health Sciences asked whether an LLM can
evaluate this reasoning, "as long as this is a small portion of activities
rather than major assignments", for example as student self-evaluation on
small-grade activities.

## The policy position (2026-10)

The University of Waterloo IST page
[AI tools](https://uwaterloo.ca/information-systems-technology/about/policies-standards-and-guidelines/artificial-intelligence-ai/responsible-use-ai-tools-university-data/ai-tools)
lists these facts:

- **Anthropic Claude (UW login)** is "Approved for University data up to and
  including Restricted when using the UW-provided account". It needs a paid
  licence, for faculty and staff only.
- **Claude with a personal account** is approved for public data only.
- **Highly Restricted** data "must not be used with any AI tool unless that
  specific use has received explicit, documented approval" from the
  Information Steward.

The page does not mention grading, assessment, student work, or the Claude
API. These are open questions for IST (see **Open questions**).

## Options considered

| | Option | Data to a model provider | Server calls a model | Approval status |
|---|---|---|---|---|
| A | Student self-assessment against a rubric. No AI. | None | No | Needs no approval |
| B | **The instructor's own agent drafts feedback through MCP. Staff review it.** | Pseudonymous reflection text, through the instructor's UW Claude account | No | Covered by the "Approved up to Restricted" row, if student work is Restricted |
| C | The server calls a model API and grades each submission | Reflection text, through a server-held API key | Yes | Not covered. The Claude API is not on the IST page. |

**Chosen: B.** Option C reverses the strongest claim in the compliance
package: "Chickadee is not the AI tool" (`compliance/uw-ai-approval-readiness.md`
§0). It also needs a model API host in `deploy/egress-allowlist.md`, which that
file says must never appear, and a stored API key. Option B keeps the server
free of model egress. The AI tool stays the instructor's own approved account.
Option A remains a good choice for a course that does not want AI involved,
and it needs no code.

## Design

### Two opt-in gates, both set by a person

1. **Course gate: `courses.ai_feedback_enabled`.** Only a deployment admin can
   set it, on the admin course page. This is the "limited-use, unit-level
   approval" step from `compliance/uw-ai-approval-readiness.md` §4: the admin
   turns it on for a pilot course after the approval exists.
2. **Assignment gate: `assignments.ai_feedback_enabled`.** A course instructor
   sets it on the assignment edit page. The page refuses it unless the course
   gate is on.

**No MCP tool can set either gate.** An agent can never widen its own reach to
student work. `MCPAIFeedbackGateTests` pins this.

### What a student writes, and what the agent reads

The instructor marks each reasoning cell in the starter notebook with the
Jupyter cell tag `reflection`. JupyterLite keeps cell metadata, so the tag
stays on the cell when the student fills it in.

For each tagged cell, the agent receives:

- **`prompt`**: the text of the nearest markdown cell before the tagged cell,
  read from the **starter** notebook. A student cannot change it.
- **`response`**: the text of the tagged cell, read from the student's latest
  submission.

The agent does not receive the student's code, outputs, test results, grade,
name, username, student number or email. It does not receive the reference
solution through these tools.

### Pseudonymous handles

The agent identifies each student by a **feedback handle**, for example
`R-7Q2M4K`. The server makes the handle at random the first time it lists the
student for that assignment, and stores it on the `reflection_feedback` row.

- A handle is per (student, assignment). The agent cannot link one student
  across two assignments.
- A handle is not the per-course avatar handle (`docs/student-avatars.md`).
  Classmates can see that one.
- Only the staff review page maps a handle back to a student.

### The MCP tools

All three are on the content surface. Each one refuses an assignment whose
two gates are not both on, with the same answer as an unknown assignment.

| Tool | Scope | Course role | Does |
|---|---|---|---|
| `list_reflections` | `feedback:read` | TA+ | Lists each student's handle, the submission time, whether the submission has tagged cells, and the feedback state (`none`, `draft`, `released`, `stale`). |
| `get_reflections` | `feedback:read` | TA+ | Returns the prompt and response pairs for one handle. |
| `draft_feedback` | `feedback:write` | TA+ | Saves draft feedback text (at most 4,000 characters) for one handle. It never releases. It refuses to replace released feedback. |

`feedback:read` and `feedback:write` are separate from `content:read` and
`content:write`, so a grant shows the reach in its scope list. `MCP_MODE`
applies the same ceiling: `read_only` grants `feedback:read` and never
`feedback:write`.

### The person in the loop

The staff review page, `/instructor/:assignmentID/feedback`, lists each draft
with the student's name, their reflections and the draft text. A TA or
instructor edits the text and then selects **Release** or **Discard**. Only a
released row is visible to the student.

If the student submits again after the draft was written, the row becomes
`stale`. The page shows this, and the agent sees it in `list_reflections`.

### What the student sees

- **Before submitting:** when the assignment gate is on, the assignment page
  shows one sentence: course staff can use an AI tool to help draft feedback
  on written answers, staff review all of it, and the student's name is not
  sent. It links to this document's student-facing summary.
- **After release:** the results page shows the feedback under the heading
  **Feedback on your written answers**, with the label "Drafted with AI
  assistance and reviewed by course staff".

The feedback has no score field. It does not change `earnedPoints`, BrightSpace
or LTI grade sync. An instructor who wants a mark for the reflection keeps
using a normal test (for example a check that the cell is not empty) or enters
it by hand.

### Storage

Table `reflection_feedback`:

| column | note |
|---|---|
| `id` | UUID |
| `assignment_id` | cascade delete with the assignment |
| `user_id` | cascade delete with the user; never returned by an MCP tool |
| `handle` | random, unique per assignment |
| `submission_id` | the submission the draft was written against |
| `draft_text` | nullable |
| `state` | `none`, `draft`, `released`, `discarded` |
| `drafted_at`, `drafted_by_client` | the OAuth client name, for attribution |
| `reviewed_by_user_id`, `released_at` | set by the staff review page |

### The student-data wall

The MCP surface was built and audited on the claim that it never exposes
student data (`compliance/mcp-student-data-audit-2026-07.md`). This feature
makes a narrow, gated exception. The controls are:

1. **One chokepoint in code.** Student submissions are reached only through
   `MCPStudentDataBoundary`. The new accessors there filter on both gates.
   `MCPStudentDataWallTests` keeps scanning every other tool file.
2. **One chokepoint in the database.** `deploy/sql/mcp-least-privilege-role.sql`
   adds a second row-level-security policy on `submissions`. It admits a
   `student` row only when its assignment and course gates are both on. With
   the dedicated `chickadee_mcp` pool, a bug in the code still cannot reach a
   student row outside a gated assignment.
3. **Payload minimisation.** The tools return reflection text and handles, and
   nothing else.
4. **Audit.** Every MCP call already writes a fail-closed audit row.

### Residual risk to record

Chickadee cannot verify **which** AI account the instructor connects. OAuth
consent identifies the Chickadee user, not the agent's licence. A personal
Claude account is approved for public data only. "Use the UW-licensed account"
is therefore an instructor attestation, not a technical control. The admin
course gate is the place to collect that attestation.

## Open questions for IST and the Information Steward

Ask these before the admin course gate is turned on in production:

1. Does Policy 46 classify a student's written answer as Restricted? If it is
   Highly Restricted, this use needs explicit approval from the Information
   Steward.
2. May an instructor use their UW-licensed Claude account, through a connector
   to a UW-hosted system, to read pseudonymous student written work and draft
   formative feedback?
3. Must students be able to opt out? (Slice 3.)
4. Which academic-integrity or course-outline disclosure is required for AI use
   in feedback?

**Keep course content away from Highly Restricted data.** In a health course,
use synthetic or public datasets, and do not ask students to write about real
patients or their own health. A reflection on real patient data can be Highly
Restricted, whatever the design does.

## Compliance documents this changes

The PR that ships slice 1 updates, in the same change:

- `compliance/mcp-student-data-audit-2026-07.md`: an addendum for the gated
  exception.
- `compliance/policy46-classification.md`: a row for reflection text.
- `compliance/data-flow-inventory.md` and `compliance/tool-inventory.md`: the
  three tools.
- `compliance/trust-boundary.md` and `compliance/uw-ai-approval-readiness.md`:
  the gates, and a revalidation trigger.
- `deploy/sql/mcp-least-privilege-role.sql`: the RLS policy and the new table.

`deploy/egress-allowlist.md` does not change. The server still calls no model.
