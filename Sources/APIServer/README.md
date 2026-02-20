# chickadee-server

Vapor 4 app. Exposes a REST API for workers and instructors, and a Leaf-rendered web UI for browser access.

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
