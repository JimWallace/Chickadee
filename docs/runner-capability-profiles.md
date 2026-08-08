# Runner Capability Profiles

Chickadee can now match queued jobs against explicit runner capability profiles.
This is a backend-only feature: there is no admin UI yet, and rollout is
designed to stay compatible with existing assignments and existing runners.

## What Was Added

- `runner_profiles`
  - durable server-side records of each runner's advertised capabilities
- `assignment_requirements`
  - optional per-assignment requirements for platform, architecture, languages,
    and named capabilities
- compatibility matching in `POST /api/v1/worker/request`
  - jobs are only assigned when the polling runner is compatible
- runner capability advertisement on poll and heartbeat
  - protected by the existing HMAC-signed runner protocol

## Runner Profiles

Each runner profile records:

- `runner_id`
- optional `display_name`
- `platform`
- `architecture`
- `language_versions`
- `capabilities`
- optional `profile_hash`
- `last_registered_at`
- `last_seen_at`
- `is_active`

`language_versions` and `capabilities` are stored as JSON-backed structured
fields so SQLite stays simple now and a future PostgreSQL migration remains
straightforward.

Example profile shape:

```json
{
  "platform": "linux",
  "architecture": "x86_64",
  "languageVersions": [
    { "language": "python", "version": "3.11.8" },
    { "language": "r", "version": "4.3.2" }
  ],
  "capabilities": [
    { "name": "numpy" },
    { "name": "pandas" },
    { "name": "shell-bash" }
  ]
}
```

## Assignment Requirements

Assignment requirements are optional. If an assignment has no requirement row,
it behaves exactly as before.

Each requirement record can specify:

- `required_platform`
- `required_architecture`
- `required_languages`
- `required_capabilities`

Supported language rules are intentionally simple:

- exact version
- minimum version

Supported examples:

- Python `>= 3.10`
- R `>= 4.2`
- Swift `== 6.0`

Unsupported in this rollout:

- version ranges
- OR clauses
- package version constraints
- automatic dependency installation

Example requirement shape:

```json
{
  "requiredPlatform": "linux",
  "requiredArchitecture": "x86_64",
  "requiredLanguages": [
    { "language": "python", "minimumVersion": "3.10" }
  ],
  "requiredCapabilities": [
    { "name": "numpy" },
    { "name": "pandas" }
  ]
}
```

## Matching Rules

A runner is compatible when all of the following are true:

1. `platform` matches, if the assignment specifies one
2. `architecture` matches, if the assignment specifies one
3. every required language is present and satisfies its version rule
4. every required capability is present

Matching is deterministic and returns explicit reasons when a runner is
incompatible, for example:

- `missing language python`
- `python version 3.9 < required 3.10`
- `missing capability pandas`
- `architecture arm64 != required x86_64`
- `runner profile unavailable`
- `runner version 0.4.639 < required minimum 0.5.0`

## Minimum Runner Version Gate (manifest)

Separate from the capability profile above, a test setup's **manifest** may carry
an optional `minimumRunnerVersion` (`TestProperties.minimumRunnerVersion`). It
gates on the runner's *Chickadee build version* — `ChickadeeVersion.current`,
advertised as `runnerVersion` on every poll — rather than on installed platform /
language / package capabilities. Use it when a suite depends on behaviour only
present in a newer `chickadee-runner` build.

- **Optional and opt-in.** `nil` (every manifest written before the field, and
  every un-gated assignment) means no gate, and the manifest is byte-for-byte
  unchanged. A plain semver string like `"0.5.0"` enables it.
- **Enforced server-side at claim time.** The same `POST /api/v1/worker/request`
  claim path that runs capability matching also compares the polling runner's
  advertised version against the gate; the two verdicts are merged, so a version
  block surfaces through the identical diagnostics
  (`no_compatible_runner_available`) and leaves the submission `pending` until a
  new-enough runner polls. It is deliberately *not* a runner-side check: an older
  runner has no gate code, so only the server can reliably keep old runners off a
  gated job.
- **Fail-closed on an unparseable runner version**, but only when a gate is set;
  a `nil`/blank gate short-circuits without parsing, so un-gated assignments —
  and runners advertising a non-semver version — are unaffected.
- **Worker path only.** Browser (`gradingMode: browser`) grading runs the
  server's own vended WASM bundle, which has no runner version, so the gate never
  applies there (it can still bite a browser submission that fails over to the
  worker backstop).
- **Stripped from the runner-facing manifest.** The gate is a server-side
  dispatch concern; `runnerSanitized()` drops it, so the runner never receives it
  and old runners can't choke on it.

Authoring: set or clear it over MCP with `set_minimum_runner_version` (a
metadata-only edit — no regrade or close), or include it in the uploaded manifest
/ a `.chickadee` course bundle. A malformed value is rejected at upload time.
`get_suite` and `get_assignment` report the current value.

### Authoring rule: gate on the release that shipped the feature

**Every assignment that depends on runner-side behaviour added in release *X*
must carry `minimumRunnerVersion: X`, set when the assignment is authored.**
This is written down rather than left to judgement because it is a mistake this
project keeps repeating.

Why it is not optional, and why testing does not catch it:

- **The fleet is mixed by construction.** The server auto-deploys on merge
  ([docs/zero-downtime-deploy.md](zero-downtime-deploy.md)); runners are separate
  hosts upgraded on their own schedule. Several `chickadee-runner` versions are
  polling at any moment.
- **The failure is nondeterministic, so validation does not surface it.** Claim
  order decides which runner grades a job. An ungated assignment validates green
  whenever a capable runner happens to poll first, and the identical assignment
  fails for the next student whose job an older runner claims.
- **The failure does not look like a version problem.** An old runner has no
  interpreter for the new language, so the symptom is exit 127 / "not found" / a
  suite of `error` outcomes. It reads as a broken test script and gets debugged
  as one, on the assignment rather than on the fleet.
- **Browser-graded assignments are not exempt.** Instructor validation is
  enqueued as a `kind == .validation` submission and graded by the native worker
  regardless of `gradingMode`, and a browser submission that fails over to the
  worker backstop lands there too.

Support landed in:

| Feature | Gate at |
|---|---|
| Lua assignments | `0.5.23` |
| Octave assignments | `0.5.24` |
| C++ assignments | `0.5.27` |

### Why capability requirements are not a substitute

The two mechanisms fail in opposite directions, and only the version gate is
reliable for "this runner build is too old":

- `requiredLanguages` matches what a runner **advertises**.
  `RunnerProfileDetector` hand-lists the interpreters it probes, so a runner
  built before the language existed never advertises it *however the host is
  provisioned*. Requiring the language therefore matches **no** runner and queues
  the assignment's jobs forever — the worse of the two failures, and the one the
  Lua audit sweep had to fix.
- `minimumRunnerVersion` compares against `runnerVersion`, which every runner has
  always advertised. An old runner is excluded correctly without having to know
  anything about the feature.

Use capability requirements for "this host lacks a package or toolchain" and the
version gate for "this build predates the feature". A new language wants the
version gate; adding a language requirement as well is safe only once every
runner in the fleet advertises it.

## Rollout And Backwards Compatibility

The rollout rules are:

- old assignments with no requirements still run on old runners
- old assignments with no requirements still run on new runners
- new assignments with requirements do not run on runners that have no profile
- new assignments with requirements only run on compatible runners

This means capability filtering can be adopted gradually without breaking
existing courses.

## Runner Capability Discovery

Runners detect capabilities best-effort at startup and include the resulting
profile in poll and heartbeat payloads.

Currently detected automatically:

- platform
- architecture
- `python3 --version`
- `R --version`
- `swift --version`
- Python package presence via import probes:
  - `numpy`
  - `pandas`
  - `scipy`
  - `matplotlib`
- shell availability:
  - `shell-bash`
  - `shell-zsh`

Detection failures do not crash the runner. Missing tools simply do not appear
in the advertised profile.

Configuration:

- `RUNNER_CAPABILITY_DISCOVERY_ENABLED`
  - default: enabled
  - set to `false` to suppress profile discovery and advertisement

## How Assignments Declare Requirements

This PR keeps requirement declaration backend-only. There is no admin form yet.

For now, requirements are managed by creating or updating a row in
`assignment_requirements` for the target assignment.

Example SQLite session for a Python assignment:

```sql
INSERT INTO assignment_requirements (
  id,
  assignment_id,
  required_platform,
  required_architecture,
  required_languages_json,
  required_capabilities_json,
  created_at,
  updated_at
) VALUES (
  'REQUIREMENT-UUID-HERE',
  'ASSIGNMENT-UUID-HERE',
  'linux',
  'x86_64',
  '[{"language":"python","minimumVersion":"3.10"}]',
  '[{"name":"numpy"},{"name":"pandas"}]',
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP
);
```

Example R assignment requirement payload:

```json
{
  "requiredPlatform": "linux",
  "requiredLanguages": [
    { "language": "r", "minimumVersion": "4.2" }
  ]
}
```

## Observability

Structured server logs now include:

- `runner_profile_registered`
- `runner_profile_updated`
- `assignment_requirements_loaded`
- `compatibility_check_passed`
- `compatibility_check_failed`
- `no_compatible_runner_available`
- `job_assigned_to_compatible_runner`

The admin JSON metrics endpoint also exposes compatibility counters since the
current server start:

- `compatibleAssignmentAttempts`
- `incompatibleAssignmentAttempts`
- `jobsBlockedNoCompatibleRunner`

## Troubleshooting

No compatible runner available:

- confirm the assignment has a requirement row
- query `/admin/metrics` and server logs for
  `event == "no_compatible_runner_available"`
- verify the runner is advertising a profile

Runner missing `numpy`:

- on the runner host, check `python3 -c "import numpy"`
- ensure `RUNNER_CAPABILITY_DISCOVERY_ENABLED` is not disabled
- restart the runner so it re-advertises the profile

Language version too low:

- inspect `runner_profiles.language_versions_json`
- compare with the assignment's `required_languages_json`
- upgrade the toolchain on that runner or relax the assignment requirement

Old runner is not picking up a requiremented assignment:

- this is expected until the runner is upgraded to advertise a profile
- jobs with requirements treat a missing runner profile as incompatible

## Future Work

Not included in this rollout:

- package version constraints
- richer R package detection
- admin UI for profiles or requirements
- smarter scheduling among multiple compatible runners
- profile-based autoscaling
