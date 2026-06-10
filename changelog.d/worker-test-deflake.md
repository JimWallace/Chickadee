### Fixed

- **WorkerTests de-flaked.** A three-week CI audit showed ~85% of genuine
  worker-test failures were one mechanism: trivial `/bin/sh` scripts in
  `WorkerTests.swift` hitting their 5 s script time limit on CPU-starved
  runners. Those limits (which only bound a hang) are now 60 s, and the
  kill-path latency assertions are correspondingly relaxed. The second
  pattern — `Process.run()` transiently failing under fork pressure with a
  misleading "file doesn't exist" error — is fixed by a shared
  `runProcessRobustly` helper that launches bare `Process` spawns under the
  subprocess throttle and retries failed launches; the `LocalHTTPTestServer`
  factories, the daemon tests' zip builder, and the Rscript probe now all
  honor the throttle they were documented to use. Also: the three
  worker-secret tests no longer `chdir` the whole process
  (`resolveWorkerSharedSecret` / `defaultWorkerSecretFilePaths` take an
  injectable `currentDirectory`), the mock URLSession timeout no longer
  gates passing runs, and the `worker-tests` CI job caps Swift Testing
  parallelism at 4 like the APITests jobs.
