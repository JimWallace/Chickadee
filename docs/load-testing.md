# Load testing the hot paths

`chickadee-loadtest` simulates deadline traffic on the two server routes with
the most traffic, and reports the latency that each stream sees. Use it to
measure a change to these routes before the change reaches production.

| Stream | Route | What the server does for each request |
|---|---|---|
| Runner poll | `POST /api/v1/worker/request` | HMAC check, nonce insert, runner check-in, pending-work query, and a claim when work is pending |
| Status poll | `GET /api/v1/submissions/:id` | Session lookup, submission read, access check |

A real runner slot polls with a backoff of up to 30 s. A result view polls
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

SQLite and Postgres behave differently under concurrent claims
(`atomicallyClaimSubmission`). Measure on the database that production uses.
