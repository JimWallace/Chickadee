# The live board's refresh

A class activity's board refreshes every 5 s in each viewer's browser
(`Public/table-poll.js`), and the projector's wall does the same. In a lecture
of 150 that is about 30 refreshes a second. Before this change, each refresh
built the whole board from the database: the ranked entries, then every ranked
student's user and enrollment rows, decoded into models, then the HTML. The
`chickadee-loadtest lecture` baseline (`docs/load-testing.md`) measured p95
1.6 s for this refresh, ten times slower than any other stream. On an idle
server one refresh took about 70 ms, and decoding the 150 users and
enrollments was most of it.

This is work items W2 to W4 of the live-lecture plan (pull request #2540).

## What a refresh does now

For a board that takes the fast path (below), a refresh with
`?fragment=body`, and the wall's `?present=1&fragment=present`:

1. **Fingerprint.** One aggregate query over `leaderboard_entries` reads the
   count of ranked entries, the sum of their metrics and the newest
   `reached_at` (`LiveBoardFingerprint`). A result that changes a best
   changes the sum or the instant. A staff reader's fingerprint also counts
   the setup's submissions and the course's enrollments, because the staff
   rows show a submission count and the summary counts the unranked students.
2. **Roster snapshot.** The students' handles, birds, names and staff rings
   come from a `RosterSnapshot`. It is captured once per fingerprint and
   shared by every refresh in the process (`LiveBoardSnapshots`). Refreshes
   that arrive while it is being captured wait for that capture, so a change
   costs one roster load, not one per viewer. A snapshot is captured again
   after 30 s at most (`LiveBoardETag.bucketSeconds`), even on a quiet board.
3. **ETag.** `LiveBoardETag` hashes the fingerprint, the activity's
   manifest, the snapshot's digest, the viewer, whether they read as staff,
   the query (which carries the full list switch and present mode), the
   session window's state, the build and the 30-second time bucket. A refresh
   that sends this tag in `If-None-Match` gets 304 and nothing is built.
4. **Build.** Otherwise the board is built as before, with the snapshot in
   place of the per-request roster load, and answered with the same tag.

The full page load (no `fragment`) does not take the fast path.

**Which boards.** `WebRoutes.takesLiveBoardFastPath`: a metric board
(`bestMetric`, `beatTheInstructor`) that is not run per lab group. A hill
(`kingOfTheHill`) reads its holder from `activity_champions`, and the other
aggregations read other tables, which the fingerprint does not cover. They
are built on every refresh, as before.

**What can be late, and by how much.** A new best shows at the next refresh.
Anything else the board shows shows within 30 s, when the time bucket in the
tag turns over: a ranked student's new handle or bird, a student who drops
or changes role, a new title, an unranked viewer's own card. Each viewer then
builds once, from the shared snapshot. The fingerprint is a count, a sum and
the newest instant, so a recompute that lowered one best and raised another
by the same amount at the same instant is also seen within 30 s, not at once.

**Per process.** The snapshots are in memory. A blue-green cutover starts the
new colour empty; its first refresh of each board captures again. A browser's
ETag from the old colour still matches when nothing changed, because the tag
holds no per-process value.

## Request metrics

`GET /testsetups/:id/leaderboard` is a hot path (`HotPathRoute.leaderboardRefresh`):
a refresh answered 304 no longer inserts a `request_metrics` row, and
`HotPathRequestStats` counts every request on the path in memory. A board that
was built (200) still inserts its row, so the page load and a slow build of
any board kind, on the fast path or not, stay in `get_request_metrics`. `/admin/metrics` and
`get_metrics_snapshot` report it under `hotPaths`. See
`docs/operational-diagnostics.md` ("Hot-path counts").

## The wall stops

Present mode decides when it renders whether to refresh, and before this
change it had no stop time: a wall left on after the lecture refreshed until
its tab closed. It now carries `data-poll-until`: four hours after the wall was
opened, or the session window's close when that is later
(`PresentModePresentation.pollUntil`). Not the window's close alone: the page
reads the attribute once, so a window that staff extend during the lecture
would freeze the wall at the old close. After the close a refresh is a cheap
304, and the wall shows the session as closed. At the cap the last refresh
still reads Live, because the server cannot know the session is over: reload
the wall to start it again.

## Measured

`chickadee-loadtest lecture`, 150 students, cold join, the default timeline,
an empty board at the start, on the same machine and database as the
baseline in `docs/load-testing.md` (debug build, loopback):

| Board refresh | Baseline | With the fast path |
|---|---|---|
| Answered 200 | 1,968 | 2,565 |
| Answered 304 | 2,943 | 2,293 |
| p50 | 293 ms | 74 ms |
| p95 | 1,647 ms | 449 ms |
| p99 | 1,986 ms | 706 ms |

Most 200 answers follow the board's changes, which every viewer must see. The
rest are the time bucket turning over: every 30 s each viewer builds once,
from the shared snapshot, which is what bounds a change the fingerprint does
not see. A build from the snapshot costs about a third of a build from the
database (26 ms against 70 ms on an idle debug server), and a 304 costs one
aggregate query instead of a build.
