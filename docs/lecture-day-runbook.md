# Lecture-day runbook

What to do before, during and after a lecture in which the whole class does a
class activity at the same time: about 150 students, one projector, the
activity graded in the students' browsers. The load it plans for is measured in
`docs/load-testing.md` ("A lecture activity"), and the board's refresh is
described in `docs/live-board-cache.md`.

The commands below are for the operator's shell. Each one is one line, with no
comment on it. The host commands need the production host; the read-only checks
use the admin diagnostics MCP (`Chickadee_Admin`), which any admin session can
call.

## The week before

**Choose an activity the lecture can carry.**

- Graded in the browser (grading mode `browser`). A worker-graded activity
  sends 150 jobs to the runners in a minute.
- A metric board (`bestMetric` or `beatTheInstructor`), not run per lab group.
  Only these take the board's fast path (`docs/live-board-cache.md`). A hill,
  a bracket, standings or a per-group board is built on every refresh of
  every viewer.
- Python, with imports from the standard library where you can. A cold join
  downloads the whole Python kernel environment (`docs/kernel-boot-cost.md`).
- A session window (`activity.window`): it opens and closes submissions on the
  clock, and the students' boards stop refreshing when it closes. The
  projector refreshes on, cheaply, for four hours after you open it (see
  "Open the projector"). Set the window on the edit page ("Class activity":
  Session opens, Session closes) or with MCP `set_activity`.
- Decide whether students see the board: the visibility control on the
  staff leaderboard page, or `leaderboardVisibility` in MCP `set_activity`. A
  hidden board costs almost nothing while students work: a student's refresh
  is refused before the board is built, and only the projector builds it.

**Validate it, and try it yourself.** Validation runs on a native runner, and
the students grade in the browser kernel. Open the notebook as a student would
and submit once, so the browser substrate is tested too (#2586).

**Do not re-vendor a kernel in the week before.** A new kernel build changes
the boot files, and every student's browser downloads them again on the day.

**Warm the students' caches.** The student dashboard downloads the kernel of
each open notebook assignment in the background (`Public/kernel-prewarm.js`,
`docs/jupyterlite.md`). Ask students to open the course's dashboard, or the
activity's notebook, once before the lecture: in a lab, or at home. A warm
join asks the server for almost nothing. A cold join of 150 students is about
9.7 GB, which a lecture hall's shared Wi-Fi carries slowly.

**Rehearse.** Run `chickadee-loadtest lecture` against a staging server with
the activity's copy (`docs/load-testing.md`): first `--join cold`, then
`--join warm`. It needs local accounts (`AUTH_MODE=local` or `dual`) and
`LOGIN_RATE_LIMIT_ENABLED=false` on that server, so never run it against
production. Then rehearse once with people: TAs or volunteers on their own
laptops, on the hall's Wi-Fi if you can.

## Thirty minutes before

**Check the deployment.** Call `get_deployment_info` and `get_deploy_status`.
Note the running version. A deploy that is pending or in progress should
finish now, not during the lecture.

**Pause the deployer.** A blue-green cutover during the lecture moves traffic
to a container whose in-memory state is empty: the hot-path counts and the
board snapshots. On the production host:

```sh
echo '{"command":"pause"}' | sudo tee /var/lib/chickadee-deploy/command.json
```

Merges to `main` still cut releases while it is paused; the daemon deploys
the newest one when it resumes. `get_deploy_status` shows `paused: true` once
the daemon has read the command.

**Check health.** Call `get_health_alerts`: nothing should be firing. Call
`list_runners`: keep the runners online. A browser that cannot grade sends its
work to the runners without telling the student
(`/submissions/browser-failover`), so the runners are the fallback.

**Note the baselines.** Call `get_query_stats` and note `statsResetAt` and the
top statements: the statistics accumulate, so the lecture is the difference
between now and afterwards. Call `get_metrics_snapshot` and note `hotPaths`.
Call `list_runners` and note each runner's `jobsProcessed`.

**Open the projector.** Open the activity's leaderboard from a staff account
and choose Present, which opens the wall in a new tab. It refreshes
for four hours, or until the window's close when that is later. After four
hours it stops but still reads Live: reload it if the lecture runs on.

## During the lecture

What to watch, every few minutes:

| Question | Tool | What is normal |
|---|---|---|
| Is the board refresh keeping up? | `get_metrics_snapshot`, `hotPaths`, route `GET /testsetups/:id/leaderboard` | about 30 a second, about half answered 304 and the rest builds; p95 well under the 5 s refresh interval |
| Which board builds are slow? | `get_request_metrics` with `pathPrefix` `/testsetups/` | a refresh answered 304 is not recorded; a board that was built is |
| Are results being stored? | `get_metrics_snapshot`, `hotPaths`, route `GET /api/v1/submissions/:id` | status polls follow the submits |
| Are browsers failing over to the runners? | `get_queue_state`, `pendingWorkerQueue` and `oldestPendingAgeSeconds` | both stay near 0; a growing worker queue means failovers. `pendingTotal` also counts browser-graded submissions the runners only back up, so it can be above 0 when nothing is wrong |
| Are kernels booting? | `get_browser_diagnostics`, `kernelBootFunnel` and `submitFunnel` | `kernel_idle` close to `boot_start` |
| Is anything else wrong? | `get_health_alerts` | nothing firing |

**If the board is slow.** There is no switch that slows the refresh. Hide the
board from students with the visibility control on the staff leaderboard page,
or with MCP `set_activity` (`leaderboardVisibility`). A student's refresh is then refused before the board
is built, and the projector, which reads as staff, keeps showing it.

**If a student cannot grade.** Their work still reaches a runner, and the
result appears on the board when the runner has graded it.

## After the lecture

**Resume the deployer.** On the production host:

```sh
echo '{"command":"resume"}' | sudo tee /var/lib/chickadee-deploy/command.json
```

The daemon then deploys the newest release, if a merge cut one during the
lecture.

**Record what happened.** Keep these with the date and the class size, so the
next lecture starts from numbers:

- `get_metrics_snapshot`: `hotPaths` for the board refresh and the status
  poll: the peak per minute and the p95.
- `get_query_stats`: the top statements, compared with the baseline.
- `get_browser_diagnostics`: the boot funnel, the submit funnel and
  `assetLoads` (how many joins were cold).
- `get_queue_state` (`pendingWorkerQueue`) and `list_runners` (jobs processed
  since the baseline): how many submissions failed over to the runners.

If a number was far from the rehearsal's, run `chickadee-loadtest lecture`
again on staging with the same class size before the next lecture.
