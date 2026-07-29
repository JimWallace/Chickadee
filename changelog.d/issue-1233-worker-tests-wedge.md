### Fixed

- **`worker-tests` whole-process wedge root-caused and fixed (#1233).** The
  20-minute CI job kills recurred because the cooperative thread pool was
  fully pinned by blocking subprocess waits (`MimeTypeDetector`'s per-file
  `readDataToEndOfFile`, test helpers' `waitUntilExit`/`availableData`),
  made permanent by non-CLOEXEC pipe write ends leaking into long-lived
  concurrent subprocesses so EOF never arrived. All worker and test-support
  subprocess pipes are now CLOEXEC with deadline-bounded drains, the test
  helpers await child exit without pinning pool threads, and
  `TestSetupCache.acquire` — the daemon-side wait that ignored cancellation —
  now uses cancellation-responsive continuations and cancels an in-flight
  populate once its last waiter detaches.

### Added

- **WorkerTests wedge watchdog (#1233).** A dedicated-OS-thread watchdog
  aborts the test process with a full per-thread `/proc` state dump (state +
  `wchan`) after five minutes of in-flight-helper silence, so a future wedge
  fails in minutes with evidence instead of riding to the silent 20-minute
  job kill; `awaitCancelledDaemon` likewise records a loud issue plus a
  thread dump when an abandoned daemon ignores cancellation.
