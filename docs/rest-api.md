# REST API reference

This document describes Chickadee's HTTP interfaces for programs: the runner
protocol, the `/api/v1` JSON endpoints, the JupyterLite contents API, and the
endpoints that other systems call (LTI, GitHub, OAuth and MCP). The web UI's
HTML pages are not covered here.

The source is the reference. Each section names the file that registers its
routes, and `Sources/APIServer/routes.swift` shows which authentication guards
each group. When this document and the code disagree, the code is right and
this document needs a fix.

**Stability.** Chickadee is at 0.y.z, so any interface may change in a minor
release ([release-process.md](release-process.md)). Two of them are versioned
contracts with their own rules:

- The runner protocol is checked by `minimumRunnerVersion` and the runner
  capability profile ([runner-capability-profiles.md](runner-capability-profiles.md)).
- The browser-grading endpoints serve a student's cached grader, so they change
  only in a minor release ([release-gate.md](release-gate.md)).

The instructor editor endpoints (listed at the end) belong to the web UI and
change with it.

---

## Conventions

| | |
|---|---|
| Base URL | The deployment's origin, for example `https://chickadee.example.edu`. |
| JSON | Requests and responses use `application/json`, unless an endpoint says otherwise. |
| Dates | ISO 8601 strings, for example `2026-11-25T12:00:00Z`. |
| IDs | Submission and test setup IDs are opaque strings. User and course IDs are UUIDs. |
| Errors | A path under `/api/` answers an error with a JSON body: `{"error": true, "status": 404, "reason": "..."}`. Other paths answer with an HTML error page. |

Status codes used throughout:

| Code | Meaning |
|---|---|
| 200, 201, 202, 204 | Success. 201 for a created test setup, 202 for an accepted diagnostic, 204 when there is nothing to return. |
| 304 | Not modified, for a request that sent a matching `If-None-Match`. |
| 400 | The request is malformed or not allowed for this assignment. |
| 401 | No valid credentials. |
| 403 | Authenticated, but not allowed: wrong course, wrong role, an assignment that is not open, or a missing CSRF token. |
| 404 | No such resource, or a feature the deployment has turned off. |
| 409 | A runner ID that another active runner holds. |
| 410 | A result report for a job that was reassigned to another runner. |
| 413 | The body is over the endpoint's size limit. |
| 422 | The body parsed but failed validation (manifest, result collection, notebook JSON). |
| 429 | A rate limit. |

---

## Authentication

Chickadee has four kinds of caller. Each endpoint below names its kind.

### Session (browser users)

A user signs in on the web UI (`/login`, or `/auth/sso/start` under SSO) and
gets a session cookie. Every session request also passes through
`RoleMiddleware`, and `/instructor/*` and `/admin/*` check the course role or
the admin role ([multi-course-roles.md](multi-course-roles.md)).

**CSRF.** A session request with a method other than `GET`, `HEAD` or
`OPTIONS` must carry a CSRF token. The token goes in a header (`X-CSRF-Token`,
`CSRF-Token`, `X-XSRF-Token` or `X-CSRFToken`) or in a `_csrf` form field.
Pages put the current token in a `<meta name="csrf-token">` tag. A request
without one gets `403 No CSRF token provided.`

**Course scope.** Roles are per course. An endpoint that names a test setup
or submission checks the caller's role in *that* course, not a global role. A
student reaches only their own submissions and the assignments of courses they
are enrolled in.

### Runner (HMAC)

`chickadee-runner` signs every request with a secret it shares with the
server. The runner reads it from `RUNNER_SHARED_SECRET`. The server takes
`RUNNER_SHARED_SECRET`, or `--worker-secret`, or generates one and keeps it in
a `.worker-secret` file. The algorithm lives in `Sources/Core/WorkerHMACSigning.swift`,
which both sides compile, so they cannot drift.

| Header | Value |
|---|---|
| `X-Worker-Timestamp` | Unix seconds, as a decimal string. Must be within 60 s of the server clock. |
| `X-Worker-Nonce` | A unique string per request. A nonce is accepted once; a reuse within 300 s is a replay. |
| `X-Worker-Body-SHA256` | Lowercase hex SHA-256 of the request body (of the empty string for a `GET`). |
| `X-Worker-Signature` | Lowercase hex HMAC-SHA256, under the shared secret, of `METHOD\nPATH\nBODY_SHA256\nTIMESTAMP\nNONCE`. |
| `X-Worker-Id` | The runner ID (optional, at most 256 bytes). |

Every failure is a `401` with a reason: a missing header, a timestamp outside
the window, a bad signature, a body that does not match its hash, or a replay.

### Bearer token (MCP)

The MCP endpoints take an OAuth 2.1 bearer token, from the browser OAuth flow
or minted by an admin. See the README section "MCP content-authoring server",
[admin-mcp.md](admin-mcp.md) and [mcp-file-uploads.md](mcp-file-uploads.md).

### Signed by a third party

The GitHub webhook and the LTI launch carry their own signatures (an HMAC over
the body, and a platform-signed JWT). See their sections.

---

## Public endpoints

### `GET /health`

No authentication. For load balancers and monitoring. Registered in
`Sources/APIServer/Routes/HealthRoutes.swift`.

```json
{ "status": "ok", "version": "0.6.3", "db": "ok", "runner": { "recentActivity": true } }
```

- `200` with `"status": "ok"` when the database answers.
- `503` with `"status": "degraded"` and `"db": "error"` when it does not.
- `runner.recentActivity` is true when a runner checked in within the last
  120 seconds. It does not affect the status code.

### Other public paths

| Path | Purpose |
|---|---|
| `GET /favicon.svg`, `GET /avatar-icon/:version/:file` | Tab icons. |
| `GET /.well-known/oauth-protected-resource`, `/.well-known/oauth-authorization-server`, `/.well-known/jwks.json` | OAuth discovery for MCP clients (only while MCP is on). |
| `GET /lti/jwks` | The tool's public key set for LTI platforms. |

---

## Runner protocol

HMAC authentication. Registered in `WorkerJobRoutes.swift`,
`WorkerArtifactRoutes.swift` and `ResultRoutes.swift`. The runner side is
`Sources/Worker/`.

### `POST /api/v1/worker/request`

Ask for a job. Body: `WorkerActivityPayload` (`Sources/Core/Models/WorkerActivityPayload.swift`).

| Field | Type | |
|---|---|---|
| `workerID` | string | The runner's ID (`--worker-id`). |
| `hostname` | string | |
| `runnerVersion` | string | |
| `maxConcurrentJobs` | int | |
| `activeJobs` | int | |
| `profile` | object, optional | The capability profile: languages and tools the runner has. A job whose languages it lacks is not offered to it. |
| `longPollSeconds` | int, optional | Ask the server to hold the request open while no job is ready. The server grants at most 20 s. |

Responses:

- `200` with a `Job` (`Sources/Core/Job.swift`): `submissionID`,
  `testSetupID`, `attemptNumber`, `submissionURL` and `testSetupURL` (the two
  download endpoints below), the `manifest`, and the per-student inputs
  (`assignmentSeed`, `personalizedInputs`, `personalizedFiles`), the
  `language`, any `opponent`/`opponents` for class activities, and a
  `claimToken` that the result report must return.
- `204` when no job is ready. After a held poll, the response carries
  `Chickadee-Poll-Held: 1`, and the runner polls again at once.
- `409` when another runner with the same `workerID`, on another host, checked
  in within the last 90 s.

### `POST /api/v1/worker/heartbeat`

Same body as `request`. Records that the runner is alive while it grades.
Returns `200`.

### `GET /api/v1/worker/submissions/:submissionID/download`

Streams the submission's file. For a reference-solution or starter run with
personalization, it streams the copy with the placeholders already filled in.

### `GET /api/v1/worker/testsetups/:testSetupID/download`

Streams the test setup zip. The manifest is not in the zip; it comes with the
job.

### `POST /api/v1/worker/results`

Report a graded job. Body: `WorkerExecutionReport`, which carries the
`TestOutcomeCollection` (`Sources/Core/Models/TestOutcomeCollection.swift`),
with ISO 8601 dates. Body limit 32 MB; the server also truncates an oversized
collection before it stores it.

- `200` with `{"received": true}`.
- `422` for a body that does not decode.
- `410` when the claim is stale (the job was reassigned): the report is
  refused, and the submission keeps its newer claim.

The outcome of each test follows the test script contract in `CLAUDE.md`:
four statuses (`pass`, `fail`, `error`, `timeout`), a `score` in 0...1, and an
optional `metric`.

---

## Submissions

Session authentication. Registered in `SubmissionQueryRoutes.swift`,
`SubmissionRoutes.swift` and `BrowserResultRoutes.swift`.

### `GET /api/v1/submissions`

List submissions, newest first.

| Query | |
|---|---|
| `testSetupID` | Only this assignment's submissions. |
| `limit` | Default 500, from 1 to 5000. |
| `offset` | Default 0. |

A student gets only their own submissions. Course staff with a `testSetupID`
of their course get every submission for it. An admin gets all.

```json
{ "submissions": [
  { "submissionID": "...", "testSetupID": "...", "status": "complete",
    "attemptNumber": 3, "submittedAt": "2026-11-25T12:00:00Z" } ] }
```

`status` is one of `pending`, `assigned`, `running`, `complete`, `failed`.

### `GET /api/v1/submissions/:submissionID`

One submission's status, for polling while it grades. The owner or course
staff only.

```json
{ "submissionID": "...", "testSetupID": "...", "status": "running",
  "attemptNumber": 3, "submittedAt": "...", "assignedAt": "..." }
```

### `GET /api/v1/submissions/:submissionID/results`

The `TestOutcomeCollection` for a graded submission. The owner or course staff
only. `404` until results exist.

- **Tiers.** A student sees `public` results, `release` results after the
  effective deadline (the due date or their own extension, whichever is later),
  and `secret` results never, except through a granted reveal. Staff see every
  tier.
- **Failure detail.** A student sees each test's failure text as its entry's
  `failureDetail` setting allows ([failure-detail.md](failure-detail.md)).
  Staff see the full text.
- `?tiers=public,release` returns only those tiers, within what the caller may
  see.
- The response carries an `ETag`. Send it back in `If-None-Match` to get a
  `304` when nothing changed.

### `GET /api/v1/submissions/:submissionID/download`

Downloads the submitted file as an attachment. The owner or course staff only.

### `POST /api/v1/submissions` and `POST /api/v1/submissions/file`

Course staff only (TA and above in the test setup's course). Queue a
submission for a runner to grade, with no owner, for testing an assignment.
Students submit through the web UI or the browser-grading endpoints below.

- `POST /api/v1/submissions`: `{"testSetupID": "...", "zipBase64": "..."}`.
- `POST /api/v1/submissions/file`: `testSetupID`, `filename` and `file` (the
  bytes). A `.ipynb` has the instructor's hidden test cells merged back in.

Both return `{"submissionID": "..."}`.

---

## Browser grading

Session authentication. Students in the test setup's course, while the
assignment is open. These endpoints serve the in-browser grader
(`Public/browser-runner.js` and the grading executors), so they change only
in a minor release.

| Endpoint | |
|---|---|
| `GET /api/v1/browser-runner/testsetups/:id/download` | The test setup zip, for a browser-graded assignment. |
| `GET /api/v1/browser-runner/testsetups/:id/manifest` | The manifest JSON, read from the database. |
| `GET /api/v1/browser-runner/testsetups/:id/seed` | The caller's personalization: `seed`, `personalizedInputs`, `personalizedFiles`, `language`. |
| `POST /api/v1/submissions/browser-result` | Multipart: `testSetupID`, `notebook` (the `.ipynb` bytes) and `collection` (the `TestOutcomeCollection` as JSON text). Stores a graded submission. Returns `{"submissionID": "..."}`. `400` for an assignment that is not graded in the browser. |
| `POST /api/v1/submissions/browser-failover` | JSON: `testSetupID`, `notebook` (the `.ipynb` as text). When browser grading froze or failed, queue the notebook for a native runner instead. |
| `POST /api/v1/submissions/runner-submit` | Multipart: `testSetupID`, `notebook`, optional `filename`. A notebook submission for an assignment that a native runner grades. `400` for a browser-graded one. |

The submission endpoints apply the same gate as the web UI: enrollment, an
open assignment, and the deadline.

---

## Test setups

Session authentication. Registered in `TestSetupRoutes.swift`.

| Endpoint | Who | |
|---|---|---|
| `POST /api/v1/testsetups` | Instructor of the course | Multipart: `manifest` (the `test.properties.json` text), `files` (the zip), `courseID`. Validates the manifest and the suite, stores the setup. `201` with `{"testSetupID": "..."}`; `422` with the reason when validation fails. Limit 300 MB. |
| `GET /api/v1/testsetups/:id/download` | Instructor of the course | The full zip, with secret tests and solutions. |
| `GET /api/v1/testsetups/:id/assignment` | Enrolled users | The assignment notebook. Students get it with the `release` and `secret` cells removed, and only once the assignment is open. |
| `GET /api/v1/testsetups/:id/assignment/download` | Enrolled users | The same notebook, as an attachment named after the assignment. |
| `GET /api/v1/testsetups/:id/support/:filename` | Enrolled users | A support file from the zip. Test scripts, the notebooks and grader-only files are refused (`403`). |
| `PUT /api/v1/testsetups/:id/assignment` | Instructor of the course | Replace the notebook. The body is the raw notebook JSON. `204`. |

The manifest format is `TestProperties` (`Sources/Core/TestProperties.swift`).
The test scripts follow the test script contract in `CLAUDE.md`.

---

## Diagnostics and instructor data

| Endpoint | Auth | |
|---|---|---|
| `POST /api/v1/client-diagnostics` | Session | The editor page reports a browser-side failure or timing: `kind` (one of a fixed set, such as `preflight_fail`, `watchdog_timeout`, `editor_error`, `kernel_error`, `asset_load`), and optional `testSetupID`, `failedChecks`, `message`, `stack`, `source`, `appVersion`. Never student code. Rate-limited per user; always `202`, `400` for an unknown `kind`. |
| `GET /api/v1/uw-dates` | Course staff | Upcoming University of Waterloo important dates, for due-date warnings. `404` when the deployment turns the integration off. |
| `GET /admin/metrics`, `/admin/metrics/timeseries?hours=&bucketMinutes=`, `/admin/metrics/cards` | Admin | Server metrics as JSON, for the admin dashboard. See [operational-diagnostics.md](operational-diagnostics.md). |

---

## JupyterLite contents API

Session authentication. Registered in `JupyterLiteContentsRoutes.swift` and
`JupyterLiteContentsRoutes+Write.swift`. A subset of the Jupyter Server
contents API, so the embedded editor can keep a user's files on the server.

- `GET /jupyterlite/api/contents` and `GET /jupyterlite/api/contents/<path>`
  list a directory or return a file, in the Jupyter contents model. The same
  routes answer under `/api/contents`, `/lab/api/contents`,
  `/notebooks/api/contents` and the `/jupyterlite/lab/...` and
  `/jupyterlite/notebooks/...` prefixes, because JupyterLite asks under each.
- `PUT`, `POST`, `PATCH` and `DELETE` under `/jupyterlite/api/contents/` save,
  create, rename and delete. They reach only the caller's own `users/<id>/`
  folder, and a student's only while the assignment is open. A per-user quota
  and rate limit apply (`413` and `429`).

---

## Integrations

| Endpoint | Auth | Doc |
|---|---|---|
| `POST /github/webhook` | `X-Hub-Signature-256` over the body, under the GitHub App's webhook secret | [github-submissions.md](github-submissions.md). Records the head commit of a pushed course repository; never starts grading. `204` for every accepted event, `401` for a bad signature, `404` while no App is configured. |
| `GET`/`POST /lti/login`, `POST /lti/launch`, `GET /lti/jwks` | The platform's signed launch JWT | [lti-1-3.md](lti-1-3.md). LTI 1.3 OIDC login and resource launch. |
| `POST /lti/deep-link`, `POST /lti/deep-link/bind` | A single-use ticket in the form | [lti-1-3.md](lti-1-3.md), "Deep Linking". |
| `GET /auth/sso/start`, `GET /auth/sso/callback` | OIDC authorization code with PKCE | The README, "Local and SSO auth". Present unless `AUTH_MODE` is `local`. |

### MCP and OAuth

Present only while `MCP_MODE` is `read_only` or `read_write`.

| Endpoint | |
|---|---|
| `POST /mcp` | The content-authoring MCP server (JSON-RPC over HTTP). Bearer token. |
| `PUT`/`POST /mcp/uploads/:uploadID` | File uploads for MCP tools ([mcp-file-uploads.md](mcp-file-uploads.md)). |
| `POST /admin-mcp` | The read-only admin diagnostics MCP server ([admin-mcp.md](admin-mcp.md)). Bearer token with its own audience. |
| `GET`/`POST /oauth/authorize` | The consent page and its submit. |
| `POST /oauth/token`, `/oauth/revoke`, `/oauth/register` | Token exchange, revocation and dynamic client registration. |

The MCP tools themselves are listed by the server (`tools/list`) and by
`get_server_info`; they are not repeated here.

---

## Web UI endpoints (not a stable API)

The pages under `/instructor/`, `/admin/`, `/courses/` and the student pages
call JSON endpoints of their own: the suite editor (`GET`/`PUT
/instructor/:assignmentID/suite`, which also saves pattern families), script
editing, suite sections, the notebook save from the editor (`POST
/testsetups/:id/notebook/save`), the notebook guide
(`/testsetups/:id/notebook-guide.json`, `/instructor/:id/suite-outline.json`,
`/instructor/:id/preview-guide.json`) and others. They need a session and a
CSRF token, they change with the pages, and they are documented where they
are registered (`Sources/APIServer/Routes/Web/`) and in
[authoring-editors.md](authoring-editors.md) and
[notebook-guide.md](notebook-guide.md). Build on the endpoints above instead.
