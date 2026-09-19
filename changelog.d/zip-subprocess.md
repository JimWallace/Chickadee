### Changed

- **Every zip and unzip spawn runs on `swift-subprocess`.** This completes the
  move off Foundation's `Process`. `ZipProcessSerialization.swift` is deleted
  with it: its process-wide lock, its EFAULT retry and its `makeZipProcess()`
  factory all existed to make `Process` safe to spawn concurrently, and
  Subprocess does not share the global state that race lived in.

  The zip API is now async throughout. `listZipContents`, `listZipEntries`,
  `extractZipEntry`, `repackZipFromDirectory` and `validateZipUploadSize`
  suspend rather than block, and about 90 call sites across 40 files follow
  them.

  One property from the deleted file stays, because it was never a `Process`
  defect: zip spawns pass an explicit environment snapshot. A spawn that lets
  the library read the environment for it races `setenv` from the suites that
  write environment variables, and the observed failure was a SIGSEGV rather
  than a test failure. Subprocess defaults to `.inherit`, so the guard now
  pins the explicit `.custom(` instead of forbidding a bare `Process()`.

- **Two thread-pool offloads are removed.** `ZipEntryListCache` and
  `NotebookBytesCache` pushed zip work onto a NIO thread pool because listing a
  zip was a blocking spawn taken under the process-wide lock, so a caller parked
  a cooperative-pool thread for its own spawn and for every caller queued ahead
  of it. The call suspends now and the lock is gone, so the offload would only
  add a hop. Six `runBlocking` call sites whose bodies were zip work are
  unwrapped for the same reason. Every other `runBlocking` stays: file reads,
  directory sizes and the export path still block.

### Removed

- **The tests for the zip lock and the EFAULT retry.** `aHeldLockKeepsEveryOtherZipSpawnOut`,
  `aTransientEFAULTIsRetriedAndSucceeds` and
  `aPersistentEFAULTIsRetriedExactlyOnceThenPropagates` killed mutants in code
  this change deletes, so they have no subject any more.

  The three behavioural tests beside them are kept, with their assertions
  unchanged, in `ZipSubprocessTests.swift`: stdout capture, exit-status
  reporting, and twelve concurrent zip subprocesses each reading their own
  child's output. That last one was the regression net for the overlapped-drain
  regime the narrow lock scope created. It is now the regression net for the
  claim that replaced the lock, which is that concurrent zip spawns need no
  mutual exclusion at all.

  `ZipProcessEnvironmentTests` is rewritten rather than deleted, and gains a
  behavioural test it did not have before: a zip child really does receive the
  parent's `PATH`.
