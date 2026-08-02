# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows Semantic Versioning.

Releases before 0.5.0 (the 0.1.0 – 0.4.669 history, ~660 releases across the
first course offering) are archived in [CHANGELOG-0.4.md](CHANGELOG-0.4.md).

## [Unreleased]

## [0.5.1] - 2026-08-02

### Added

- **`delete_support_file` MCP tool.** Removes one non-graded support/data file from
  an assignment's test setup. `author_script(tier: "support")` could create and
  replace support files but never remove one, so retiring a helper module or a stale
  fixture meant overwriting it with a stub — leaving a dead entry in the setup zip
  that students could still download. The tool refuses graded rows (pointing at
  `delete_suite_item` or the owning family/check) and the reserved setup members
  (`test.properties.json`, `assignment.ipynb`, `solution.ipynb`), clears any
  `graderOnlyFiles` / `datasets` mark naming the file, re-syncs the shared support
  directory so student symlinks disappear, and re-runs validation — so a remaining
  test that still sources the file fails loudly instead of at submission time.
  Content catalog is now 52 tools.

### Fixed

- **R pattern-family and notebook-check cases can express `NA`.** An authored JSON
  `null` now renders as R's `NA` rather than `NULL`, and a null interleaved among
  scalars no longer demotes the whole array to `list(...)` — `[60, null, 20]` renders
  as `c(60, NA, 20)`, `["G2", null, "G4"]` as `c("G2", NA, "G4")`. Previously `NULL`
  silently vanished inside `c()`, so an NA-bearing case handed the student's function
  a list and failed with `'list' object cannot be coerced to type 'double'` before the
  function was meaningfully exercised. This made the "NA in, NA out" half of a
  function's contract unauthorable as a pattern family, forcing hand-written scripts.
  Mixed-kind arrays still render as `list(...)`; a null does not rescue them.


## [0.5.0] - 2026-08-01

### Changed

- **Chickadee 0.5.0.** Marks the conclusion of the first full course offering
  run on Chickadee and the close of the 0.4 series. The system this milestone
  snapshots: Python and R assignments; browser (Pyodide/wasm) and native
  worker grading sharing one RunnerCore implementation; per-student
  personalization, pattern families, and notebook checks; achievements and
  slip days; per-course roles; BrightSpace grade sync; the MCP authoring and
  admin-diagnostics surfaces; OIDC SSO; and zero-downtime auto-deploys. The
  0.1.0 – 0.4.669 release history is archived in CHANGELOG-0.4.md;
  development now shifts to next year's feature work.


## [0.4.670] - 2026-08-01

### Changed

- **0.5-boundary cleanup pass.** Closes out the 0.4 series ahead of the 0.5.0
  milestone: the CI test image now installs `r-base` and pandas/matplotlib so
  the R execution-path and dataframe/plot suites actually run in CI (their
  availability guards were permanently false before); the browser graders'
  shared Python snippets, exit-code derivation, MEMFS writer, and package
  preloader moved into one `Public/grading-shared.js` consumed by both the
  grading worker and the main-thread fallback (the fenced-region drift test is
  retired, and the grading worker is now spawned with the page's cache-buster
  so all grading files pin to one release); six APITests suites that spawn
  subprocesses or bind ports gained `.timeLimit` traits; the `alert()` ratchet
  now also covers first-party `Public/*.js`; and the second migration
  consolidation folded the post-#502 incremental migrations into their
  canonical `Create*` files, removing the boot-order hazard class behind
  #1077.

### Removed

- **Pre-0.5 compatibility shims.** The `WORKER_SHARED_SECRET` env alias (a
  deprecation warning had been shipping; use `RUNNER_SHARED_SECRET`), the
  `GET /admin/workers` and `POST /admin/worker-secret` route aliases, the two
  "one-time" legacy boot sweeps that ran on every boot, the decode-and-ignore
  `suiteFiles`/`suiteConfig` fields on `/edit/save`, the verified-dead overlay
  pattern-family editor path, the `NotebookFunctionScanner` memberwise-init
  realignment shim, and the legacy `isOpen` key on course-bundle exports (the
  read-side fallback stays, so old bundles import unchanged).

### Fixed

- **Documentation debt.** `CHANGELOG.md` history through 0.4.669 archived to
  `CHANGELOG-0.4.md`; CLAUDE.md's per-version log compressed into a 0.4
  retrospective; `docs/architecture.md` and `README.md` refreshed to describe
  the five-target + wasm reality, both MCP surfaces, and per-course roles;
  finished-era investigations moved to `docs/archive/`; stale "not yet built"
  headers corrected; and the manual minor-bump procedure is now documented in
  `docs/release-process.md`.

