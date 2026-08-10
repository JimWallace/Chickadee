### Fixed

- **A browser-graded submission can no longer be lost because a badge failed.**
  This is the `grading-probe` intermittent, closed after three sightings.

  The window was exact: the breadcrumb trail reached `suite_done` — graded,
  passed — then the POST 500'd, and the page went on polling
  `GET /api/v1/submissions/:id` and getting 200 for its full budget. That is the
  tell. The submission row existed and the result did not, so something between
  the two threw, and in the probe's configuration exactly one thing there could:
  `awardFirstToSubmitRecords`, an unguarded read-then-write that ran *before*
  the result was saved.

  Why it threw at all is the part that made this hard to place. sqlite-nio
  installs a busy handler that retries forever, so ordinary lock contention
  never surfaces — which is why "set a `busy_timeout`" is the wrong fix and why
  reading the configuration for a missing one finds nothing. What a busy handler
  cannot cover is `SQLITE_BUSY_SNAPSHOT`: a WAL read snapshot made stale by
  another connection's commit, which SQLite returns immediately because waiting
  cannot help. Every badge helper is read-then-write, the shape that hits it,
  and the page's own polling supplies the concurrent commits.

  The Pathfinder award now runs after the result is stored, alongside the class
  records, in an extracted `awardBrowserResultBadges`. Both go through a
  best-effort wrapper: `withTransientDatabaseLockRetry` first, then log and
  continue. A class badge is worth an ordinary amount; a student's grade is not
  worth losing for one.

  `BrowserResultSideEffectOrderTests` pins the ordering and the wrapper, and
  reproduces the original failure when the order is reinstated.
