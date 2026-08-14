### Changed

- **The process-wide zip lock now covers only the spawn.** Synchronous zip
  subprocess runs (suite-zip list/extract/repack, upload-size validation,
  notebook detection) held the shared serialization lock across the child's
  whole runtime — a server-wide cap of one zip operation at a time, with each
  waiter parking a thread. The lock now covers Process construction + spawn
  only (the window Foundation's EFAULT race actually spans, and the scope the
  async path always used); drains and waits overlap. All sync sites route
  through one shared helper, which also brings the previously-unserialized
  `zipContainsNotebook` spawn into the lock + retry regime.
