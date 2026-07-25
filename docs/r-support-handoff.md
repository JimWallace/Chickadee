# Handoff: first-class R support (HLTH 230 → R)

Written 2026-07-25. Repo `JimWallace/Chickadee`, branch
`claude/hlth230-assignments-r-conversion-waxnqw`, server at v0.4.640.

## Goal

Chickadee supports assignments authored and graded in **R** as well as Python,
including per-student personalization, **transparently to instructors** — an R
instructor should never have to think about Python underneath. Design and
rationale: [`docs/r-support.md`](r-support.md). This file is only the
*remaining work* plus the traps that will cost you hours if you don't know them.

## State: done and verified

The engine is complete and merged (v0.4.635–v0.4.640). All five HLTH 230
assignments are converted to R in course **TEST** and **validate green**:

| Assignment | Public ID | Notes |
|---|---|---|
| A0 warm-up | `DEJr2f` | hand-written R tests |
| A1 BMI | `FpY4wz` | pattern families |
| A2 DNA/k-mers | `OImnr8` | per-student expressions, `{{name}}` substitution |
| A3 health records | `PKPkxL` | 4 pattern families with per-student `expectedVarRef`, `dbgen.R` |
| A4 VitalDB EDA | `I4nUW0` | 6 notebook checks; **6/6 pass** as of 19:46Z |

Notebook checks render in R for **every kind but `ast_structure`**.

## Task 1 — drive PR #1211 to merge (only open item)

[#1211](https://github.com/JimWallace/Chickadee/pull/1211) fixes every escape in
the R runtime's JSON result formatter (`.chickadee_json_str`). It was open and
in CI at handoff time.

```
gh-equivalent: mcp__github__pull_request_read  method=get  pullNumber=1211
```

If CI is green: mark it ready (`update_pull_request draft=false`), squash-merge,
**wait for the `chore(release)` commit on main**, then reset the branch (see
Trap 2). If red: diagnose and push a fix — do not leave it red.

## Task 2 — apply minimum-runner-version gates (blocked on a client reconnect)

v0.4.640 added the MCP tool `set_minimum_runner_version` (#1210). It gates a
submission to a runner at or above a given version; a job that doesn't qualify
**stays queued** rather than being graded by a too-old runner.

**It is not callable from the session that wrote this** — the server has it, but
the MCP tool catalog is fixed for the life of a client connection, so it needs
the Chickadee connector reconnected (or a fresh session). Verify with:

```
ToolSearch  "select:mcp__Chickadee__set_minimum_runner_version"
```

Once it resolves, apply:

| Assignment | Gate | Why |
|---|---|---|
| `DEJr2f`, `FpY4wz`, `OImnr8`, `PKPkxL` | `0.4.635` | `chickadee_load_student` |
| `I4nUW0` | `0.4.639` | `chickadee_student_cells` |

All five are green today, so correct gates change nothing. If one starts
**queueing**, that is the gate catching an old runner before it produces a
misleading red — not a regression.

## Task 3 — backlog (found this session, none started)

Ordered by value. None is blocking.

1. **Runner version-skew alert.** Runners already advertise `runnerVersion` on
   every poll and nothing compares it to the server's. A mixed fleet cost most
   of a session and produced three wrong conclusions before it was diagnosed;
   the failure mode is silent *and* intermittent. A health alert when a runner
   falls behind is the single highest-value item here.
2. **The recorded manifest language is a one-way door.** `TestProperties.language`
   outranks every other signal, so cloning a Python assignment and converting it
   to R leaves it rendering `.py` forever — the workaround is saving one
   throwaway `.R` script (see Trap 6). The principled fix: the recorded language
   is a *memo* of what was resolved, not a declaration, so replacing the starter
   notebook should re-derive it. Sibling of the bug fixed in #1208.
3. **`cell_contains` regex validator counts parens naively.**
   `NotebookCheckKindHandler.swift` compares raw `(` and `)` character counts, so
   `\(` or `[(]` is rejected as "unbalanced". Affects Python authors identically.
4. **Check `variable` is validated as a *Python* identifier**
   (`validateRequiredIdentifier`), so an idiomatic R name like `my.df` is refused
   on an R assignment. The handler's `validate` has no language in scope; thread
   one through.
5. **`ast_structure` in R.** A design question, not a port: `for_loop` /
   `while_loop` / `recursion` / `lambda` / `import:` all have analogues but
   `list_comprehension` has none, so the predicate vocabulary must become
   language-scoped first (R would want `apply_family`, `pipe`, `vectorized`).

## Traps

These each cost real time. Read before starting.

1. **A `changelog.d/` fragment is mandatory on every PR.** With an empty
   `changelog.d/`, `auto-release.yml` exits **0** and reports success without
   releasing — a silent deploy stall. This cost 3 hours. Preview with
   `scripts/assemble-release.sh --dry-run`. Never edit `VERSION`,
   `ChickadeeVersion.swift`, or `CHANGELOG.md` directly.
2. **Reset the branch only *after* the release commit lands.** Merging consumes
   your fragment into `CHANGELOG.md` and deletes it. If you reset onto `main`
   before `chore(release): vX.Y.Z` appears, you carry the consumed fragment back
   and duplicate the entry. Wait for it, then
   `git checkout -B <branch> origin/main`.
3. **Validation results are cached.** `validate_assignment` only *watches* — it
   returns the last terminal status. Reading a stale result as current produced
   two wrong conclusions this session. To force a fresh run you need a real
   content edit (re-authoring a check with a changed hint works).
4. **A red validation may be the fleet, not your content.** If `longResult` says
   `could not find function "chickadee_..."`, that is runner version skew.
   Re-run before debugging; the fleet has been mixed, and consecutive runs 34
   seconds apart returned 13/13 and 0/13.
5. **CI has no R.** Every R renderer test guards on `Rscript` and *silently
   skips* in CI. R work is only really verified on a host that has R — so run
   `swift test --filter 'RendererR|RRuntime'` locally and don't trust a green CI
   as proof the R paths work.
6. **Clone-and-convert needs a language flip.** Until backlog item 2 is fixed:
   save one throwaway `.R` test script, which re-resolves and *records* `language: r`;
   the record persists, so delete the script immediately after.
7. **Python's generated bytes must never move.** They feed `spec_hash` and
   `TestSetupCache` keys. Add R *alongside* the Python renderers, never as
   branches inside them. Tests assert this — keep them.
8. **`Tools/runner-support/test_runtime.R` is a byte-for-byte mirror** of the
   composed Swift string in `Sources/Worker/TestRuntimeSources.swift`. Edit both
   or `RuntimeSourceDriftTests` fails. It cannot interpolate Swift constants,
   which is why the cell-marker contract has a dedicated pin test.
9. **The stop hook will flag two commits as "Unverified"** whenever the branch
   sits at `origin/main`. They are GitHub's own — the auto-release bot and the
   squash-merge. Do **not** amend or rebase them; that rewrites merged history
   behind a force-push. Only act if a commit is genuinely yours.
10. **`mcp__github__actions_list` returns payloads too large to read.** It saves
    to a file; parse that with `python3 -c 'import json; ...'`.

## Before every push

```
scripts/format.sh
scripts/lint.sh
scripts/swiftlint.sh
swift test --filter 'RendererR|NotebookCheck|PatternFamily|Runtime|Personalization'
```

Commit as `noreply@anthropic.com` / `Claude`
(`git config user.email noreply@anthropic.com && git config user.name Claude`).

## Reference

- [`docs/r-support.md`](r-support.md) — the design: language resolution, the
  per-language strategy, personalization in R, the R renderers, the cell-boundary
  marker, and what is deliberately deferred.
- [`docs/personalization-eval-runtime.md`](personalization-eval-runtime.md) —
  why expressions are evaluated per-language **on the server**.
- [`docs/zero-downtime-deploy.md`](zero-downtime-deploy.md) — the deploy daemon;
  step 8 is the runner refresh, and its failures are logged to `history.jsonl`
  without rolling back the deploy (relevant to backlog item 1).
