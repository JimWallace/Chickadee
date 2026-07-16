### Changed

- **The instructor LEARN-tab bulk actions ("Sync now", "Push all") now return
  immediately instead of holding the request open for every D2L push.** They
  still re-queue the affected grades and write the audit row in-request (fast
  local writes), but the actual sync now runs in a detached background task
  rather than being awaited — so clicking them on a large class no longer hangs
  the page for the dozens of sequential D2L round-trips (which risked a
  reverse-proxy timeout). The grades push moments later; the page flashes a
  "pushing in the background" confirmation, and the 60-second periodic monitor
  remains the backstop. ("Reconcile now" is unchanged — it's a single classlist
  fetch plus local writes, so it stays synchronous to show the
  confirmed/unreachable counts immediately.)
