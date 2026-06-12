# CI Follow-Ups

> **Historical.** This note documents the CI containment work done for the
> `v0.4.6` release push. The 3-job `Swift Tests` split was collapsed back
> to a single job and `WorkerTests` returned to the per-PR gate as part of
> the 2026 cleanup (commit `a5a6f61`). Kept here for archaeology.

This note captures the CI changes made during the `0.4.6` release push, why
they were made, and the cleanup work that should happen next.

## Release Context

To get `v0.4.6` out for live testing, the main release gate was narrowed to the
checks that were consistently passing on GitHub Actions:

- `JupyterLite`
- `Build and Push Docker Image`
- `Swift Tests`:
  - `CoreTests`
  - `APITests`

The release tag `v0.4.6` was cut from commit `5aad78e`.

## CI Reshaping That Happened

The following workflow changes were made on `main`:

- Coverage was moved off the push path and into nightly/manual execution.
- The original all-in-one Swift test gate was split by target.
- `WorkerTests` were removed from the release-critical `Swift Tests` workflow.
- A separate `Worker Tests` workflow was added for manual/nightly investigation.

Relevant commits in order:

- `ecb33be` `Split CI tests and move coverage nightly`
- `d5de0f1` `Run coverage on schedule instead of push`
- `5ccad7e` `Fix worker secret path test across path aliases`
- `15b4104` `Run worker tests without parallel mode`
- `03552f3` `Skip sandbox runner tests on GitHub Linux CI`
- `5aad78e` `Move worker tests out of release CI gate`

## Runner Test Problem (resolved)

The original `v0.4.6` containment — quarantining `WorkerTests` to a separate
manual/nightly workflow — has been wound down. `WorkerTests` now runs on
every PR and push to `main` as a sibling job inside `swift-tests.yml`,
alongside `CoreTests`, `APITests`, and the browser-runner tests.

### What was wrong

`WorkerTests` repeatedly hung on GitHub's Linux container runner during the
`v0.4.6` push, even after `--parallel` was removed and the sandbox-exec
tests were skipped on Linux CI. The same suite passed locally and the rest
of the gate ran normally. The hang blocked the release, so the suite was
split into three jobs (`stable`, `runner-core`, `timeouts`) in a separate
reusable workflow and moved off the release gate while the cause was
investigated.

One real portability bug surfaced during the investigation and was fixed in
`Tests/WorkerTests/WorkerTests.swift` — a path comparison that assumed
`/var/...` vs. `/private/var/...` on macOS now derives its expected path
from `FileManager.default.currentDirectoryPath` instead.

### Why it's resolved

After incremental tightening (the 2026 May `Split worker CI` work and
related Swift 6 concurrency cleanups), all three buckets have been green
on consecutive PR and nightly runs for weeks. With the suite stable, the
three-job split was scaffolding rather than signal, so the workflow has
been collapsed back to a single `worker-tests` job inlined into
`swift-tests.yml`. The separate `worker-tests.yml` nightly schedule and
the `worker-tests-reusable.yml` indirection have been deleted; per-PR
coverage exercises the same code on every change.

The one remaining Linux skip is correct and stays: `sandbox-exec` is a
macOS-only API, so the `requireStableLinuxSandboxRunner()` guard in
`Tests/WorkerTests/WorkerTests.swift` keeps those eight `testSandboxedRunner*`
cases off the Linux runner.

## Warning Cleanup

The build logs currently contain many warnings, including Swift 6 async
warnings in tests and related code paths.

This should get its own focused cleanup pass. In particular:

- replace APIs that are unavailable from async contexts
- remove `await` where no async work occurs
- adopt the async variants of testing helpers where available
- treat warning cleanup as preparation for stricter Swift 6 enforcement

This matters even when builds pass, because these warnings are likely future
errors once Swift 6 mode gets stricter.
