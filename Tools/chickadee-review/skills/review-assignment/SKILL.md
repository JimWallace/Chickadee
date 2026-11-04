---
name: review-assignment
description: >
  Review one Chickadee assignment before students see it. Runs the server's
  rule-based checks, then the reviewers the assignment needs, in parallel,
  and returns one report with the disagreements shown. Use when an
  instructor asks to review, check or proofread an assignment, or to compare
  one week against earlier weeks. Changes nothing unless the instructor
  approves a specific fix.
---

# Reviewing a Chickadee assignment

You coordinate a review of one assignment. The checks and the reviewers
report; the instructor decides. You change content only after the
instructor approves a specific finding, and you say before each change what
it triggers.

In this skill, `<tool>` means the plugin server's tool
`mcp__plugin_chickadee-review_chickadee__<tool>`. The server's name, for
`ReadMcpResourceTool`, is `plugin:chickadee-review:chickadee`.

## Rules

- **No student data.** Use only the tools this skill names. Never call
  `list_reflections`, `get_reflections`, `draft_feedback` or any other
  `feedback` tool in this review, even if the instructor asks: say that a
  review reads authoring content only, and that feedback is a separate task.
- **No unapproved change.** Never edit content, start or wait on validation,
  re-grade, open or close an assignment except as step 7 allows.
- **Only these reviewers.** Start a reviewer only by the names in step 3.
  Never give a reviewer's task to `general-purpose` or to any agent that has
  no fixed tool list: such an agent can reach student data.
- **Secret tests stay secret.** No text meant for students, including a fix
  you apply to the notebook, may contain secret-tier test source, a secret
  test's name or a hidden expected value.
- Prose you write in a fix follows the course's voice guide.

## 0. Is the server connected?

If the `<tool>` names above are missing, stop and tell the instructor:

- If `/mcp` lists `plugin:chickadee-review:chickadee`, sign in to it there.
- If `/mcp` does not list it, the server URL is unset or was not
  substituted. Set it with `/plugin configure chickadee-review@chickadee`,
  then restart Claude Code. Say that this is one of the points the plugin's
  runbook marks as not yet confirmed.

## 1. Find the assignment and the comparison range

- Resolve the course with `list_courses`. If two courses share the code,
  ask which term.
- Resolve the assignment with `list_assignments`. If two match, ask.
- Get the order with `list_course_sections` and `list_assignments`. A
  "week" is a course section. If the course has no sections, a week is a
  position in `list_assignments`. An assignment in no section is placed by
  its position in `list_assignments`.
- Resolve the comparison range ("weeks 1 to 5") to a list of assignment
  public IDs now. Without a range, use every assignment before this one.
  Reviewers receive the IDs, never the phrase.

## 2. Run the checks

Call `check_assignment` with the assignment's public ID.

- If `warnings` is not empty, record which parts could not be read: the
  checks that need them found nothing, so an empty result there is not a
  pass.
- Call `get_validation_result`. If it has no `ranAt`, or its status is
  pending, record that the run-based checks may be stale. Otherwise record
  `ranAt`, so the instructor can judge whether it predates the last edit.
  Suggest `run_validation` if the content changed since; do not start it.

## 3. Prepare the reviewers

| Reviewer (`subagent_type`) | Run it when | Gets the check findings |
|---|---|---|
| `chickadee-review:voice` | Always | Yes |
| `chickadee-review:assessment-alignment` | Always | Yes |
| `chickadee-review:student-perspective` | Always | **No** |
| `chickadee-review:personalization` | `get_global_inputs` lists an input | Yes |
| `chickadee-review:curriculum-fit` | The comparison range is not empty | No |
| `chickadee-review:consistency` | The comparison range is not empty | No |

The student-perspective reviewer has no access to the tests, on purpose.
The check findings name tests, so it never receives them.

Before you start them:

- **Voice guide.** Read `chickadee://course/<courseCode>/authoring-guidance`
  with `ReadMcpResourceTool` on `plugin:chickadee-review:chickadee`. If the
  read fails, tell the instructor and do not run the voice reviewer: never
  substitute another guide. List it under "Not covered".
- **Course outline.** Use `list_content_items` to look for the outline. Its
  text must be in an item's `description`. If the outline is only a link or
  an attachment, ask the instructor to paste its text, or run the
  curriculum reviewer without it and say so. Pass the text itself.
- **Prior material**, for student-perspective only: a short list of what
  earlier assignments covered, from their titles and concept tags.

## 4. Run them in parallel

Start every chosen reviewer in one message, one Agent call each, with
`subagent_type` exactly as in the table. Keep each call's agent ID for step 5.
Each prompt states:

- the course code and the assignment's public ID;
- the comparison range as a list of public IDs, where the reviewer uses one;
- the check findings as JSON with the line "Do not repeat these.", only
  where the table says so;
- the voice guide text (voice), the outline text (curriculum-fit), or the
  prior-material list (student-perspective).

If the Agent tool rejects a scoped name, try the bare name (`voice`) once.
If that fails too, do not run that reviewer: list it under "Not covered"
with the error.

Each reviewer replies with one fenced `json` block holding an array of
findings, then a line that starts with `Read:`. A reply with no parseable
array is a failed reviewer: list it under "Not covered" with its reply. It
is never the same as `[]`.

## 5. Settle overlaps

Two findings **match** when their `location` kind and reference are the same
and they describe the same defect. Two `assignment`-level findings match only
on the same defect.

- Drop a reviewer finding that matches a check finding.
- Where two reviewers' findings match and agree, keep the clearer one and
  note that both found it.
- Where they conflict (one asks for more detail, the other for less),
  continue each of the two reviewers once with `SendMessage`, using its
  agent ID, with the other's finding and "Reply with your finding kept,
  revised, or withdrawn, in the same format." If you cannot continue a
  reviewer, keep both findings. If they still conflict, keep both and mark
  them as a disagreement.

## 6. Report

1. One line: the assignment, the reviewers that ran, the validation run's
   `ranAt` (or "no run"), and the counts by severity.
2. **Check findings**, then 3. **Reviewer findings**. Each sorted most
   severe first, then by location in notebook and suite order. For each
   finding: its number, severity, location in words ("cell 4",
   "test `test_mean.py`", "input `limit`"), message, suggested fix, and
   source (the check ID or the reviewer).
4. **Disagreements**, each pair side by side, with no ruling from you.
5. **Not covered**: reviewers not run and why, failed reviewers, parts that
   could not be read, stale runs, and each reviewer's `Read:` line where it
   says the reviewer did not finish.

Number findings with one running count across sections 2 to 4. The two
sides of a disagreement are 12a and 12b. A finding that needs a change in a
different assignment is listed, but marked "not applied in this review".

## 7. Apply approved fixes

Only for findings the instructor names by number.

1. **Before each change, ask for a yes**, naming what it triggers:
   - `update_suite`, `move_suite_item`, `delete_suite_item`,
     `create_pattern_family`, `update_pattern_family`,
     `author_notebook_check`, `author_script`, `delete_support_file`,
     `update_notebook`, `update_solution` and `restore_assignment_version`
     re-run validation and **close the assignment if it is open** (a
     `preview` assignment stays in preview). A suite change also re-grades
     every existing submission.
   - Treat any other write tool the same way unless its description says it
     neither closes nor re-grades.
2. Make the change. If the tool is refused for scope, stop and tell the
   instructor to sign in again through `/mcp` and approve `content:write`.
3. If the result says `assignmentClosed`, tell the instructor that the
   assignment is now closed and that reopening is their decision, after
   validation passes.
4. Call `validate_assignment`. It only waits on the run the edit already
   queued; it starts nothing. Report its status.
5. When every change is made, call `check_assignment` again. If validation
   has not finished, say so, and report changes only for checks that do not
   read a run (`manifest.incoherent`, `placeholders.unresolved`,
   `tiers.noPublicTest`, `points.zeroPoints`).
