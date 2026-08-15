### Fixed

- **Zip subprocesses no longer read the global environ at spawn time**, closing
  a race that killed CI runs with a SIGSEGV rather than a test failure.

  `Process.run()` with a nil `environment` does not inherit for free: it reads
  the global environ itself. Neither zip spawn set one, so both were
  unsynchronized *readers* of a structure `setenv`/`unsetenv` reallocates —
  and several test suites mutate environment variables while Swift Testing runs
  everything else concurrently.

  This is the race `ZipProcessSerialization.swift` already existed for, in the
  half its retry cannot reach. When the kernel notices the bad address, `run()`
  throws EFAULT and the retry absorbs it; when the read instead walks a
  reallocated environ in user space, the process dies mid-run. `withAsyncEnvLock`
  could not help either: its contract asks every reader to take the lock, and a
  zip spawn is an **undeclared** reader — the read happens inside Foundation,
  not in any helper anyone thought to wrap.

  Both spawns now come from `makeZipProcess()`, which supplies an environment
  snapshot taken once per process. The contents are exactly what these spawns
  inherited before — the children are `zip` and `unzip`, which consult no
  environment — so only the number of racy reads changes, from one per spawn to
  one per process.

  Scope is deliberately the zip paths. Three other Foundation `Process` sites
  construct bare (`MimeTypeDetector`, `RunnerProfileDetector` ×2) and have the
  same exposure in principle. Broadening looks free and is not: a snapshot taken
  at process start does not reflect a later `setenv`, so any spawn whose child is
  meant to observe a mutated variable would break silently. The zip children
  consult none, which is what makes them safe to convert.

  `ZipProcessEnvironmentTests` guards it, including a control that pins "a bare
  `Process` really does start with a nil environment" — without which the guard
  could be protecting a property Foundation had started supplying anyway, with
  no way to tell.
