# MCP read access to validation runs (planned)

**Status:** planned feature, not yet implemented. Captured here so the design
is settled before we build it.

## Motivation

An MCP agent can already author content and *trigger* validation
(`update_solution`, `update_suite`, `validate_assignment`), but it can only learn
the **outcome** of a validation run as a single word: `passed` / `failed` /
`no-runner`. When a validation fails, the agent can't see *which* test failed or
*why* — so diagnosing (e.g. "Q3's answer key reports `fortuneShift` undefined")
requires a human to copy the per-test result out of the web UI.

Giving the agent read access to **validation-run results** closes that loop, so
it can diagnose and fix a failing suite on the instructor's behalf without a
human relaying the grid.

## Hard guardrails

This is **validation runs only** — never student data. Concretely:

- **Scope:** `content:read`.
- **Only `kind == .validation` submissions.** The tool must refuse anything
  `kind == .student`. It never accepts a raw submission id; it resolves the
  validation submission from the assignment.
- **Authorization:** same course-scoping as every other content tool — the
  account must be enrolled in the course that owns the assignment (admin = all).
- **No student identities, no student submissions, no grades, no rosters.** The
  response carries only the instructor's own reference-solution run.

Validation submissions are instructor-authored (the reference solution graded
against the suite), so this is the same trust tier the agent already reads via
`get_solution` / `get_suite` — no new data class is exposed.

## Proposed surface

`get_validation_result(assignmentPublicID)` → the latest validation run for the
assignment:

```jsonc
{
  "assignmentPublicID": "G9mx8H",
  "validationStatus": "failed",          // passed | failed | no-runner | pending
  "ranAt": "2026-06-09T15:49:14Z",
  "buildStatus": "passed",               // passed | failed
  "compilerOutput": null,
  "outcomes": [
    { "testName": "fortune key defined", "tier": "public",
      "status": "fail",
      "shortResult": "These variables are not defined yet: fortuneShift, fortuneBlockSize.",
      "longResult": "…" },
    { "testName": "Decoded fortune matches", "tier": "secret",
      "status": "skip-equivalent", "shortResult": "Skipped: prerequisite … did not pass" }
  ],
  "counts": { "total": 10, "pass": 8, "fail": 1, "error": 0, "timeout": 0 }
}
```

Optionally, later: `list_validation_runs(assignmentPublicID)` → recent attempts
(`{ ranAt, validationStatus, pass/total }`) for trend/debugging.

## Implementation sketch

- Resolve the assignment with the existing `authorizedAssignment` /
  `authorizedAssignmentAndSetup` helper (course-scoped auth, no new path).
- Resolve the validation submission: prefer `assignment.validationSubmissionID`,
  else the most recent `kind == .validation` submission for the setup — exactly
  the resolver `loadExistingSolution` already uses, **filtered to
  `kind == .validation`**.
- Load its `APIResult` (`collectionJSON` → `TestOutcomeCollection`), decode, and
  map to a DTO that includes per-test outcomes + counts and **excludes any user
  field** (`submissionID`/`userID` are dropped from the DTO).
- Return all tiers (public/release/secret/student): validation is instructor
  content, and the agent needs the secret-tier outcomes to debug the suite.
- A `pending` / missing-result state returns `validationStatus` with empty
  `outcomes` (mirrors `validate_assignment`).

## Open questions

- **Personalized expected values.** A failing pattern-family case's resolved
  per-student `expected` (from `_ck_inputs`) could appear in `longResult`. That's
  solution-derived, but it's the *instructor's own* assignment that the agent
  already authors — so surfacing it to the authorized instructor account is fine.
  Worth a conscious confirm when implementing.
- **`get_suite` overlap.** `get_suite` already returns the suite definition; this
  tool is strictly the *run outcome*. Keep them separate.
- Whether to fold `list_validation_runs` in now or defer until there's a need.

## Catalog/doc sync reminder

When implemented, update the two agent-facing copies that must stay in lockstep
with the tool catalog (per the MCP design notes in `CLAUDE.md`): the tool's
`description`/`inputSchema`, and `MCPServerInstructions.text` (the `initialize`
handshake), plus the human index in `docs/mcp-authoring-roadmap.md`.
