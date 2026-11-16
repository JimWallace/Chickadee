# Load testing

`chickadee-loadtest` simulates load on a server and reports the latency that
each request stream sees. Use it to measure a change before the change
reaches production. It has two subcommands:

- `hot-paths`, the default: deadline traffic on the two routes with the most
  traffic. The sections up to "Compare two versions" describe it.
- `lecture`: one browser-graded class activity in a lecture, with 150
  students by default. See "A lecture activity".

## The hot paths

| Stream | Route | What the server does for each request |
|---|---|---|
| Runner poll | `POST /api/v1/worker/request` | HMAC check, nonce insert, runner check-in, pending-work query, and a claim when work is pending |
| Status poll | `GET /api/v1/submissions/:id` | Session lookup, submission read, access check |

A real runner slot asks the server to hold an idle poll for up to 20 s
(`WorkerLongPoll`), so each idle slot sends about three polls a minute. The
tool's simulated runners do not ask for a hold, so `--runner-poll-interval`
sets their rate directly. A result view polls
every 2 s while its submission is pending. During a deadline, both streams
grow with the number of runners and students.

## Safety

- **Do not run the tool against production.** A simulated runner sends a real
  poll. If a job is pending that any runner can grade, the simulated runner
  claims it. The job then stays assigned until the server times it out. The
  report shows a `WARNING` line when this occurs.
- The tool refuses a host that is not a loopback host (`localhost`,
  `127.0.0.1`, `::1`). For a staging server, add `--allow-remote`.
- The simulated runners use the IDs `loadtest-runner-0`, `loadtest-runner-1`,
  and so on, with the hostname `chickadee-loadtest`. They appear on the admin
  runner page until they age out.

## Run it

Start a local server first. The server writes its runner secret to
`.worker-secret` in its working directory. Run the tool in that directory, or
give the path of the file with `--runner-secret-file`.

Build the tool:

```sh
swift build -c release --product chickadee-loadtest
```

Run 50 runner slots that each poll every second, for two minutes:

```sh
.build/release/chickadee-loadtest --runners 50 --runner-poll-interval 1 --duration 120
```

To add status polls, you need the ID of a submission and the `Cookie` header
of a session that can read it. Sign in with a browser, open a submission, and
copy the `Cookie` request header from the developer tools. Then run:

```sh
.build/release/chickadee-loadtest --runners 20 --status-pollers 300 --submission-id SUBMISSION_ID --session-cookie "COOKIE_HEADER" --duration 120
```

Replace `SUBMISSION_ID` and `COOKIE_HEADER` with your values. Use
`--status-pollers` with `--runners 0` to load only the status route.

## Read the report

For each stream, the report gives:

- the number of requests, and the rate per second
- the count of each HTTP status
- the number of requests that got no reply (refused, reset or timed out)
- p50, p95 and p99 latency and the maximum, in milliseconds, measured at the
  client

An idle runner poll returns 204. A status of 401 on the runner poll means that
the secret does not match the server. A status of 401 on the status poll means
that the cookie is not signed in.

The server measures the same routes from its side. After a run, read
`hotPaths` in `/admin/metrics`, or call the admin MCP tool
`get_metrics_snapshot` (see `docs/operational-diagnostics.md` §"Hot-path
counts"). If the client latency is much larger than the server latency, the
time goes to the network or to the queue in front of the server, not to the
route.

## Compare two versions

1. Run the tool against the base version, with fixed options, and keep the
   report.
2. Apply the change, restart the server, and run the tool again with the same
   options.
3. Compare p95 and p99. One run of a few seconds is noise. Use at least
   60 s, and repeat each run.

Concurrent claims (`WorkerJobClaim.claimSubmission`) depend on Postgres row
locks. Measure against a Postgres configured like production's.

## A lecture activity

`chickadee-loadtest lecture` simulates the four phases of a class activity
that the whole lecture does at the same time. It is work item W1 of the
live-lecture plan (pull request #2540). Each simulated student does what the
browser does:

| Phase | Stream | What the student sends |
|---|---|---|
| Join | `GET /testsetups/:id/notebook` | The notebook page |
| Join | Kernel boot file | Every file in the page's `data-kernel-assets` list, six at a time |
| Submit | `GET /api/v1/browser-runner/testsetups/:id/download`, `/seed`, `/manifest` | The browser grader's three downloads |
| Submit | `POST /api/v1/submissions/browser-result` | A result that passes every suite entry, with the student's own `metric` |
| Submit | `GET /api/v1/submissions/:id` | The status poll, every 2 s, until the result is stored |
| Watch | `GET /testsetups/:id/leaderboard?fragment=body` | The board's background refresh every 5 s, with the last ETag |

The work phase sends nothing, because the editor runs in the browser.

**Timeline.** The students join over `--join-window` seconds (30). The first
student submits at `--work-seconds` (60), and the last one by the end of
`--submit-window` (60). The board is watched for `--watch-seconds` (60) more.
A student watches the board from the end of their join to the end of the run.

**Join modes.** `--join cold` (the default) downloads every boot file.
`--join warm` simulates browsers that have the files from an earlier visit:
before the run, the tool fetches each file once and reads its headers. A warm
student then skips each immutable file and revalidates the others with
`If-None-Match` or `If-Modified-Since`. `--join page` fetches the page only.

### Set up the activity

The tool needs a server with local accounts and an activity it can grade:

- **The server.** Run it with `AUTH_MODE=local` (or `dual`), and with
  `LOGIN_RATE_LIMIT_ENABLED=false`. The rate limit allows 10 sign-ins a
  minute from one address, and the tool signs in every student from one
  address. Do not turn the limit off on a server that students use.
- **An admin first.** The first account on a new database becomes the admin.
  Register your own account before the first run, so that a simulated
  student does not become the admin.
- **The course.** It must be open for self-enrolment (the default). Pass its
  ID with `--course-id`.
- **The activity.** An open, browser-graded assignment in that course, with
  a ranked activity (`bestMetric`), so the board has rows. Pass its test setup
  ID with `--test-setup-id`.

The first run registers `loadtest-student-0` to `loadtest-student-149` (change
the prefix with `--student-prefix`), enrols them in the course, and saves
their sessions in `.loadtest-lecture-sessions`. Later runs reuse the saved
sessions. If the server reports redirects, the sessions have expired: delete
the file, and the next run signs the students in again.

The safety rules of the hot-path run apply. Never point the tool at
production. A remote server needs `--allow-remote`.

### Run it

```sh
swift build -c release --product chickadee-loadtest
```

```sh
.build/release/chickadee-loadtest lecture --test-setup-id SETUP_ID --course-id COURSE_ID
```

Replace `SETUP_ID` and `COURSE_ID` with your values. Then run again with
`--join warm`, which is the case the join target is written for.

### Read the report

The report has a block for each stream, as the hot-path run has, plus the
bytes the stream received. Two blocks are spans per student, not requests:

- **Join:** from the page request to the last kernel file.
- **Result visible after submit:** from the first submit download to the
  status poll that reads the result as stored.

The report ends with the plan's targets:

| Target | How the tool checks it |
|---|---|
| Warm join, p95 under 5 s | The join span, in a `--join warm` run |
| Result visible after submit, p95 under 10 s | The result span |
| No server errors | No 5xx and no request without a reply, in every stream |
| A change reaches the projector within 5 s | Not measured |
| Database CPU under 50% while the board is watched | Not measured: read it on the database host |

Before a run against a staging server, reset the statement statistics. After
it, read `hotPaths` and `get_query_stats` (see
`docs/database-performance.md`).

### Baseline, 2026-11-16

A local run on a Mac Studio, over loopback, against a debug build on
Postgres 16, with 150 students and the default timeline. The activity has one
public test and a Python kernel of 51 boot files (64.6 MB).

| Stream | Requests | p50 | p95 | p99 |
|---|---|---|---|---|
| Notebook page | 150 | 24 ms | 30 ms | 34 ms |
| Kernel boot file (cold) | 7,650, 9.7 GB | 3 ms | 71 ms | 133 ms |
| Board refresh | 4,911 (27 per second) | 293 ms | 1,647 ms | 1,986 ms |
| Setup download | 150 | 48 ms | 351 ms | 770 ms |
| Result post | 150 | 39 ms | 93 ms | 241 ms |
| Status poll | 150 | 4 ms | 14 ms | 59 ms |
| Result visible (span) | 150 students | 179 ms | 669 ms | 1,054 ms |

No request failed. The board refresh is the slowest stream by a factor of
ten, as risk R2 of the plan predicts: every refresh rebuilds the whole board
for its viewer. Loopback hides the network, so a cold join here does not show
what 9.7 GB costs on a lecture hall's shared Wi-Fi.
