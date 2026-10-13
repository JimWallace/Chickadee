# Live lecture activities at 150 students

This document plans for one new way to use Chickadee: about 150 students who do
the same activity at the same time, during a lecture, with the result on the
projector. It gives the assumptions, the load that one lecture makes, the risks
in order, the decision about push or poll, and the plan to measure and fix the
system before the Winter term.

| Part | Status |
|---|---|
| Load model (this document) | Draft, 2026-10 |
| Measurement tools: `hotPaths`, `get_query_stats`, `chickadee-loadtest` | Shipped (#2531, #2539, #2533) |
| Lecture load-test scenario | Planned |
| Shared board cache and version number | Planned |
| Push channel (server-sent events) | Proposed |
| Join-cost fixes (kernel assets) | Immutable kernel packages in review (#2544); lite environment proposed |
| Dress rehearsals | Planned, before January |

## What the system does today

The system is reliable at these loads:

- About 150 students who submit before a weekly deadline. The submissions
  spread over hours or days.
- About 30 students who are live in an in-person lab.

A lecture activity puts all 150 students in the same two minutes, on pages that
poll, with a projector open. The two loads above do not tell us about this one.

## Assumptions

- **A1. Browser grading only.** A class activity is a participation grade. It
  is graded in the student's browser, so the native runners do no work. This
  document is about server load only.
- **A2. 150 students at the same time.** All join in about one minute, work for
  a few minutes, and submit in about one minute.
- **A3. One projector view**, open for the whole activity.
- **A4. Production topology.** One application container serves all traffic,
  behind the host nginx. During a blue-green cutover, two containers (colors)
  run for a short time. The database is Postgres.

### What A1 means for the activity kinds

Browser grading is refused today for any activity that stages an opponent
(`docs/class-activities.md` §"Browser grading is refused"). So under A1:

| Kind | Browser-graded today | Under A1 |
|---|---|---|
| `bestMetric` leaderboard | Yes | In scope |
| Class composite (`docs/class-composite.md`) | Planned: browser or worker | In scope; not built yet |
| Collaborative class assignment, class goals | Yes, except the bug hunt (grader-only files) | In scope, without the bug hunt |
| Bot, king of the hill | No (opponent) | Out of scope, or redesign |
| Round robin, tests-and-code | No (opponent) | Out of scope, or redesign |
| Tournament (elimination, Swiss) | No (opponent) | Out of scope, or redesign |

For a kind with an opponent, two redesigns are possible. In the first, the
student's browser also plays the opponents. That is N − 1 runs per student, in
the browser, so the cost moves from the runners to the students' laptops. In
the second, the projector browser plays the matches for the whole class. Both
are new designs, and this document does not plan them.

**A browser grade that fails goes to the native runners.** When the browser
cannot grade (an unsupported browser, a kernel that does not boot, an engine
that refuses an isolated worker), the page sends `POST
/api/v1/submissions/browser-failover`, and the native worker grades the
submission. The student sees no error. So A1 holds only if we turn off failover
for a class activity, or accept a small runner load from it. See work item W6.

## One lecture, in four phases

The numbers below are for 150 students. The request rates come from the client
code; the costs come from the server code. Each row says where the number
comes from. The lecture load test (W1) must confirm them before we trust them.

| Phase | What happens | Requests at 150 students | Server cost per request |
|---|---|---|---|
| 1. Join | Each student opens the activity page, and the browser boots a kernel to grade | 150 page loads; each kernel boot fetches 10–51 package files | Page: session read, user read, page queries, render. Kernel files: served by the app (see R1) |
| 2. Work | The student edits in the browser | Few. The editor's timers are local; the freeze watchdog reports only on a freeze | Small |
| 3. Submit | The browser grades and posts the result | Per student: test setup zip, seed and manifest downloads, then `POST /api/v1/submissions/browser-result`. About 600 requests in one minute | One ingest per result: submission and result writes, leaderboard upsert, coverage |
| 4. Watch | Every student and the projector watch the live board | Board: one poll per 5 s per viewer, so ~30 req/s. Status: one poll per 2 s while a result is pending, so up to ~75 req/s | Board: 8–10 queries, a full render, one `request_metrics` insert, per viewer, per poll (see R2) |

Sources: `Public/table-poll.js` (5000 ms default), `Public/app.js` (2000 ms
status poll), `Public/browser-runner.js` (setup, seed and manifest downloads,
then the result post), `Sources/APIServer/Routes/Web/WebRoutes+Leaderboard.swift`
(the board), `docs/kernel-boot-cost.md` (kernel sizes).

## Risks, in order

### R1. Join: the application serves every kernel file

In the containerised blue-green deployment, the host nginx cannot see the
container's `Public/` folder. So every static request, the kernel files
included, goes to the application (`deploy/nginx.conf`, the note above `root`).
The app serves them through `EditorAssetFastPathMiddleware`, before the session
chain.

| Kernel | Package files | Size on disk |
|---|---|---|
| Python | 48 | 58 MB |
| R | 51 | 60 MB |
| Octave | 11 | 78 MB |
| Lua | 10 | 13 MB |

The kernel packages carry `Cache-Control: no-cache`, so a browser that has them
still asks for each file again, and gets a 304.

- **Cold join:** 150 students who load the Python kernel for the first time ask
  the application for about 8.7 GB in one or two minutes. At 1 Gbit/s that is
  at least 70 s of full link use, before any other request.
- **Warm join:** about 48 × 150 = 7,200 revalidation requests in a minute or
  two. Each is cheap, but each is a request through the app.

This is the largest new risk, and grading in the browser causes it.
Mitigations, in order of cost:

1. **Warm the caches before the lecture.** Students open the activity page
   once before class, for example in the lab before. Then the lecture join is
   the warm case.
2. **Load packages on demand.** A bare Python kernel is 9.7 MB, not 58 MB
   (`docs/kernel-boot-cost.md` §"on demand"). An activity that needs only the
   standard library then costs much less to join.
3. **Serve the static files from the host nginx** in the blue-green topology.
   `docs/zero-downtime-deploy.md` describes what this needs. It takes the kernel
   files off the application completely.
4. **Make the kernel files immutable** by putting a content hash in their
   names, so a warm browser asks nothing. This is a change to the vendoring
   step.

### R2. Watch: each viewer rebuilds the whole board

- **No push, and no cache.** Every live view polls, and every poll rebuilds the
  board from the database. Nothing caches a board between polls or between
  viewers.
- **The ETag saves no server work.** `Response.pollFragment` computes it from
  the rendered HTML, after the queries and the render. A 304 saves bytes on the
  wire only.
- **Each student gets their own fragment.** It shows the student's own card and
  their own window of rows, so 150 viewers mean 150 full computations every
  5 seconds.
- **Each poll writes one row.** It inserts one `request_metrics` row, because
  only the three hot-path routes are exempt.

The board for an opponent kind is much heavier. The tests-and-code board reads
about 22,000 match rows on each poll. Under A1 that kind is out of scope, but
the same design problem applies to every board.

**Present mode stops only when its tab closes.** It decides at render time
whether to poll, and it has no stop time. An activity without a window, or with
an open-ended one, polls from the projector until someone closes the tab.

### R3. The status poll

The result page polls `GET /api/v1/submissions/:id` every 2 s while the result
is pending. Browser grading makes the pending time short, but a burst of 150
submissions still makes up to ~75 req/s. Each costs a session read, a user read
and a submission read. Since #2531, `hotPaths` in `/admin/metrics` shows the real
rate and latency of this route.

### R4. The submit burst

About 600 requests in one minute: three downloads and one result post per
student. The test setup zip is the same for every student, and its download
goes through the app. The result ingest writes the submission and the result,
upserts the leaderboard row, and records coverage. `get_query_stats` (#2539)
shows which of these statements cost the most, once the operator loads the
library.

### R5. Silent failover to the runners

See "What A1 means" above. One browser that cannot grade sends its work to the
runners, and the student sees nothing different.

### R6. A deploy during the lecture

A blue-green cutover moves traffic to a new container, which starts with empty
in-memory state: the hot-path counts, the caches, and (with push) every open
stream. The deployer can be paused on the host. A lecture-day runbook must say
to pause it (W8).

## Push or poll

The question is how a change (a new result) reaches 150 screens.

**Polling, made cheap.** Each change increases a version number for the
activity. The server builds the board once per version and keeps it in memory.
A poll then compares the version and answers 304 from memory, with no database
query. 150 viewers at 5 s is 30 req/s of near-free requests. The delay from a
change to a screen is up to 5 s.

**Push, with server-sent events (SSE).** Each viewer holds one open HTTP
response. When the version changes, the server writes one short event to every
stream, and each client then fetches the cached board. The delay is under one
second, and a quiet board costs nothing.

Both need the same foundation: a version number that the result ingest
increases, and one shared board per version. Without that, push only changes
when the 150 rebuilds happen. So the foundation comes first, whatever we choose.

**Recommendation: build the foundation, then add SSE for the live board, with
polling as the fallback.**

- **One-way is enough.** The server tells; the client does not answer. SSE is
  plain HTTP, the browser reconnects by itself (`EventSource`), and it passes
  the CSP (`connect-src 'self'`). WebSockets add a second protocol for no gain
  here.
- **The repository already streams SSE.** The MCP transport streams SSE
  (`MCPTransport.swift`), and nginx already has a location with
  `proxy_buffering off` and a long read timeout for it (`/mcp` in
  `deploy/nginx.conf`). A live-board location needs the same settings.
- **The event holds a version, not the board.** The client fetches the board
  with the usual request and gets the cached copy. So there is one rendering
  path, and the poll fallback is the same code without the stream.
- **Make the board the same for every viewer.** The page marks the student's
  own row in the browser, from an identifier in the page. Then one cached copy
  serves all 150 viewers.

Three points need design before we build push:

1. **Blue-green.** The streams on the old color stay open after the cutover. A
   change that the new color ingests does not reach them. A cap on stream
   lifetime (for example 60 s, after which the client reconnects with
   `Last-Event-ID`) keeps a stale stream short, and lets the old color drain.
   Postgres `LISTEN`/`NOTIFY` between colors is the complete answer if the cap
   is not enough.
2. **Shutdown.** A server that stops must close its streams, so that a drain
   does not wait for them.
3. **Connection count.** 150 to 200 open connections is small for SwiftNIO.
   The host nginx needs `worker_connections` well above this, and HTTP/2 at the
   edge removes the per-browser limit on open connections.

The status poll (R3) could also move to the stream later, as a per-student
"your result is ready" event. That is a second step, and the cheap poll is
enough until we measure otherwise.

## Measure first: the lecture load test

`chickadee-loadtest` (#2533) drives two streams today: runner polls and status
polls. Under A1 the runner polls are not part of a lecture. The lecture scenario
(W1) adds the four phases:

| Stream | Simulates | Default |
|---|---|---|
| Join | 150 kernel boots: the package files of one kernel, cold or warm (with `If-None-Match`) | Python, cold |
| Board | 150 viewers that poll the live board, plus one projector | every 5 s |
| Status | the status poll while results are pending | every 2 s |
| Submit | a burst of setup, seed and manifest downloads, then `browser-result` posts | 150 in 60 s |

The result post needs real submissions to post against, so the scenario needs a
seeded staging course with 150 test students. Run it against a staging copy on
Postgres, with production-sized hardware. Before each run, reset the statement
statistics. After it, read `hotPaths` and `get_query_stats`.

### Targets

The targets say what "seamless" means, so that a run passes or fails:

| Measure | Target |
|---|---|
| Warm join, page usable | p95 under 5 s |
| Result visible after the student submits | p95 under 10 s |
| A change reaches the projector | under 5 s with polling; under 1 s with push |
| Server errors (5xx) | none |
| Database CPU during the watch phase | under 50% |

## Work items

In order. Each item is a separate change with its own tests.

| | Item | Why |
|---|---|---|
| W1 | Lecture scenario in `chickadee-loadtest`, and a baseline run on staging | Numbers before changes |
| W2 | Activity version number, increased by the result ingest; shared board cache per version; poll answers from the cache | R2; the foundation for push |
| W3 | Same board for every viewer; the browser marks the student's own row | R2; makes W2's cache shared |
| W4 | Exempt the live-board poll from `request_metrics` inserts (count it in `hotPaths`); stop present mode when the activity ends | R2 |
| W5 | Join cost: on-demand packages for activity kernels; then static files from the host nginx, or hashed immutable kernel files | R1 |
| W6 | A per-assignment choice: no failover to the runners for a class activity | R5; makes A1 true |
| W7 | Server-sent events for the live board, with the lifetime cap and shutdown handling | Push |
| W8 | Lecture-day runbook: warm the caches, pause the deployer, reset statement statistics, what to watch, how to slow or freeze the board | R6 |
| W9 | Two rehearsals: a synthetic run (W1) and a live run with TAs or volunteers | Proof |

W1 to W4 are the minimum for a polling-only Winter term. W7 makes the board
feel live. W5 decides whether the join is smooth.

## Decisions (2026-10-13)

- **Python first.** The lecture activities start on the Python kernel. Other
  kernels come later.
- **Polling first.** A 5-second delay on the projector is acceptable for the
  first activities, so push (W7) can come after W2 to W4.
- **Failover is not the driver.** Most student browsers grade without fault.
  A few failovers to the runners are acceptable, so W6 is low priority.
- **No staging environment yet.** W1 runs locally until one exists.
- **The join is the first risk to fix (R1).** On a local machine (4 cores,
  debug build, loopback), the application served 150 cold Python joins at the
  same time in 23.5 s: 7,200 requests and 9.1 GB, about 3 Gbit/s, with no
  errors. So the application is not the bottleneck for the join. The network
  is: 8.7 GB through a lecture hall's shared Wi-Fi takes minutes. The fix is to
  have the bytes on the laptops before the lecture, and keep them valid:
  - Kernel packages are served as immutable (#2544), so a warm join asks the
    server for nothing.
  - No re-vendor in the week before a lecture activity.
  - Lecture activities early in the term need only the standard library. The
    two activities we checked (the Game of Life with SVG output, and
    rock-paper-scissors) import only the standard library and
    `IPython.display`, which is part of the bare 28-package kernel (9.7 MB).
    A stdlib-only "Python (lite)" environment for lecture activities would
    cut the cold join about six times. numpy and pandas come later in the
    term, in the full environment, downloaded once in a lab or at home before
    the first lecture that needs them.
- **Opponent activities will be needed, in a form without runners.** The
  first model to evaluate: play against the instructor's solution in the
  browser. A later model: play against past submissions of classmates, as an
  auto-battler game does. See "Opponents without runners" (to be written).

## Open questions

- Who builds the staging environment for W1, and when?
- Which opponent model comes first, and must the opponent's code stay hidden
  from students?
