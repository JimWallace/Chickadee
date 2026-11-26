# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows Semantic Versioning.

Earlier releases are archived: the 0.5 series (0.5.0 – 0.5.x, the first
full course offering and the move to a multi-course pilot) in
[CHANGELOG-0.5.md](CHANGELOG-0.5.md), and 0.1.0 – 0.4.669 in
[CHANGELOG-0.4.md](CHANGELOG-0.4.md).

## [Unreleased]

## [0.6.9] - 2026-11-26

### Changed

- **Tests: a worker report on a contribution assignment schedules the class corpus run.** `ClassCorpusTests` now posts a student's result through the real worker result route and checks that the class corpus run starts, and that an ordinary assignment starts none. The worker result-report helpers moved from `WorkerRoutesTests` to the shared `WorkerClaimTestFixture.swift`.


## [0.6.8] - 2026-11-25

### Added

- **Lecture notebooks.** A course can host an ungraded lecture notebook that students open and run in the notebook editor, each in a copy of their own. It has no Submit button, no grade, no LMS push and no validation. Staff add one from a section's "+ Add" menu (title, language, optional `.ipynb`) and edit it in the editor with "Save lecture notebook". MCP agents author one with `create_content_item` / `update_content_item` (`lectureNotebook`) and read it with `get_lecture_notebook`. See `docs/lecture-notebooks.md`.


## [0.6.7] - 2026-11-25

### Security

- **LTI audit follow-ups before the W27 production registration.** Every call to an LTI platform (key set, token, grades, roster) now has a 20-second deadline and a 4 MiB body cap. A launch token older than the login window, or with a future `nbf`, is refused, and tests show that `alg: none` and HS256 tokens are refused. `POST /lti/deep-link/bind` no longer creates the tool key on a deployment with no platform. The audit log now records the "Trust username" switch on every platform change, and each enrollment a launch creates (`lti.enrolled`). Fixes L-4, L-6, L-7 and L-8 of `docs/compliance/lti-audit-2026-10.md`.


## [0.6.6] - 2026-11-25

### Removed

- **Dead code from the 2026-11-22 dead-code scan.** Two lab-group model initializers that nothing called, and two parameters that their functions never read: `app:` on `materializeValidationGrading` and `courseUUID:` on the BrightSpace `syncSummary`. Also 14 unused test helpers, properties and parameters. Behaviour does not change.


## [0.6.5] - 2026-11-25

### Added

- **REST API reference.** `docs/rest-api.md` documents the HTTP interfaces for programs: the four kinds of authentication (session with CSRF, the runner's HMAC signature, bearer tokens, third-party signatures), the runner protocol, the `/api/v1` submission, browser-grading and test setup endpoints, the JupyterLite contents API, and the GitHub, LTI, SSO, OAuth and MCP endpoints, with their bodies and status codes. `Sources/APIServer/CLAUDE.md` now points to it and no longer lists runner paths without their `/api/v1` prefix or a `PUT /instructor/:id/families` endpoint that the unified suite endpoint replaced.


## [0.6.4] - 2026-11-25

### Added

- **CONTRIBUTING.md and a Sponsor button.** CONTRIBUTING.md sets out how a change gets in (an issue first for large changes, then a pull request that the maintainer reviews), the local checks to run, the rules the code follows, and the licence of contributions. `.github/FUNDING.yml` adds the repository's Sponsor button, which links to GitHub Sponsors.

### Changed

- **Coverage floor raised from 80.0 % to 94.0 %.** Line coverage has held at 96.6 % on main, so the old floor left about 15,000 lines of slack. The nightly coverage run now fails below 94.0 %. The README also shows the measured coverage from Codecov next to the floor.


## [0.6.3] - 2026-11-25

### Changed

- **`DatasetMaterializer.apportion` no longer takes a `total` argument.** The function did not read it. The stratified split is the same for every input.


## [0.6.2] - 2026-11-25

### Added

- **README badges.** CI status, the coverage floor, the latest release, Swift, platforms and license join the OpenSSF Scorecard badge. Every badge but two reads its value live; the coverage floor is read from `test-coverage.yml` on main, so raising the floor raises the badge. The Swift badge is static, so `scripts/check-readme-badges.sh` (a `format-lint` step, with a guard fixture) holds it to `swift-tools-version`.


## [0.6.1] - 2026-11-25

### Security

- **Signed releases and more pinned dependencies (OpenSSF Scorecard).** Every GitHub Release, pre-releases included, now carries a source tarball of its tag and a Sigstore-signed provenance file (`.intoto.jsonl`) made by `actions/attest-build-provenance`; `gh attestation verify chickadee-<version>.tar.gz --repo JimWallace/Chickadee` checks a download. The CI test image builds from the mirrored Swift base by digest, not by tag. The Dependabot extension rebuild installs JupyterLab from a hash-locked file, which it recompiles when the npm pin moves. The deployer and the snapshot, restore and deploy scripts read a JSON response into a variable before parsing it, instead of piping `curl` into `python3`, which Scorecard reads as running downloaded code.


## [0.6.0] - 2026-11-25

### Removed

- **The unused `course_sections.default_grading_mode` and `default_assignment_type` columns are dropped.** A section has carried no grading mode or type since assignment types phase 3, and no model maps either column in v0.5.988 or later, so the old color of a blue-green deploy is unaffected. A rollback to an older release whose model maps `default_grading_mode` needs the migration reverted first, which restores both columns. A course bundle still writes `defaultGradingMode: "worker"` for older importers.

### Removed

- **The legacy `patternFamilies` / `notebookChecks` manifest keys are no longer written.** The v1 form of a manifest (what the MCP manifest resource, MCP `get_assignment_version` and course-bundle export send out) now carries only `testItems`, which every supported reader has read since 0.4.206. Old manifests and bundles that carry only the legacy arrays still decode: the read-side migration stays. The runner job and the browser runner never carried these keys.
- **One retest per assignment with pattern families or notebook checks.** `manifestHash` hashes the v1 form, so the hash of every such assignment changes. Its next edit after the upgrade, even a cosmetic one, retests its student submissions once (`lastRetestedManifestHash`), adds one version-history row, and until then MCP `list_assignment_versions` shows no version as current. Assignments without families or checks are unaffected.

### Changed

- **Chickadee 0.6.0.** Closes the 0.5 series and opens the multi-course pilot, in which several courses run live class activities at once. The system this milestone snapshots: seven assignment languages (Python, R, Lua and Octave in the browser on xeus kernels; C++, Racket and Java upload-only), each declared by its assignment; browser and native grading sharing one RunnerCore; the assignment workbench, per-student datasets and the course dataset library; class activities from leaderboards to tournaments, class goals, lab groups and course achievements; class handles and avatars; LTI 1.3 and GitHub submissions; and production deploys gated by mode, with contract changes shipping only in a minor (`docs/release-gate.md`). The 0.5 release history is archived in `CHANGELOG-0.5.md`, headed by a one-line-per-theme summary of the series. Three changes are incompatible, each with its own entry in this release; read them before approving the deploy: the runner's `--worker-secret` flag is removed (#2226); the manifest no longer writes the legacy arrays, so an assignment with families or checks is retested once, on its next edit; and the runner sandboxes by default (#2348), so one that passes no flag, on a host that cannot sandbox, does not start.

### Removed

- **The runner's `--worker-secret` flag no longer does anything** (#2226), deprecated since #2220. It put the runner secret in the runner's command line, where every test script can read it from `/proc`, also inside the sandbox, and so sign worker API calls such as reporting its own result. The runner now takes the secret only from `RUNNER_SHARED_SECRET` or the `.worker-secret` file. A runner still started with the flag boots as before and prints a warning; remove the flag from its start command, because its value stays readable by test scripts while it is there. The server's own `--worker-secret` flag is unchanged.

### Changed

- **The runner sandboxes test scripts by default** (#2348). Before, it ran them unsandboxed unless started with `--sandbox`. A runner that already passes `--sandbox` behaves exactly as before: the flag is still accepted and changes nothing. `--no-sandbox` turns the sandbox off, and with both flags the last one wins. A runner on a host that cannot start the sandbox (no unprivileged user namespaces, or Docker's default seccomp and AppArmor profiles) now refuses to start and says why, where before it graded unsandboxed. This includes a bare-metal runner from `deploy/chickadee-runner.service` and `swift run chickadee-runner` in development, which passed no flag. Allow the namespaces, or add `--no-sandbox` to that runner's start command.

### Fixed

- **The admin course page lists assignments that share a due date in a fixed order.** The list sorted only by due date, so the order of a tie depended on which index the database planner chose. When `DropCoveredIndexes` removed `idx_assignments_course_id`, the tie flipped and the `admin-course` visual baseline failed on `main`. Ties now go oldest first (creation time, then id).

### Fixed

- **Database card: review fixes.** A configuration change whose audit entry cannot be written now fails and rolls back visibly, instead of committing nothing in silence. The collation is read from `datlocale` when the database uses the ICU or builtin locale provider (PostgreSQL 17 and later), and the card shows the provider beside it. The stored configuration tolerates a field added or removed by another version of the server, and the compare-and-set update matches the stored value exactly as read, so a server never retries the same change every minute. The MCP pool reads "Shared", "Separate role" or "Same role", and the "Previously" note names at most three changes.
- **The first reading is the baseline.** The card's first reading becomes its baseline. So the PostgreSQL 16 to 18 upgrade that ships in the same release is recorded in the deploy history ("db-upgrade ok 16->18"), but not as a "Database configuration changed" audit entry. Later changes are recorded.

### Added

- **Database card on the admin Overview.** The Overview shows the live database configuration: the PostgreSQL version, data checksums, size, `max_connections`, whether `pg_stat_statements` is loaded, encoding, collation, and whether the MCP pool connects as its own role. A read that fails shows "unavailable" and the page still renders. The server records the configuration at boot and when the Overview refreshes it (at most once a minute), so the card says since when it holds and what it was before; a change writes one "Database configuration changed" audit entry, even when two servers start together. The admin MCP tool `get_deployment_info` reports the same reading under `database`. No credential, host or role name is shown.

### Changed

- **APITests layout matches its folders.** Misplaced suites moved to their feature folders, multi-suite files split one suite per file, `Diagnostics/` dissolved, single-folder helpers moved next to their users and the page fixtures into `PageFixtures/`; `APITestsLayoutTests` now checks the folder set against `docs/testing-conventions.md`.

### Fixed

- **The image build no longer fails when Docker Hub serves a layer from S3.** The egress allowlist of the `docker-build.yml` push job did not include the Docker Hub S3 blob host. On 2026-11-21, 6 runs failed at "Set up Docker Buildx", 3 of them release-tag builds that published no image. The host is now on the list.

### Changed

- **CI mirrors `postgres:18` into GHCR.** First step of the Postgres 16 → 18 upgrade (#3148): the image must be in GHCR before the test jobs can point at it.

### Changed

- **Core symbols that no other module uses are now internal (#3234).** `AvatarCrestShape`, `DatasetSeedDerivation`, `JSONReindenter`, `ZipArchiverError`, `listZipContents(zipPath:)` and `runZipProcessExpectingSuccess` lose their `public` keyword. The tests that use them now import Core with `@testable`. Behaviour does not change.

### Changed

- **CoreTests grouped by subject.** The 167 flat files in `Tests/CoreTests` now sit in twelve subject folders, `CoreCodableTests` is split into one suite per type it covered, and `StreamedDigestTests` has its own file; no test or assertion changed.

### Changed

- **Tests for the success path of the admin `get_query_stats` tool.** The scripted catalog database and the stats-schema fixture moved from the `QueryStatistics` tests into a shared test file. A new `useScriptedCatalog` helper makes the scripted database the one that a request reads, so the tool's ready path (totals, order, limit, share of total, reset date, hidden-text note) and its two unavailable states now run on every test database.

### Changed

- **Tests for the student submit, slip-day and solution routes.** New tests cover the upload form redirect and file-type refusal, an unknown test setup on the browser JSON doors, the runner-submit filename rule, the stacked slip-day confirmation page and the solution link on the result page.

### Fixed

- **Deleting an assignment or a course removes its activity rows.** Badges, leaderboards, king-of-the-hill matches and champions, round-robin standings, tournaments and the LTI push queue, for the class and each lab group, kept a student's ID and submission after the delete. `assignments.slug` is now NOT NULL, as the model already assumed.

### Changed

- **Database design rules and guards.** `docs/database-design.md` states the rules for a new table, migration and query. New guards read the migrated catalog: no index is covered by another, no non-optional model field sits over a nullable column, and a delete leaves no row keyed to what it deleted. A claim and a result report get statement budgets beside the page budgets. Four covered indexes were dropped, and a `db-review` agent covers the judgment half.

### Fixed

- **One running tournament, one BrightSpace credential, one validation batch and one lab group set per scope, held by the database.** Each was a read-then-write that two requests at once could both pass. A migration removes any duplicates first, keeping the newest row.

### Changed

- **Fewer statements on grade pushes, coverage and the claim path.** Class coverage, grade-override flags, the LTI queue and BrightSpace requeue write in one statement instead of one per row; grade overrides set and clear in one transaction. The classmate chooser, the queue-depth timeline, the activity chart, the data export's audit filter, the metrics series and the class-goal sweep do their picking and counting in SQL. The connection-budget comments now count both servers of a blue-green deploy.
- **The class-goal sweep skips archived courses.** Their goals are history; a course archived before a goal's deadline keeps the snapshot it had, with no freeze and no new grade push.

### Fixed

- **`scripts/db-major-upgrade.sh` works end to end on PostgreSQL 16 → 18.** Its inventory query failed on every run (`text || "char"` is ambiguous), the PostgreSQL 17 `MAINTAIN` privilege made the before/after inventory differ, and a failed run hung forever after its rollback instead of exiting; the CI test (#3148) now passes in about a minute and also covers `--pin-current`.

### Added

- **`scripts/db-major-upgrade.sh` moves the Compose `db` to a new PostgreSQL major version.** It dumps the roles and the database, restores them into a new volume on the new version, compares a full inventory of the two (row counts, migrations, roles, grants, RLS policies, columns, indexes, sequences, database settings), and rolls back to the untouched old volume on any failure. `--check` runs the preflight only, `--recover` repairs an interrupted run, and `--pin-current` pins the running version. The live image and volume are recorded in `docker-compose.db.yml`, which every deploy script now includes. A new workflow runs the script end to end, 16 to 18, against real images (#3148).

### Changed

- **PostgreSQL 18 is the default.** Fresh installs get `postgres:18` (with `PGDATA` kept at `/var/lib/postgresql/data`), and CI tests against 18. An existing host keeps its version until `scripts/db-major-upgrade.sh` moves it; see "PostgreSQL major upgrade" in `deploy/README.md`.
- **`scripts/restore.sh` restarts the runner with `--no-deps`,** so a restore can no longer recreate `db` as a side effect.

### Fixed

- **The PostgreSQL major upgrade no longer rolls back on an owner-default grant.** The verify step compared the raw ACL of each table, schema and database. A table with explicit grants equal to the owner defaults restores with no explicit grants, so the check reported a difference and rolled back. It now compares effective privileges. A lost or extra grant still fails the run.

### Removed

- **The `isOpen` convenience initializer of `APIAssignment`.** Only tests called it. The tests now give `visibility:` to the remaining initializer (`.open` for `true`, `.closed` for `false`). Refs #3234.

### Removed

- **Five functions that only tests called.** The 2026-11-21 audit of code that only tests use removed `WorkerActivityStore.knownRunnerVersions`, `loadClassGoalViews`, `MetricsCardWindow.label(forBucketStart:)`, `ReflectionCells.hasTaggedCells` and the `DatasetResolver.resolve` overload with a course seed and no deal number. The tests now call the production functions. No behaviour changes.

### Removed

- **Seven overloads that only tests called.** The `testSetupID:` forms of `recordActivityMatch`, `awardClassBadgesFor100Percent`, `recordClassItemCoverage` and `recordLeaderboardEntry`, `LTIGradeSyncQueue.queue(submissionID:testSetupID:on:)`, `CompositeSlots.slot(assignmentID:...)` and the section-less `AuthoredSuiteItem.family(id:)` are gone. The tests now call the forms that production uses (#3234).

### Removed

- **Two overloads that only tests called.** `ScriptRunner.run(script:workDir:timeLimitSeconds:)`, the form with no `env:`, and `AvatarStore.ensureHandle(for:on:)` for an enrollment are gone. The tests now call the production forms (`env: [:]`, and the user form). Behaviour does not change (#3234).

### Removed

- **Three dataset overloads that only tests called.** The forms without a course seed or a deal number of `PersonalizationSubstitution.resolve`, `DatasetResolver.resolve` and `DatasetMaterializer.materialize` are gone. The tests now call the forms that production uses, with `nil` for the course seed and the deal number, as the removed forms passed (#3234).

### Removed

- **`TestProperties.runnerSanitized()`.** Only tests called this wrapper. Tests now call `runnerManifest().testProperties`, which gives the same manifest. The runner wire form does not change (#3234).

### Fixed

- **A long value no longer runs under a list row's pill.** An image digest in
  the admin Deployment history ran under the Result pill and the time. The name
  and details column of every `.section-items` list now wraps an unbroken value,
  and the Overview's drag-handle track is wide enough for its grip.
  The visual harness now captures the Deployment page with long values, and
  fails on any text that runs past its table cell at 320 and 1280 px.

### Fixed

- **The Deployment history's Result pill sits after the title on a phone.**
  Its cell lacked the `item-status item-grade` classes that other
  `.section-items` lists put on their value cell, so at phone width the pill
  sat between the tile and the title. It now sits at the right of the title,
  as in the other lists. On a desktop the pill now right-aligns in its column,
  as every `.item-grade` value does.

### Fixed

- **The Deployment history's Result pill stays in its column.** At desktop
  width the Result column was 5rem, so the "rolledback" pill ran about 7px past
  its cell and "recovered" about 5px. The column is now 6.5rem wide on this
  list only. The visual-regression fixture now has a "rolledback" and a
  "recovered" row, and the cell-overrun check measures a pill by its box, not
  only by its text.

### Changed

- **The deploy mode is a radio group on the admin Deployment page.** It was a list of the three modes with a "Switch" button on each row except the current one, which a badge marked. Now the current mode is the checked radio, each mode has its one-line summary, the default says "(default)" in its name, and one "Save mode" button asks before it sends the request.

### Fixed

- **The neutral `.tier` badge shows in dark mode.** Its fill was `--gray-100`, which dark mode sets to the page surface, so "Current", "Approved" and every other bare badge read as loose words. It now uses `--badge-neutral-bg`, one step up in dark mode and unchanged in light.

### Changed

- **The admin Deployment page alerts on a failed database upgrade.** A failed or
  rolled-back PostgreSQL upgrade shows an error banner on the held card, or above
  the running card when nothing is held. The upgrade warning is one sentence and
  still shows while the release notes are missing or stale, the approve note says
  the approval upgrades the database first, and a long value on the running card
  (a log path) wraps at phone width.

### Fixed

- **The Deployment page no longer invites the same request twice.** A request waits for the deploy daemon's next poll, up to five minutes, and until then the page showed the old mode, so on 2026-11-18 the same mode change was sent four times. Now a waiting mode change is shown checked, with a note that the deployer applies it at its next poll; a waiting approval shows as approved; a mode, pause or resume that repeats the last waiting request of its kind, or an approval already waiting, is not written again; and saving the mode already in force sends nothing.

### Added

- **A Coming next card on production's Deployment page.** Production's deployer still never deploys a pre-release on its own, in any mode. It now offers the newest one (`v0.X.0-rc.N`) on the admin page, with its notes and the `minor-release` pull requests it carries, and deploys it only when an admin types its version and approves it. While production runs an approved rc, the release that follows it in the same minor waits for approval in `gated-minors`, because it carries whatever merged after that rc. `get_deploy_status` reports the offered pre-release (`prereleaseVersion`). See "Approving a pre-release on production" in `docs/release-gate.md`.

### Fixed

- **An approved pre-release with no image no longer holds production's deploys.** If the image of an rc approved on the Deployment page is still not deployable after two hours, production's deployer drops the approval, records `approve expired` in the deploy history, and deploys releases as usual. The rc stays offered on the Coming next card, so an admin can approve it again once its image exists.

### Changed

- **The held release's notes read as notes on the admin Deployment page.** Each release is a card, and each category (Changed, Fixed) is a small heading above its own list, where before it was a bold bullet of one flat list. The bullets sit inside the text column instead of hanging outside it. The contract changes and the approval form are padded cards too (`.card--padded`), and the contract-change list no longer repeats its heading as a badge on every line.

### Added

- **The deploy daemon upgrades PostgreSQL before a release that needs it.** A
  release declares its PostgreSQL major in `deploy/db-target-major` (now `18`).
  When it is higher than the running one, the release waits for approval in
  every mode, and the approval runs `scripts/db-major-upgrade.sh` and then the
  blue-green deploy. A failed upgrade rolls back, deploys nothing and waits for
  a new approval; an interrupted one is rolled back with `--recover` when the
  daemon starts. The admin Deployment page warns on the held and Coming next
  cards, `get_deploy_status` reports the running and declared majors and the
  upgrade state, and a failed upgrade fires the `deployerUnhealthy` alert
  (#3149).

### Security

- **The images no longer carry the base image's unused `pebble` binary.** The `ubuntu:26.04` base ships Canonical's pebble service manager as a loose file that no package owns, so no `apt-get upgrade` patches it. Its Go standard library (1.27.3) has CVE-2026-97054 (HIGH), which failed the image vulnerability gate on every Docker build. Nothing in Chickadee runs pebble, so the runtime stage deletes it.

### Removed

- **scipy and statsmodels are no longer in the browser Python kernel.** They,
  and `openblas`, `patsy` and `six`, which only they needed, were about 27 MB of
  a ~69 MB environment, roughly 40% of every Python kernel boot, and no course
  needed them in the browser. A browser-graded test that imports either one is
  now refused when it is saved, and a student notebook that imports one gets
  `ModuleNotFoundError` in the editor. Worker-graded assignments are unaffected:
  they run on the runner's own Python. #3122 revisits the decision before the
  next minor.

### Changed

- **The browser grading cells are part of the student contract.** The four
  grading cells (`Public/python-grading-shared.js`,
  `Public/r-grading-shared.js`, `Public/lua-grading-shared.js` and
  `Public/octave-grading-shared.js`), the shared exit-code mapping
  (`Public/grading-shared.js`) and the kernel boot
  (`Public/xeus-kernel-shared.js`) decide how a browser-graded test is run and
  scored, so a change to them now ships only in a minor
  (`scripts/contract-paths.txt`, `docs/release-gate.md`).

### Changed

- **The browser JS tests use the shared settle helper and fake clock.** Fifteen `.mjs` suites that settled promise chains with real `setTimeout(0)` turns or counted `Promise.resolve()` loops now call `flushMicrotasks` from `support/dom-stub.mjs`, and the freeze-watchdog and workbench-poll suites drive their timers with the shared `FakeClock`; suites whose code under test schedules a real timer keep their `setTimeout` turn.

### Changed

- **The xeus kernels are built from locks, and two builds give the same
  bytes.** `scripts/lock-kernel-envs.py` locks each
  `Tools/jupyterlite/environment-*.yml` into `Tools/jupyterlite/locks/`, naming
  every package file by URL and sha256. `scripts/build-jupyterlite.sh` installs
  each kernel from its lock at a fixed path and never solves, so a rebuild no
  longer upgrades every package. The kernel binaries no longer carry a random
  build directory, every package archive is written without a time or an
  owner, and the build's task database no longer survives between builds. A
  pull request run of the re-vendor workflow now fails when the committed
  kernels are not exactly what the locks build. Publish mode locks again
  before it builds. `scripts/lock-kernel-envs.py --check` runs in the
  JupyterLite job.
- **The JupyterLite toolchain is installed with hashes.**
  `Tools/jupyterlite/requirements.in` holds the pins, and `requirements.txt` is
  compiled from it by pip-compile, with every package, transitive ones
  included, pinned and hashed. CI installs a pinned micromamba (2.10.0),
  checked by sha256, in place of `latest`.
- **The first re-vendor after this change rewrites every kernel archive once.**
  Archives keep their names unless the build already renamed them; only the
  time and owner inside each one change. Boot-time behaviour is unchanged.

### Changed

- **The classmate chooser reads five columns, not whole submissions.** `latestStudentSubmissionsByUser` picks each student's newest complete submission and its id, owner, time, filename and path in one SQL statement, as a `LatestStudentSubmission`, instead of loading every picked row as a full model with its materialization blob. It runs on the claim path of every class activity job.

### Fixed

- **The live board's 304 tests no longer flake.** The refresh reads its time from the app's clock (`LiveBoardClock`), which the tests pin, so two refreshes of an unchanged board share one 30-second ETag bucket. Production still reads the wall clock.

### Changed

- **A Python test no longer rebuilds matplotlib's font cache.** The sandbox gives each test script an empty home directory, so matplotlib found no font cache and parsed every font on the runner again in every test whose submission imports `matplotlib.pyplot`, inside the test's time limit. The runner image now builds the cache once, and the Python bootstrap copies it into the fresh home directory before the submission loads. On the runner image this cuts the `pyplot` import from about 348 ms to 260 ms per test, so a 36-test pandas and matplotlib assignment spends about 3 s less per submission. A runner outside the image keeps the old behaviour, and a cache that does not match the installed matplotlib is rebuilt by matplotlib as before.

### Changed

- **MCP test helpers live in one kit.** The OAuth PKCE and consent helpers that five suites copied now live in `Tests/APITests/MCPOAuthTestKit.swift`, and the hand-built MCP tool and admin tool contexts use `mcpContext` and the new `adminMCPContext`.

### Changed

- **Parallel test files are merged into the suite for their subject.** Twenty-four test files that the nightly steward added next to an existing suite, because it could not edit that suite, now live in that suite's file (as more tests in the same suite where the shape and traits match, else as a second suite that keeps its own traits), and five "Gap"-named files that were the only suite for their subject now carry a subject name; no test was added, removed or changed.

### Changed

- **The get_runner_detail tests join the admin MCP tool tests.** `GetRunnerDetailToolWallTests` is now a second suite, `GetRunnerDetailToolTests`, in `AdminMCPToolsTests.swift`, with its own time limit.

### Changed

- **Sixth migration consolidation round.** Eleven column migrations are folded into their `Create*` files: `AddActivitySessionNetworks`, `AddActivityStandingGroup`, `AddTournamentRunGroup`, `AddCompositeContributionGroup`, `AddClassCoverageRunGroup`, `AddCourseAchievements`, `AddContentItemAssignment`, `AddAssignmentType`, `AddSectionDefaultAssignmentType`, `AddCourseDatasetFormat` and `AddWardrobeUnlockSource`. The four one-time data migrations are deleted: `CollapseUserRoles`, `StripStarterNotebookOutputs`, `MoveLearnSectionCategoryToGroupSet` and `BackfillAssignmentType`. A fresh database gets the same schema in fewer steps. A database that already ran these migrations does not change, because Fluent ignores the history rows of migrations that are no longer registered. A database that has not run them must first start once on a release that still has them, such as v0.5.989. `RequireAssignmentSlug` and `DropCoveredIndexes` are new in this release and stay standalone.

### Changed

- **The mutation trend docs describe the equivalent-mutant ledger.** `docs/mutation-trend.md` now says that the trend's survivor count leaves out recorded equivalents, so a 100% score means the survivor queue is empty, not that every mutant was killed. It adds what the weekly sweep covers (`RunnerCore`, `Core` and `Worker`, not `APIServer`) and names a wrong ledger entry as a way the score can mislead. `trend.py`'s backlog note and `docs/mutation-triage.md` now say the same.

### Security

- **The notebook source route checks `submissionID`.** The route now accepts
  only the ID of a submission of this assignment that the caller may open, as
  the notebook page already did. Before, an unchecked ID went into a file path
  and could reach a file outside the caller's folder.

### Changed

- **Two npm development dependencies move to their newest patch within the declared ranges.** `minimatch` (under ESLint, at the repository root) goes from 11.0.8 to 11.0.9, and `axe-core` (under the visual-regression tool) goes from 4.14.0 to 4.14.1. Only the lockfiles change; no range changes, and nothing that ships to a student browser.

### Added

- **Health alert for a changed database collation version.** The new
  `collationVersionMismatch` rule fires when the database's collation library
  (glibc or ICU) no longer matches the version its indexes were built with,
  which a new image under the floating `postgres:18` tag can cause. Text
  indexes can then miss rows or admit duplicates; the alert names the fix
  (`REINDEX DATABASE`, then `REFRESH COLLATION VERSION`).
- **Guard against VIRTUAL generated columns.** PostgreSQL 18 makes a generated
  column VIRTUAL unless the migration says STORED; `GeneratedColumnStorageTests`
  fails on one that is not listed with a reason.

### Changed

- **Claude Code web sessions test on the PostgreSQL major production runs.** The
  session hook installs the major named in `deploy/db-target-major` (18) when
  the sandbox lacks it, and rebuilds a test data directory left by another
  major. Sessions had been running the suite on PostgreSQL 16.
- **The least-privilege MCP role script hashes its password with SCRAM-SHA-256
  explicitly**, whatever the server's default.

### Removed

- **Unreachable fallbacks.** The Swift fallbacks for a database without SQL are gone from the student submission aggregates, the admin runner load series and the pending-queue read of the health alerts. The server runs on Postgres only, so these paths ran only in tests. The health-alert sweep no longer has a branch for advisory (`info`) rules, because no rule has that severity. Also removed: the " / " title join in the unclaimable-jobs rule (a unique constraint allows one assignment per setup), an unreachable DNS refusal in the support-file URL fetcher, and the unused `POST` verb in the BrightSpace client. Behaviour does not change.

### Changed

- **The xeus kernels are re-vendored to their channels' current builds.**
  `.github/workflows/revendor-kernels.yml` locked the unchanged
  `Tools/jupyterlite/environment-*.yml` files again
  (`Tools/jupyterlite/locks/`), rebuilt `Public/jupyterlite/` from the new
  locks and verified it before this pull request was opened.

### Fixed

- **A runner's check-in writes its freshness once per minute, not once per slot.** The slots of one runner check in at about the same moment. Each read the same aged profile row and saved every column of it again. Production ran one such write per runner about every 22 s, against the 60 s debounce. Now an unchanged check-in updates only `last_seen_at`, and only when the stored value has aged, so the first slot's write lands and the others change no row. `last_registered_at` now moves only when a runner registers or changes its profile or name.

### Changed

- **Shared enrollment, user and zip fixtures in the API tests.** `makeTestEnrollment` takes an optional per-course `role`, and the private copies of it, of `makeTestUser`, of `makeTestCourse`, of `writeSetupZip` and the pass-through `arMakeZip`, `ahMakeZip` and `makeZipAt` aliases of `writeZipFixture` are gone, so each fixture has one definition.

### Changed

- **One log capture and one forwarding database for the API tests.** Thirteen private capturing log handlers become `CapturedLog` (`Tests/APITests/LogCapture.swift`) and seven private forwarding Fluent databases become `ForwardingTestDatabase`, which re-wraps its transactions and connections so a refusal rule reaches nested work.

### Changed

- **Two oversized test files are split along their seams.** `CourseBundleTests` becomes export, import validation, import records and round-trip suites that share `CourseBundleRouteFixtures`, and `AdminRoutesTests` keeps its core routes while user deletion, course management and the runners tab move to their own suites that share `AdminRouteFixtures`; every test moves unchanged.

### Changed

- **The notebook web-route tests are split by section.** `NotebookWebRoutesTests` (2,300 lines) is now four suites, for page access, the editor save, the template view and the remaining routes, which share one `NotebookWebRoutesFixture`; every test is unchanged.

### Security

- **SSO login checks the ID token's nonce, authorized party and issue time.** The login now sends a fresh `nonce` and refuses an ID token that does not carry it back, an `azp` that names another client (or a multi-audience token with no `azp`), and an `iat` more than five minutes in the future (OIDC Core 3.1.3.7). The test of a callback with no code now reaches the missing-code check instead of stopping at the state check.

### Security

- **Course bundle import checks content item links.** The import now applies the
  same link rule as the content item form and MCP. A bundle with a content item
  link that is not http(s) or site-relative, for example a `javascript:` link, is
  refused before anything is saved, and the error names the item and the link.

### Fixed

- **A failed assignment clone no longer leaves a setup row.** The web clone route (`POST /instructor/:assignmentID/clone`) now runs the clone in one database transaction, as the course clone does. A clone that failed after it saved the new `test_setups` row used to remove the copied files but keep the row with no zip (#3214).

### Fixed

- **A content item keeps every file that an instructor selects.** The file input on the add-material form and on the edit form of a content item had the bare name `attachmentFiles`. The server decoded several parts with that name as one file, so only the last file was stored. Both inputs are now named `attachmentFiles[]`, and each selected file is stored in order.

### Fixed

- **A refused upload on content item create no longer keeps the item.** The web create handler (`POST /instructor/content-items`) now checks every attached file before it saves the item, and removes the new item if a file write fails. A refused upload used to return 400 but keep the item with no attachments (#3214).

### Security

- **Course content links refuse protocol-relative URLs.** A content item link
  that starts with `//` or `/\` linked off the site, but the site-relative
  check accepted it. The web form and the MCP content item tools now refuse
  it with the same error as a `javascript:` link.

### Changed

- **One course-delete route test.** `DeleteCourseCoverageTests` and `DeleteCourseDatasetDealsTests` are folded into one test in `StudentWorkDeletionCoverageTests`, which deletes a course through the admin route and checks that another course's coverage and deal rows stay.

### Changed

- **Test the copied-solution source for a declared language and a zipped solution.** `ClonedSolutionSourceTests` now checks that a copy of an R assignment writes `solution.R`, and that a solution stored as a zip is read for the notebook inside it.

### Changed

- **Test where the runner writes an extracted notebook.** `SubmissionNormalizerEdgeCaseTests` now checks that an extracted notebook keeps counting past a taken numbered name (`hw.extracted.2.py`), and that a notebook saved under another extension in a folder extracts in that folder.

### Changed

- **Tests for uncovered instructor and admin routes.** New tests cover `GET` and `PUT /instructor/:assignmentID/global-variables` (a save by a TA, a refused save, a student), `GET /instructor/metrics/cards` (only the active course counts; no active course gives no windows), `PUT /instructor/new/draft/suite` and `DELETE /instructor/new/draft/scripts/:filename`, and the banner that each Deployment page notice shows. No product code changed.

### Changed

- **Tests for uncovered MCP tool and dispatcher paths.** New tests cover the `author_script` refusals (a generated script, a graded test sent as a support file, a grader-only file on a browser-graded assignment) and the grader-only mark and unmark, the `move_suite_item` refusals for an unknown item and its no-op move, the `preview_personalization` fallback to the acting account's own seed, the resource-method scope and missing-URI refusals, a `notifications/initialized` call that has an id, and the audit target rules. No product code changed.

### Changed

- **More tests for the notebook and JupyterLite contents routes.** The notebook
  routes now have tests for an unknown setup, a reset with no assignment or no
  starter, and the closed gate on the source route. The contents routes now
  have tests for text and base64 file content, folder order, a missing file or
  folder, a path above the drive, a student path that steps out of its folder,
  and an unenrolled student's read-only copy.

### Changed

- **Tests for six more uncovered paths.** New suites cover the deploy state folder (history order and limit, a bad history line, a failed request write), the position fallback that restores personalized notebook cells, the Racket call context and per-student preamble, the Octave rule that the first omitted argument ends the list, the pandas `ignoreIndex: false` mode, and the runner fleet duration and size formats. No product code changed.

### Changed

- **Tests for seven more uncovered paths.** New suites cover the pattern-family header refusals (family id, case key, blank label, duplicate variable and parameter names), the differential, return-type and performance-threshold case checks, a family or notebook check that depends on an unknown family, the C++ call context (an omitted argument ends the list, a variable reference, no input, a family variable that hides a section variable), notebook substitution on input that is not a notebook, the one-file-or-many multipart decoder, and the stored-filename fallback. No product code changed.

### Added

- **Tests for the LEARN admin routes, course binding and instructor connection.** New suites run the admin Valence callback, the pasted-key and connection-test routes, org-unit verification, grade-item auto-mapping and the instructor connect step against a scripted D2L, with no network.

### Changed

- **Tests for seven more uncovered paths.** New suites cover the runner compatibility reasons (no profile, a platform mismatch, a version that does not parse), the manifest helpers on a manifest that does not decode and on an unknown grading or submission mode, the partial-credit label on a hidden test, the requirement suggestions from the entries of a test setup zip, the hidden-tier filter on a test cell that names no tier, the bundled-solution link in the Files panel, and the section grouping and order tie-break of the assignment lists. No product code changed.

### Added

- **Tests for the instructor LEARN routes and the LEARN group sync.** New suites drive the BrightSpace tab actions (connection test, connect, take over the sync identity, bind the org unit, the grade-item feed, auto-map, reconcile now) and the "Check against LEARN" route against a scripted D2L, and cover the group-sync sweep loop and its monitor. No product code changed.

### Changed

- **Tests for the unclaimable-jobs read and the database statement statistics.** New suites cover how the unclaimable-jobs health rule reads its jobs (pending only, the minimum wait, the retest time, the stored runner profiles, the assignment requirement, and the names of the blocked setups), and how `QueryStatistics` checks for pg_stat_statements, creates the extension at startup, and reads the statement rows, totals and reset time. No product code changed.

### Added

- **Tests for compute-expected and the global-inputs refusals.** New suites cover the `compute-expected` route (its refusals, a real Python solution call, and an undefined function in every language) and the `GlobalInputsService` validation and save-time evaluation errors. No product code changed.

### Changed

- **Tests for the coverage section and the notebook scaffold.** New suites cover the instructor's class-coverage rows for a contribution assignment (suite order, uncovered items, a covered item no longer in the suite, a finder with no account, the slots of a class composite), the class-corpus coverage wording, and the one-shot section scaffold from a solution notebook (a fresh setup, a non-Python language, and the setups it must leave alone). No product code changed.

### Added

- **Tests for the data-export, stuck-submission and LTI grade sweeps.** New suites cover what the data-export reaper deletes and keeps (including a zip it cannot delete), the export generation failure, cancel and zip-replace paths, the stuck-submission and AGS sweep monitors, and the AGS rows the sweep deletes or drops without a score.

### Changed

- **Tests for the health-alert monitor and its database rules.** New suites cover which alert webhook URL wins (the admin override, the saved file, the environment value) and that an override is saved and cleared, a test alert whose page is refused, the cap on the recent-firings list, a sweep that records a failed page, pages once inside the cooldown and records the resolve, the boot time stamp when alerts are off, the system-failure rate over the most recent grading jobs, the BrightSpace alert's list of failing assignments, and an unreachable database that stops the rules that need it. No product code changed.

### Added

- **Tests for the authoring snapshot loader and the assignment version store failure paths.** New suites pin what `check_assignment` loads (notebook cells, a missing setup zip, the variant batch behind the student-data wall, one expression evaluation per variant seed) and how version recording and blob reclamation fail safe.

### Changed

- **Tests for the refusals of the support-file URL fetcher.** A new suite covers the error text that an agent reads for each refusal, a URL that does not parse, a host that the client would read differently from the checked host, the real resolver on `localhost` and on obfuscated numeric hosts, and `fetch` and `fetchData` refusing a loopback or cloud-metadata host before they connect. No product code changed.

### Added

- **Tests for the runner start command and the job cgroup fallback.** New worker tests start `chickadee-runner` end to end (an invalid API base URL, a missing secret, a start that drains on SIGTERM), check the sandbox-on startup checks, and check that a command whose job cgroup cannot be created is still graded and leaves no cgroup behind.

### Changed

- **Tests for the LEARN roster sweep and the BrightSpace sync bookkeeping.** New suites cover the course loop of the roster-readiness sweep (a course with no org unit, an identity that does not resolve, a classlist read that fails, the summary log line) and its monitor, and the failure paths of the grade-sync bookkeeping: a lost row save while a failure is recorded, a lost sync-log row, the "Sync now" requeue of errored overrides and removals, and the background sweep that "Sync now" starts. No product code changed.

### Added

- **Tests for the BrightSpace sync sweep and the deadline monitor.** New tests cover the classlist-outage fallback to the student-number lookup, a pending override whose student also has a pending result, the chunking of large `IN` filters, one tick of the grade-sync and deadline monitors, and the group-session refusal text.

### Changed

- **Tests for the new-assignment draft solution and suite actions, and the runner load fallbacks.** New suites cover the draft actions that create a blank solution, copy the assignment notebook into the solution, upload, clear and refuse a solution for an upload-only language, and rebuild the suite from uploaded files with the grading mode of the chosen type. Other new suites cover the tie rule of the peak runner load and the Swift fallbacks of the runner load and time-series summaries, which must agree with the SQL path. No product code changed.

### Added

- **Tests for the notebook draft-backup notice and the per-group tournament control.** New suites render the notebook body from a notebook context (the kept-draft notice, the task outline and guide, the iframe flags) and read the instructor submissions page for an activity that runs once per lab group, with and without lab groups.

### Changed

- **Tests for the notebook working-copy store.** New suites cover the refresh that keeps a copy differing only in its outputs and rewrites a changed one, the template view that seeds from the stored starter and not from a submission, a submission that is not a notebook, the personalization fallbacks (a manifest that does not decode, a failed substitution, expressions with no seed, an expression that raises), the refusals when a past submission is opened, and the logged failures of a support-file link and a shared-dataset link. No product code changed.

### Added

- **Tests for the instructor dashboard, Groups tab and grades CSV.** New suites pin the exact grades CSV columns, order and escaping, whose rows each export holds, the Groups tab refusals (another course, a TA, a bad form, a LEARN set), the status and open refusals, the cross-course reorder refusal, and the unpublished-setup delete with its files.

### Changed

- **Tests for the test-setup routes.** A new suite covers the upload refusals (a manifest that is not JSON, a browser setup with no notebook, a worker setup with no suites, a zip that does not open), the flat notebook that a browser upload stores, the setup zip download (not found, a student refused, the instructor served), every refusal of the support-file download and the file it serves, and the notebook save (an empty body, a body that is not JSON, a setup that already has a notebook path). No product code changed.

### Added

- **Tests for diagnostics failure paths and the leaderboard builders.** New suites check that a failed diagnostics write logs one warning with no student identifier, that the queue-depth fallback counts what the SQL count does, and that the leaderboard ranks highest first with ties, hides names from students, and shows a superseded bracket and a union viewer with no submission correctly.

### Changed

- **Tests for the admin course and runner routes.** New suites cover the refusals of the admin course routes (a blank create form, a delete of a course that is not archived, bad ids, an unknown per-course role, a role change for a user who is not enrolled, an unknown user, a CSV enroll into an archived or unknown course, a student who posts to an admin route), the course-page unenroll and the CSV enroll, the LEARN org-unit binding on the course edit form, and the runner detail page for a pruned or unknown runner, the time-limit note, the cache hit rate and the capability tags. No product code changed.

### Added

- **Tests for the runner-facing API gaps.** A new suite covers the 409 for a workerID that another host holds, the language gate refusing a runner end to end, the download base URL order (configured URL, forwarded headers, Host header, bind address), unsigned heartbeat and result requests that store nothing, the class corpus and best-effort result kinds, and the claim on a store without SQL. No product code changed.

### Changed

- **Tests for the staff per-student pages and actions.** A new suite covers the per-student submissions page (section grouping, a class-record badge and a disabled one, the jump badge from the prior attempt), the 404 for an unknown course and for an assignment of another course, the refusal of an extension with no valid date, the per-student notebook reset and its refusal when the setup has no starter, and the 403 for a course student and for staff of another course. No product code changed.

### Added

- **Tests for tournament opponent choice, the sweep lease and validation runner autostart.** New suites cover the opponent a tournament match job stages (never the submitter, a superseded upload or a student of another course), the claim failure when a download link cannot be built, the periodic sweep tick without the lease or with a failed lease check, the sweep lifecycle handler, the sidecar a cloned validation carries, and the local-runner autostart branches of the validation runner probes.

### Changed

- **Tests for the uncovered paths of the runner prepare phase.** New suites cover the download of a submission opponent (single and matrix) before it is staged, the extraction of an archive submission and the submission entry limit it applies, the starter-notebook cleanup, the extract-to-source arm of the submission normalization (the refusal of protected files and the student-module hint), and the timing of a successful make step. No product code changed.

### Added

- **Tests for the runner job paths and submission staging edges.** New suites drive whole jobs through the runner against a scripted server and check what it reports: a seeded job, per-test time limits, a matrix job and its match rows, a missing script, a suite with no scripts and a failed `make` step (both a collection-level build failure), retried and terminal poll errors, and two non-HTTP download failures. Staging tests cover the free-space probe, merges from a missing or linked source, the last Python heuristic, and the `WorkerDaemonError` messages.

### Changed

- **Tests for the refusals of the SSO login routes.** A new suite covers an authorization URL that cannot be built, a callback with a valid state but no code, a token endpoint that refuses every request shape or answers with a body that does not decode, the fallback to the client-secret-post request shape, an expired ID token, an ID token signed with an untrusted key, an ID token from another issuer, an SSO username that a local account already holds, the display-name fallback to given and family name, and the audit entry for a role change from the admin allowlist. No product code changed.

### Added

- **Tests for the login lockout, the login rate limit and the roster refusals.** Two new suites cover the per-IP 429 of the login rate limit and its reset when the minute passes, the per-username lockout and its reset when the window passes, the case-insensitive lockout key, the last X-Forwarded-For entry as the rate-limit key, the stale-row sweep, the IdP end-session return address on logout, a TA and an instructor of another course refused every roster change with the roster unchanged, the per-course role change, the last-instructor guard, and the malformed-id and missing-row refusals of the roster routes. No product code changed.

### Changed

- **Tests for the BrightSpace API client.** New suites drive the real D2L client against a scripted HTTP client. They cover the API version pin, cache and fallback, the one clock-skew retry after a timestamp error, and how each read and write maps a refusal to its own error: the user lookup, whoami, the org unit and grade item reads, the grade push and clear, the paged classlist and the group readers. No product code changed.

### Added

- **Tests for content items and the AI-feedback wall.** New tests cover content-item attachment uploads, refused link URLs and ids, the course scope of the MCP account, and the two AI-assisted feedback gates: no MCP path sets a gate, clone does not carry one, and written answers come from a zipped submission's notebook.

### Changed

- **Tests for the Swift fallbacks of the student submission aggregates.** A new suite reaches the four non-SQL fallbacks of the dashboard and roster loaders (latest submission and attempt count per setup and per student, and the best grade per setup and per student) through a database wrapper that is not an SQL database. It checks the latest-pick order and its tie-break, the scoping to student attempts, the 0% rule of each fold, the 99% cap on a partial mark, and that each fallback gives the same answer as the SQL path. No product code changed.

### Added

- **Tests for the admin gate and the runner-detail diagnostics tool.** New suites check that a course instructor who is not a deployment admin is refused every admin page and form, the role, alert-webhook and test-alert refusals, and that `get_runner_detail` on the admin diagnostics MCP refuses a blank runner id, a call without `diagnostics:read` and a non-admin, resolves a runner known only by snapshots, and never returns per-job rows or a student identifier. No product code changed.

### Added

- **Tests for three authoring paths.** New suites cover the section-inputs route of a published assignment (names checked in the declared language, an expression refused without a language, the TA, student and other-course gates), the language a new-assignment draft declares (each language, "none", upload-only, an unknown value, the notebook scaffold, resuming a draft from another course, and the publish that keeps the draft's sections), and the failure paths of the authoring service that remove the files they wrote. No product code changed.

### Added

- **Tests for section inputs, the coverage fallback and achievement row refusals.** New suites cover the section expression checks and save-time evaluation of `SectionInputsService`, the plain-database path of the class and lab item coverage, and the achievement editor refusals that no test reached. No product code changed.

### Added

- **Tests for the UW important-dates cache, the GitHub installation listing and the configuration summary.** New suites drive the UW dates fetch and its 24-hour cache with a scripted client, the paging and error mapping of the live `installationByAccountID` call, and each optional line of `AppConfig.logSummary` with its secrets redacted.

### Changed

- **Tests cover more manifest and enrollment edits.** New tests check that an edit of a deleted setup is not found, that a grader-only mark is added once and removed, that an unknown grading or submission mode is refused, that both language writers refuse to make browser grading effective on an Assignment, that a malformed username in a roster is reported and not recorded, and how a failure-detail setting is parsed.

### Changed

- **Tests run each reaper monitor's sweep.** Ten periodic monitors (audit log, diagnostics prune, login attempts, sessions, stale data exports, client diagnostics, activity events, worker nonces, MCP OAuth records and class-goal achievements) now have a test that runs one sweep through the monitor and checks what it removed or wrote.

### Added

- **Tests for the runner's retry-delay range, stale-claim results and zipped opponents.** New tests check that a retry delay outside 0 ms to one hour falls back to its default and is logged, that a result the server refuses for a stale claim is dropped with its log event, that a zipped champion submission is extracted for a match, and the two error descriptions no test read. No product code changed.

### Added

- **Tests for the runner's script launch failure, its 1 MB output cap and executable helpers.** `ScriptExecutionTests` (renamed from `ScriptExecutionGapTests`) now checks that a launch that cannot start reports exit code 2 with its prefix, and that output over 1 MB is cut at the limit, marked once, and does not stop a chatty script from finishing. `ScriptInvocationTests` checks that an executable file of unknown type runs as itself. No product code changed.

### Fixed

- **Failure masking, the submission diff and the notebook scans split CRLF lines on every platform.** In Swift "\r\n" is one character, so splitting on "\n" did not split CRLF text on Linux and left a "\r" on each line on macOS. Student code can print CRLF, and the `actualOnly` failure mask then kept a whole message as one `got:` line, with the expected value. A CRLF student file also diffed as one changed line, and a CRLF notebook cell lost its section heading and its later definitions. A new Core helper, `textLines`, splits on CRLF, LF and CR. These sites and the UW important dates parser use it.

### Changed

- **Dependabot: remove the expired untarjs 5.4.0 ignore.** The entry held back a broken release until 2026-11-12. The lockfile now resolves 5.4.1, and Dependabot does not move a package down, so the entry no longer has an effect.

### Changed

- **Enrollment contract checks that a refusal changes nothing.** The MCP enrollment-denial contract now compares every row of the target course before and after each refused call, so three per-tool copies of that check are gone.

### Fixed

- **A refused attachment on MCP `create_content_item` no longer keeps the item.** The tool now fetches and checks every attachment before it saves the item, and removes the new item if a file write fails after the checks. The cheap checks (the https rule and the file type from the URL) run on every attachment before the first fetch. A refused attachment used to return an error but keep the item with no attachments. `update_content_item` still keeps its edit when an attachment is refused, but it now writes no file until every attachment is fetched and checked.

### Changed

- **Tests for four mutation survivors in the personalization helpers.** A steward mutation run on six pure files in `Sources/APIServer/Utilities` found four survivors in `PersonalizationPlaceholders` and `PersonalizedCellRestoration`. A new suite, `PersonalizationTemplateHelpersTests`, kills each one. No product code changes.

### Changed

- **Tests for nine mutation survivors in the assignment-type rules and the personalization substitution.** A steward mutation run on five pure files in `Sources/APIServer/Utilities` found six survivors in `AssignmentTypeRules` and three in `PersonalizationSubstitution`. Two new suites, `AssignmentTypeRulesProseTests` and `PersonalizationSubstitutionSectionTests`, kill each one. No product code changes.

### Changed

- **Database-free tests for the live board ETag, from a mutation run on five more APIServer helpers.** A steward mutation run on `DeployMode`, `DeployReleaseNotes`, `RunnerVersionReport`, `TierFilter` and `LiveBoardETag` in `Sources/APIServer/Utilities` found no survivor in the first four. `LiveBoardETag` had only tests that need a database, so a new suite, `LiveBoardETagTests`, checks the tag without one. Its one survivor, the staff-or-student word swapped, cannot change any tag comparison, and `Tools/mutation/equivalent-mutants.json` records why. No product code changes.

### Changed

- **Tests for the support-file list, from a mutation run on six more APIServer helpers.** A steward mutation run on `ClientNetwork`, `SecretFile`, `SupportFileNames`, `WorkerClaimToken`, `FreshShortID` and `CourseRoleFloor` in `Sources/APIServer/Utilities` found one survivor: `currentSupportFileNames` had no test, so its filter could keep a suite script as a support file and no test failed. A new database-free suite, `SupportFileNamesTests`, kills it. No product code changes.

### Changed

- **Boundary tests for the alert-summary wording.** A steward mutation run on four helpers in `Sources/APIServer/Utilities` (`AlertText`, `LanguageProse`, `GeneratedMessageVocabulary`, `AchievementSignalPresentation`) gave four mutants, and the existing tests killed all four. A boundary check by hand found that no test held a list of exactly five names, so "and 0 more" could appear in an alert summary without a failure. The new suite `AlertTextBoundaryTests` holds the list at the limit and the durations on each hour and day boundary. No product code changes.

### Security

- **The course-switch redirect no longer accepts a backslash.** The `next` value of the course-switch form refused `//host` but accepted `/\host`, which a browser reads as `//host`, so it could send a signed-in user to another site. It now uses the shared `isSafeLocalPath` check. The queued MCP sign-in return path had the same gap; no route can store such a value there today, but it now uses the same check. The editor-reset return path uses it too, in place of its own copy of the rule.

### Fixed

- **The runner no longer retries a download that cannot succeed.** A transport error that the same request cannot get past (a bad or unsupported URL, a missing or unreadable local file, a body over the size limit) now fails the download at once. Before, every `URLError` used the full download retry budget. Network, DNS and TLS errors stay retryable. The server sends only HTTP URLs, so production was not affected.

### Changed

- **Slowest suites in the CI summary.** Each Swift test lane now writes its 20 slowest suites, from the xUnit report, to the job summary. The step never fails the job.

### Removed

- **Non-SQL fallbacks in class activities.** The Swift fallbacks for a database without SQL are gone from the class and lab coverage writes, the leaderboard submission counts and the latest-submission read of the classmate chooser. They now throw `AppError.internalFailure`.

### Removed

- **Non-SQL fallbacks in diagnostics and admin reads.** The Swift fallbacks for a database without SQL are gone from the request timing series, the pending queue depth, the runner job counts, the admin assignment counts, the runner last-seen read, the user activity chart and the retention submission counts. The server runs on Postgres only, so these paths ran only in tests. They now throw `AppError.internalFailure`.

### Removed

- **Non-SQL fallbacks in grading.** The Swift fallbacks for a database without SQL are gone from the runner pending-work probe and pending count, the validation variant write, the submission status read, the best-grade reads and the BrightSpace pending flag of a grade override. They now throw.

### Removed

- **Non-SQL fallbacks in the remaining reads and writes.** The instructor submitter counts, grades export and submission timestamps, the BrightSpace sync flags, the LTI grade sync queue and the session user lookup no longer have a Swift path for a database without SQL. The single-use burn, the MCP upload claim and the refresh token rotation no longer answer "won" on such a database; they now throw.

### Changed

- **Swift package pins are current.** Twelve root-package pins move to their newest patch releases: async-http-client 1.37.1, jwt-kit 5.9.1, swift-asn1 1.7.5, swift-certificates 1.21.2, swift-crypto 5.1.2, swift-log 1.17.2, swift-metrics 2.13.1, swift-nio 2.105.1, swift-nio-extras 1.35.3, swift-nio-http2 1.46.1, swift-nio-ssl 2.37.7 and vapor 4.122.4. The `wasm/` pins were already current.

### Changed

- **The nightly steward may edit existing tests.** The test-edit hook lets a change through on a `steward/` branch, and the steward rules now say to extend the suite that already tests a type, and to move a private helper into shared test support instead of copying it.

### Changed

- **One multipart form helper in the API tests.** The private multipart body builders in five test files now call the shared `arMultipartBody`, and the repeated POSTs of a multipart form and of the student upload form now go through the new shared `postMultipartForm` and `wrPostSubmitUpload`. Each request keeps the same parts in the same order, and each test checks the same results.

### Changed

- **Shorter subprocess deadline test and plain test teardowns.** `BoundedSubprocessTests` waits 2.5 s instead of 3.5 s for its teardown check. The pattern-family fixture and the seed-pool tests tear their apps down through `withApp`; the two-app helper says why it cannot.

### Changed

- **Unused test imports removed.** Twelve API test files no longer import `Crypto`, which none of them used.

### Fixed

- **The UW important dates feed parses CRLF lines on Linux.** RFC 5545 requires CRLF line endings. In Swift "\r\n" is one character, so splitting on "\n" did not split a CRLF feed on Linux, and the parser found no events. The parser now splits on CRLF, LF and CR, so a standard feed gives its events in production.

### Security

- **The upload form checks course enrollment on submit.** `POST /testsetups/:id/submit` checked enrollment only through the assignment row, so a draft or a REST-uploaded test setup, which has no assignment row, took a submission from any signed-in user. The route now checks enrollment first, as the form page does.

### Changed

- **Sweep tests no longer poll on a wall clock.** `PeriodicSweepMonitor.sweepOnce` runs one leased tick and returns when it ends. Eleven sweep tests await it instead of starting the loop and polling every 25 ms for up to 10 seconds.

### Fixed

- **The Swift currency step records its exit status when the check is red.** GitHub runs `shell: bash` with `-e`, so a red check ended the step before it wrote the status. The step now turns `-e` off around the check, as `repeat-test.yml` and `mutation-probe.yml` do. This completes the fix for #3270.

### Fixed

- **The Swift currency issue names the right kind of red.** The check now sends its exit status to the report job in its artifact. Before, the report job read an empty job output and filed "cannot run" for a run that found 12 pins behind (#3270).

### Removed

- **The old test-app helper names are gone.** `withAssignmentRoutesApp` and `withWebRoutesApp` were pass-through names for `withTestApp`; their 865 call sites in 149 test files now call `withTestApp`.

### Fixed

- **Test apps no longer write state files into the checkout.** `makeTestApp` now puts the alert webhook file, the LTI tool key and the GitHub App secrets file in its per-app temporary directory, like the worker secret. Before, a test that saved the alert webhook wrote or removed `.alert-webhook-url` in the repository.

### Removed

- **Test-suite cleanup.** Removed seven per-tool MCP enrollment-denial tests that `MCPEnrollmentDenialContractTests` already covers, two scope-gate tests that `AdminMCPDispatcherTests` covers, and the Swift runner-bucket reference code (`RunnerBucketAccumulator`, `accumulateRunnerSnapshots`, `summarizeRunnerBuckets`) that only tests called. Zip and python tests now skip through host-condition traits instead of a silent `return`, and three suites gained time limits.

### Changed

- **Best-so-far rows and composite contributions are written in one
  statement.** The leaderboard rows, the ranked class records and a student's
  composite contribution used an existence check, a conditional update, an
  insert and a retry on conflict. Each is now one `INSERT … ON CONFLICT … DO
  UPDATE … WHERE` statement: two to four round trips become one, and the
  insert-then-catch path that the SQLite backend needed is gone.

### Changed

- **Worker tests share one daemon factory.** `Tests/WorkerTests/Support/DaemonTestSupport.swift` now holds the `NoJobPoller` and `NoopReporter` stubs and `makeTestDaemon`, replacing ten private copies across the worker test suites.

### Changed

- **WorkerTests is grouped by subject.** The runner's test files move into `Daemon`, `Grading`, `Matrix`, `Notebooks`, `RunnerProfile`, `Sandbox`, `Scripts`, `Submissions` and `TestSetupCache` folders, and the small `TestSetupCache`, `RunnerProfileDetector`, `SubmissionNormalizer` and `SubmissionStaging` fragments join their main suite's file.


