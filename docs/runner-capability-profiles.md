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
