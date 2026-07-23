### Fixed

- **Personal-data export hung forever for data-heavy accounts.** The export's
  zip step ran `zip -r` (verbose) with its output wired to an in-memory pipe
  that was never drained, so once the "adding: …" output exceeded the ~64 KB
  OS pipe buffer — i.e. an account with enough submissions/results — `zip`
  blocked on write, never exited, and the export hung in `pending` forever
  (small accounts fit the buffer and completed, which is why it only bit large
  ones). `runZipProcess` now discards child output to the null device instead
  of an undrained pipe, and `createZipArchive` runs `zip -q`. This is the
  actual cause behind the stuck exports the v0.4.624 stale-export reaper only
  papered over.
