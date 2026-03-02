# chickadee-server

Vapor 4 app. Exposes a REST API for workers and instructors, and a Leaf-rendered web UI for browser access.

---

## CLI startup

Run server mode with:

```bash
chickadee-server serve --port 8080 --worker-secret your-secret
```

`--worker-secret` sets the runner shared secret persisted by the server. The local auto-launched runner receives this as `RUNNER_SHARED_SECRET` (with legacy `WORKER_SHARED_SECRET` also set for compatibility).

---

## HTTPS / proxy settings

For production SSO rollouts, run Chickadee behind HTTPS (typically terminated at a reverse proxy/load balancer) and set:

- `PUBLIC_BASE_URL` (example: `https://chickadee.example.edu`) for externally-visible absolute URL construction.
- `ENFORCE_HTTPS=true` to redirect plain-HTTP GET/HEAD requests to HTTPS and reject other insecure requests.
- `TRUST_X_FORWARDED_PROTO=true` (default) when TLS is terminated upstream and `X-Forwarded-Proto` is forwarded.
- `SESSION_COOKIE_SECURE=true` to force the session cookie `Secure` attribute.

If unset, defaults preserve current local development behavior.

---

## Auth mode defaults

- Chickadee now defaults to `sso` auth mode when `AUTH_MODE` is unset.
- To allow non-SSO modes (`local` or `dual`), set `ENABLE_NON_SSO_AUTH_MODES=true`.
- With the flag disabled, `AUTH_MODE=local` or `AUTH_MODE=dual` is ignored and `sso` is used.

---

## REST API

Base path: `/api/v1`

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/submissions` | Submit a zip for grading |
| `GET`  | `/submissions` | List submissions; optional `?testSetupID=` filter |
| `GET`  | `/submissions/:id` | Submission status (`pending`/`assigned`/`complete`/`failed`) |
| `GET`  | `/submissions/:id/results` | Full `TestOutcomeCollection`; optional `?tiers=` filter |
| `POST` | `/worker/request` | Worker claims the next pending job |
| `POST` | `/worker/results` | Worker reports a completed `TestOutcomeCollection` |
| `POST` | `/testsetups` | Instructor uploads a test-setup zip (multipart) |
| `GET`  | `/testsetups/:id/download` | Download a test-setup zip |

### Query parameters

**`GET /submissions`** — `?testSetupID=<id>` filters to submissions for a single test setup.

**`GET /submissions/:id/results`** — `?tiers=public,student` filters which tiers are included in the response. Aggregate counts (`passCount`, `failCount`, etc.) are recomputed to match the filtered set.

---

## Web UI

Browser-facing routes rendered with Leaf templates. No authentication — all submissions are anonymous for MVP.

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/` | Home page — lists all test setups |
| `GET`  | `/testsetups/new` | Instructor upload form |
| `POST` | `/testsetups/new` | Handle upload; redirect to `/` |
| `GET`  | `/testsetups/:id/submit` | Student submission form |
| `POST` | `/testsetups/:id/submit` | Save submission; redirect to `/submissions/:id` |
| `GET`  | `/submissions/:id` | Live results page (polls API until complete) |

Templates live in `Resources/Views/`. Static assets (CSS, JS) are served from `Public/`.

---

## Test setup manifest

Stored as `test.properties.json` at the root of the instructor-uploaded zip.

```json
{
  "schemaVersion": 1,
  "requiredFiles": ["warmup.py"],
  "testSuites": [
    { "tier": "public",  "script": "test_public.sh"  },
    { "tier": "release", "script": "test_release.sh" },
    { "tier": "student", "script": "test_student.sh" }
  ],
  "timeLimitSeconds": 10,
  "makefile": null
}
```

When `makefile` is non-null, a `make` step runs before the test scripts. Set `"target": null` for bare `make` or `"target": "test"` for `make test`.

---

## Test tiers

| Tier | Shown to student |
|------|-----------------|
| `public` | Immediately after submission |
| `release` | Hidden until deadline; unlocked on demand |
| `secret` | Never shown |
| `student` | Student-written tests, always visible |
