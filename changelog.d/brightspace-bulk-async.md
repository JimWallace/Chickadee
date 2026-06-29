### Changed

- **The instructor LEARN-tab bulk actions ("Sync now", "Retry failed", "Push
  all") now return immediately instead of holding the request open for every
  D2L push.** They still flag the affected grades pending (a fast local write),
  but the actual sync now runs in a background task rather than being awaited
  in-request — so clicking them on a large class no longer hangs the page for
  the dozens of sequential D2L round-trips (which risked a reverse-proxy
  timeout). The grades push moments later in the background; the page flashes a
  "syncing in the background" confirmation. ("Reconcile now" is unchanged — it's
  a single classlist fetch plus local writes, so it stays synchronous to show
  the confirmed/unreachable counts immediately.)
