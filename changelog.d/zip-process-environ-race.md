### Fixed

- **`api-tests` SIGSEGV in `Process.run()` reading the global environ.** Every
  `/usr/bin/zip` and `/usr/bin/unzip` spawn left `Process.environment` nil, so
  Foundation inherited by reading environ itself — an unsynchronized read of a
  structure `setenv`/`unsetenv` reallocates, racing the three `APITests` suites
  that mutate env. This is the same race `ZipProcessSerialization` already
  mitigated in its *throwing* form (EFAULT, retried); in its user-space form it
  is a bad pointer dereference that no retry can catch, and it killed a CI run
  on 2026-08-09. All seven zip/unzip sites now build their process through
  `makeZipProcess()`, which supplies an environment snapshot taken once per
  process, so `run()` never performs the implicit read. Contents are unchanged;
  only the number of racy reads is, from one per spawn to one per process.
  `ZipProcessEnvironmentTests` fails on a bare `Process()` at any of those
  sites — verified to bite by reverting one — since a new site would otherwise
  opt back into the crash with every existing test still green. Recorded as
  Family 6 in `docs/ci-flakiness.md`, with the note that the crashing thread,
  not the first familiar name in the dump, is the one to read.
