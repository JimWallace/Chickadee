# Audit rotation (Saturday nights)

Goal: one audit each week, in turn, with its findings filed as an issue and
the clear ones fixed. The day of the month that the night starts on decides
the audit. Follow the rules in `Tools/maintenance/README.md`.

| Day of the month | Audit |
|---|---|
| 1 to 7 | Docs audit (section 1) |
| 8 to 14 | UI audit (section 2) |
| 15 to 21 | Code that only tests use (section 3) |
| 22 to 31 | No audit. The night goes to fill work (`nightly.md`). |

## 0. Rules for every audit

- Before you file or fix anything, look for work that already exists:
  `gh pr list --state all --search "<audit> audit" --limit 5`, and the
  newest issue with the audit's label. If an open or merged pull request
  already fixes the issue, report it and stop.
- Check each finding again on `origin/main` before you fix it. If it is no
  longer true, skip it and write "already fixed on main" in the pull
  request body.
- Fix only a finding that has one clear, mechanical fix: a wrong path, name,
  count, status line, class name or token. A finding that needs a design or
  product decision stays in the issue, and the pull request body lists it
  under "Left for the maintainer".
- Run `diff-reviewer` on the diff, and `interaction-review` when the diff
  touches `Sources/` or a `Public/*.js` file.
- Put "Fixes #N" for the issue in the pull request body only when the pull
  request fixes every finding. When anything is left for the maintainer,
  write "Refs #N", so the issue stays open.

## 1. Docs audit

1. Run the `docs-audit` subagent on the worktree.
2. Read the newest `docs-audit` issue. If it is still open, mark each
   finding that it already lists as "still open since #N".
3. File one issue titled "Docs audit (DATE)" with the label `docs-audit`.
   The body is the agent's report, findings in order of severity. If the
   agent found nothing, file the issue anyway, say so, and stop. If the
   previous `docs-audit` issue is open, close it with a comment that links
   the new one.
4. Fix the findings. Open the pull request titled
   "docs: fix drift from the YYYY-MM docs audit".

## 2. UI audit

1. Do steps 1 to 3 of section 1 with the `ui-audit` subagent, the label
   `ui-audit` and the title "UI audit (DATE)".
2. Read `Sources/APIServer/Views/CLAUDE.md` and `docs/ui-design.md` before
   you edit. Fix only findings that the design system already decides: a
   wrong token, a missing shared class, a label that is not consistent with
   other pages, a missing accessible name. A new pattern or a layout change
   is a design decision.
3. Run `scripts/check-styles.sh`, `lint-guard`, `test-runner` with the
   filter `ElementaryPageGuardTests`, `ui-review` and `interaction-review`.
   Apply their findings.
4. Open the pull request titled "ui: fix findings from the YYYY-MM UI
   audit".

## 3. Code that only tests use

Removing this code means editing tests, and an unattended run cannot get
the maintainer's approval for that. So this audit sorts the list and
prepares the removal for a live session. It removes nothing and opens no
pull request.

1. Find the newest successful `dead-code.yml` run on `main` that finished
   in the last 8 days. If there is none, report that and stop.
2. Download its artifact into your scratchpad:
   `gh run download RUN_ID -n dead-code-report -D SCRATCHPAD/dead-code-report`
   If `results-without-tests.json` is missing, report that and stop.
3. The list is every result in `results-without-tests.json` whose `ids`
   are not in `results.json`. Drop results under `Tests/`, and results that
   `docs/dead-code-scan.md` says are not dead code.
4. Put each remaining result in one group, after a word-boundary search of
   `Sources/`, `Tests/`, `wasm/`, `Public/` and `scripts/` (a use in
   `wasm/` is a real production use):
   - Test seam, keep: its doc comment says that tests use it, or it injects
     a clock, a random source, a database or another dependency.
   - Remove with its tests: a wrapper or old overload that production code
     no longer calls. Name the test files that call it.
   - Unsure: say what you must know to decide.
5. If an issue labelled `dead-code` is open, add this month's list as a
   comment and mark the items that are new. If none is open, file one
   titled "Code that only tests use (DATE)" with the label `dead-code`.
   Give each item a file and line, and name the run it came from.
6. End the issue or comment with a section "To remove": a prompt that the
   maintainer can paste into a live session. It lists each item in "Remove
   with its tests" with its test files, and asks for one pull request that
   removes them.
