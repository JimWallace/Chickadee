# Fix failed scheduled checks (nightly)

Goal: every scheduled check on `main` is green, and every finding that it
reports is fixed or has a recorded reason. These checks are off the pull
request path, so nothing else makes a person look at a red one. Follow the
rules in `Tools/maintenance/README.md`.

`dependency-update-failed` issues are not part of this job; they belong to
`dependency-failures.md`. The Swift pins belong to `swift-pins.md`.

## 1. Collect

1. Open issues labelled `scheduled-check-failed`. `macos-build.yml` and
   `visual-regression.yml` file them, one per key, through
   `scripts/dependency-issue.sh`; the next green run closes each one. Also
   open issues labelled `nightly-clean-build`, which `test-coverage.yml`
   files when the clean build fails.
2. The newest scheduled run on `main` of each of these workflows. A red run
   with no issue is work:
   `browser-probes.yml`, `browser-grading-smoke.yml`, `test-coverage.yml`,
   `kernel-currency.yml`, `zap-baseline.yml`, `codeql-js.yml`,
   `macos-build.yml`, `visual-regression.yml`.
   `gh run list --workflow NAME --branch main --limit 1 --json conclusion,event,databaseId,createdAt`
3. Open CodeQL alerts:
   `gh api 'repos/{owner}/{repo}/code-scanning/alerts?state=open&per_page=100'`
4. The ZAP baseline report issue (title "ZAP Scan Baseline Report"): the
   alerts that its newest comment adds.
5. The flake-telemetry tracking issue: a rate that rose for two weeks in a
   row.

If all of these are clean, report "nothing to do" and stop.

## 2. Fix

Take the items one at a time. One pull request per root cause. If a fix
needs an edit to an existing file under `Tests/`, do not make it: name the
exact edit in the night report, as `Tools/maintenance/README.md` says.

- **A red run.** Find the root cause in the failed job's full log, not its
  tail. Read `docs/ci-flakiness.md` before you call a failure a flake.
  Re-run a job at most once, and only to show that the failure is not
  repeatable.
- **`kernel-currency.yml` red.** Red there means that the kernels are
  behind; the job dispatches `revendor-kernels.yml`, which opens its own
  auto-merging pull request. Find that pull request. If it is red, fix it on
  its branch, as `Tools/jupyterlite/CLAUDE.md` says. Read that file before
  you change anything under `Public/jupyterlite/` or `Public/vendor/`.
- **`visual-regression.yml` red.** A changed screenshot is a fix only when
  the change on `main` was intended: name the pull request that made it.
  Update a baseline only with that evidence. An accessibility violation is
  fixed in the page, never in `a11y-baseline.json`.
- **A CodeQL alert.** Fix the code. Dismiss an alert only as a false
  positive, with the argument in the dismissal comment, and list each
  dismissal in the report.
- **A ZAP alert.** Fix it in the server (a header, a cookie flag, a
  response). If the alert is a false positive for this deployment, add it to
  `.zap/rules.tsv` with the reason, in its own pull request.
- **A flake that rose.** Follow `docs/ci-flakiness.md`. Fix the test or the
  code under test; never widen a tolerance to hide the rate.

## 3. Close the loop

Comment on each issue you worked on: the root cause, the change, and the
pull request. Do not close a `scheduled-check-failed` issue yourself; the
next green run closes it.
