# Dead-code review (weekly)

Goal: remove the dead code that this week's Periphery report finds and that
survives a check by hand. Work from the report that CI produces
(`dead-code.yml`, Sundays at 08:00 UTC). Do not hunt for dead code by reading
the whole codebase. Follow the rules in `Tools/maintenance/README.md`.

Read `docs/dead-code-scan.md` first. Its section "Results that are not dead
code" is binding here.

## 1. Get the report

1. Find the newest successful run of the workflow on `main` that finished in
   the last 24 hours:
   `gh run list --workflow dead-code.yml --branch main --status success --limit 1 --json databaseId,updatedAt`
2. If there is none, report that and stop. Do not start a run and wait for
   it; the next night takes it.
3. Download the artifact into your scratchpad, not into the repository:
   `gh run download RUN_ID -n dead-code-report -D SCRATCHPAD/dead-code-report`
4. `agent-prompt.md` is the task list. `results.json` has the same results
   in a form you can count. If the report says "No unused code detected.",
   report that and stop.

## 2. Check each result before you remove it

`agent-prompt.md` says to treat its results as authoritative. Do not follow
that here: Periphery does not see every use in this repository. Remove a
result only if every check says it is unused:

- It is not in a group that `docs/dead-code-scan.md` says is not dead code:
  `CodingKeys`, Fluent property wrappers and migrations, wire-format fields
  (`Tests/Fixtures/output-contract.json`, the MCP output schemas), test
  seams.
- A word-boundary search for its name in `Sources/`, `Tests/`, `wasm/`,
  `Public/`, `scripts/`, `Tools/` and `docs/` finds no use outside its own
  declaration. `wasm/` is a separate package that the scan does not build,
  so a use there is a real use.
- It is not reached by name from a string, a route path, a registry or a
  catalog (for example `MCPToolCatalog`, a pattern-kind table or an
  Elementary fixture list).
- For an unused parameter: skip it when a protocol, an override or a Vapor
  route signature requires it.

Keep a list of each result you reject and the reason.

## 3. Remove the confirmed results

- Work through `agent-prompt.md` in its order. It groups results that must
  go together.
- If a removal makes other code unused, remove that too.
- If a result is used only by tests, or its removal needs an edit to an
  existing file under `Tests/`, do not remove it. List it for the
  maintainer.
- Add one fragment in `changelog.d/` under `### Removed`.
- If nothing survives the checks, open no pull request. Report what you
  rejected and why.

## 4. Verify and open the pull request

1. Start the test Postgres if it is not running, as `README.md` describes
   (`docker start chickadee-postgres`). If Docker is not running, say so,
   and do not say that the database suites passed.
2. Run the `test-runner` subagent with a filter for the suites that the
   change touches.
3. Run `lint-guard`, `diff-reviewer` and `interaction-review`. Fix what
   they find.
4. Open one pull request with three lists:
   - Removed: each declaration, with one line on why it is dead.
   - Rejected: each result you did not remove, with the reason. These are
     candidates for a Periphery baseline.
   - For the maintainer: results that only tests use, and anything you
     could not decide.
