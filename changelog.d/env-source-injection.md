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
