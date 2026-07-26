# Handoff: first-class R support (HLTH 230 → R)

Written 2026-07-25. Repo `JimWallace/Chickadee`, branch
`claude/hlth230-assignments-r-conversion-waxnqw`, released through v0.4.641.

## Goal

Chickadee supports assignments authored and graded in **R** as well as Python,
including per-student personalization, **transparently to instructors** — an R
instructor should never have to think about Python underneath. Design and
rationale: [`docs/r-support.md`](r-support.md). This file is only the
*remaining work* plus the traps that will cost you hours if you don't know them.

## State: done and verified

The engine is complete and merged (v0.4.635–v0.4.641). All five HLTH 230
assignments are converted to R in course **TEST** and **validate green**:

| Assignment | Public ID | Notes |
|---|---|---|
| A0 warm-up | `DEJr2f` | hand-written R tests |
| A1 BMI | `FpY4wz` | pattern families |
| A2 DNA/k-mers | `OImnr8` | per-student expressions, `{{name}}` substitution |
| A3 health records | `PKPkxL` | 4 pattern families with per-student `expectedVarRef`, `dbgen.R` |
| A4 VitalDB EDA | `I4nUW0` | 6 notebook checks; **6/6 pass** as of 19:46Z |

Notebook checks render in R for **every kind but `ast_structure`**.

There are **no open PRs**. #1211 (every escape in the R runtime's JSON result
formatter) merged as v0.4.641; runners pick it up on the normal deploy path,
after which student-visible R messages render correctly.

## Task 1 — apply minimum-runner-version gates (blocked on a client reconnect)

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

**Status (still pending).** Not yet applied. In a later session the Chickadee
connector reconnected under a *new* server id, but its tools then returned
`requires approval` — so the gates await the connector being re-authorized in
the client (that same approval gate also blocks `send_later`). The tool name is
otherwise correct; only its server-id prefix changes per reconnect.

## Task 2 — backlog (found this session, none started)

Ordered by value. Items 1–4 are **done** (shipped v0.4.643–v0.4.646); only
item 5 remains.

1. ~~**Runner version-skew alert.**~~ **Done — #1213 (v0.4.643).** A
   `runnerVersionSkew` health alert fires when an active runner falls behind the
   server (`ChickadeeVersion.current`), with a server-uptime grace
   (`ALERT_RUNNER_VERSION_SKEW_GRACE_SECONDS`, default 900s) so only *persistent*
   skew pages — the expected transient skew during a deploy's runner-refresh
   window stays quiet. Backstop for `zero-downtime-deploy.md` step 8.
2. ~~**The recorded manifest language is a one-way door.**~~ **Done — #1216
   (v0.4.646).** Replacing the starter notebook now re-derives the recorded
   language (`AssignmentLanguage.rederive` in `writeAssignmentNotebook`, no-op
   when unchanged); the throwaway-`.R`-script workaround (Trap 6) is obsolete.
   See `r-support.md`, "How the language is resolved and remembered".
3. ~~**`cell_contains` regex validator counts parens naively.**~~ **Done — #1215
   (v0.4.645).** The scan tracks escape state and character-class nesting, so
   `\(`, `[(]`, and a literal trailing `\\` are accepted; genuinely unbalanced
   parens and a dangling backslash still reject.
4. ~~**Check `variable` is validated as a *Python* identifier.**~~ **Done — #1215
   (v0.4.645).** `validateNotebookChecks` threads the assignment language into
   each handler's `validate`; R names like `my.df` are accepted via
   `isValidRIdentifier`, while Python assignments are unchanged.
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
6. ~~**Clone-and-convert needs a language flip.**~~ **Obsolete as of #1216
   (v0.4.646):** replacing the starter notebook now re-derives and records the
   language, so the throwaway-`.R`-script trick is no longer needed. (Left here
   because older deploys still need it until v0.4.646 ships.)
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
