### Fixed

- **Student submission uploads no longer block a cooperative-pool thread on
  disk I/O.** The web upload form and all three notebook submit routes
  (browser-graded result, runner-submit, browser-failover) wrote their file with
  a synchronous `Data.write(to:)`. Vapor handlers run on the Swift cooperative
  pool, which has roughly one thread per core and never grows, so each write
  pinned a thread for its duration while the handler still held the whole body
  in memory — during a deadline burst, which is exactly when these routes are
  hot. They now use `req.fileio.writeFile`, matching the API submission path
  that was already fixed.
