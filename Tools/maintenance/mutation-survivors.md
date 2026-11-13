# Triage mutation survivors (weekly)

Goal: every new survivor of the week's mutation sweep has an answer. The
sweep runs on Tuesdays at 06:00 UTC and files an issue titled
"Mutation sweep: logic tier (<date>)". Read `docs/mutation-triage.md`,
`docs/mutation-trend.md` and `Tools/mutation/equivalent-mutants.json` first.
Follow the rules in `Tools/maintenance/README.md`.

1. Find this week's sweep issue. If there is none, report that and stop. If
   it says a shard produced no report, read that shard's job log, find why
   the mutated copy did not build, and fix that too.
2. Ignore the "Phantom mutants" sections. For each real survivor:
   1. Confirm it by hand: make the mutation and run the suite.
   2. Answer it one of three ways:
      - kill it with a test in a new file under `Tests/` (Swift Testing);
      - record it in `equivalent-mutants.json` with an argument for why no
        reachable input tells the two versions apart (a label is not an
        argument);
      - if it shows a real bug, fix the bug minimally and add a test.
3. Branch `steward/mutation-survivors-<sweep date>` from `origin/main`. Add a
   changelog fragment, run `scripts/format.sh` and
   `scripts/format-lint.sh`, and run the new suites.
4. Open a pull request with a table: survivor, then "killed by <test>",
   "equivalent (reason)", "bug fixed" or "not done (why)". Reference the
   sweep issue and enable auto-merge.
5. Comment the table and the pull request on the sweep issue.

Do not chase the score. An equivalent entry is an argument, not a
suppression.
