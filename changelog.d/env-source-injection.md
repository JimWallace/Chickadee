### Changed

- **Tests no longer write the process environment.** `setenv`/`unsetenv` rewrite
  glibc's `environ` array in place, and a concurrent `getenv` walking it
  segfaults rather than reading a stale value — killing the whole test process
  at a different test each run, which is why it always read as a flake.
  Configuration now reads through `EnvironmentSource`, whose `@TaskLocal`
  override `withTestEnvironment` binds, so a suite that covers env parsing
  supplies an environment instead of mutating the process's. Zero `setenv` calls
  remain in APITests. Production behaviour is unchanged: with no override bound,
  every read falls through to `Environment.get` as before.
- **The seventeen hand-rolled `/usr/bin/zip` test fixtures became one.** Each
  built its own `Process` and spawned it unlocked, reintroducing exactly what
  `Core/ZipProcessSerialization.swift` was written to stop. They now share
  `writeZipFixture`, which holds `withZipProcessLock` across construction and
  spawn.

### Fixed

- **The browser runner boots the assignment's declared substrate, not Python's.**
  `RoutingExecutor.ensureReady` treated `PRIMARY_KIND = 'python'` as the runtime
  the grade depended on, swallowing every other substrate's boot failure
  whenever Python was present. On an R assignment carrying one stray `.py`, that
  made R's boot the swallowed one — so every R test posted a real zero while the
  incidental file got the protection. It now boots the language the assignment
  declares, and only that one; a script of another kind still runs (its worker
  boots on first use) and reports its own error. Where no language reaches the
  browser, every present substrate is required rather than assuming Python.

### Changed

- **A language is declared, never inferred.** `AssignmentLanguage.resolve` now
  returns what the manifest declares and nothing else. The graded-script
  extension sniff and the notebook-kernel sniff moved into
  `derivedDeclaration`, which runs at the three boundaries where content arrives
  without an author answer — the REST zip upload (which did not declare before,
  and now does), course-bundle import, and the one-time backfill — and each
  records the result immediately. Derivation happens once, at the edge, and
  becomes a declaration.

### Removed

- **`AssignmentLanguage.rederive` and `manifestWithRederivedLanguage`.**
  Replacing a starter notebook re-derived the assignment's language, on the
  reasoning that a recorded language was "a memo of what was last resolved". A
  declaration does not go stale when content changes: an author converting a
  Python assignment to R changes the language in the dropdown that exists for
  that purpose, and a notebook upload no longer overrules them silently.
