# Reviewing an assignment with Claude Code

The `chickadee-review` Claude Code plugin reviews one assignment before
students see it. It runs the server's rule-based checks first, then a group of
read-only reviewer agents, each with one task, and gives the instructor one
report. The instructor decides what to change. This is Phase 0 of #2747; the
design and the later phases are in the issue.

## What runs

1. **`check_assignment`** (MCP, on the server). Rule-based checks over the
   stored content and the latest validation runs. The same content always gives
   the same findings. The checks are in
   `Sources/APIServer/Utilities/AuthoringChecks/`.
2. **The reviewers** (Claude Code subagents, on the instructor's machine).
   Each reads authoring content through read-only MCP tools and reports
   findings in the same format as `check_assignment`, with `source: "reviewer"`.

| Reviewer | Model | Judges |
|---|---|---|
| `voice` | Haiku | Tone, clarity and ambiguity, against the course's voice guide |
| `assessment-alignment` | Sonnet | Whether the tests check what the prose asks for |
| `student-perspective` | Haiku | The starter notebook read without the solution or the tests |
| `personalization` | Haiku | Whether every seed gets an equally hard task (only with per-student inputs) |
| `curriculum-fit` | Sonnet | Concepts used before they are taught; the course outline |
| `consistency` | Sonnet | Terms, names, layout and difficulty against earlier weeks |

The `review-assignment` skill coordinates: it chooses the reviewers the
assignment needs, runs them in parallel, settles overlapping findings, and
writes the report.

## What it can and cannot do

- **No student data.** Each reviewer's `tools` list names only content-read
  tools. None of them can read a submission, a grade or a written answer.
- **No change without approval.** The reviewers have no write tool. The
  coordinator changes content only for a finding the instructor names, and
  first says what the change triggers: an edit to the suite or the notebook
  re-runs validation and closes an open assignment.
- **Stale runs.** `check_assignment` reads the latest stored validation runs.
  Run validation after an edit before you review.

## Install

The plugin lives in this repository (`Tools/chickadee-review/`), and the
repository is its marketplace (`.claude-plugin/marketplace.json`). In Claude
Code, run:

```text
/plugin install chickadee-review --marketplace JimWallace/Chickadee
```

That one-step form needs Claude Code 2.1.275 or later. On an earlier
version, add the marketplace first and then install from it:

```text
/plugin marketplace add JimWallace/Chickadee
```

```text
/plugin install chickadee-review@chickadee
```

Claude Code then asks for the plugin's one setting, the Chickadee MCP URL:
your server's address followed by `/mcp`. To change it later, run:

```text
/plugin configure chickadee-review@chickadee
```

Then run `/mcp`, choose `plugin:chickadee-review:chickadee`, and sign in. The
browser opens Chickadee's consent screen. Approve `content:read`. Approve
`content:write` only if you want the coordinator to apply fixes you approve.

## Run a review

Ask in plain words, or call the skill:

```text
/chickadee-review:review-assignment Review week 6 of CS246 against weeks 1 to 5
```

The report opens with a summary line, then lists the check findings, the
reviewer findings, the disagreements between reviewers, and what was not
covered. Findings are numbered, so you can answer "apply 3 and 7".

## Not yet confirmed

The Claude Code documentation does not settle three points. The first pilot
must confirm each one, and fix the plugin if one fails:

1. That `${user_config.chickadee_url}` is substituted in the `url` of the
   plugin's `.mcp.json`. The documentation shows it in `headers`.
2. That the plugin's own server signs in through the same OAuth flow as a
   server added with `claude mcp add`, and that the deployment's MCP client
   allowlist admits it the same way.
3. That the coordinator can start a plugin agent with its scoped name, for
   example `chickadee-review:voice`, as the Agent tool's `subagent_type`.

`claude plugin validate --strict .` passes for the marketplace and the plugin.
Validation checks the files, not these three runtime points.

## Pilot log

Phase 0 exists to learn what the reviewers find and what a rule could have
found instead. After each pilot review, add a row:

| Date | Assignment | Reviewers | Findings (check / reviewer) | Accepted | A rule could have found | Cost |
|---|---|---|---|---|---|---|

Each finding in the "a rule could have found" column is a candidate check for
`AuthoringCheckCatalog` (#2747, step 5). Once a check covers it, remove that
item from the reviewer's instructions in `Tools/chickadee-review/agents/`.

## Changing the plugin

- A reviewer's tools are the plugin server's tools, named
  `mcp__plugin_chickadee-review_chickadee__<tool>`. Give a reviewer only
  read tools. A new MCP read tool reaches a reviewer only when its `tools`
  list names it.
- The finding format is `AuthoringFinding` (`Sources/Core/Models/`). Every
  reviewer's output block must match it.
- Run `claude plugin validate --strict .` from the repository root after
  each change, and bump `version` in `Tools/chickadee-review/.claude-plugin/plugin.json`
  so installed copies update.
