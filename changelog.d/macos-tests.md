### Fixed

- **Scripts launch on a macOS runner.** The capture pipes' write ends were
  close-on-exec, and on Darwin a `createSession` launch goes through
  Subprocess's fork-then-`posix_spawn(SETEXEC)` path, which cannot dup2 such a
  descriptor: every script failed with EBADF. On Darwin the write ends now stay
  inheritable; `POSIX_SPAWN_CLOEXEC_DEFAULT` already keeps them out of other
  children. Linux is unchanged.
- **The sandbox no longer opens the whole work root to a variable that names
  it.** An environment value equal to the work root (macOS's `TMPDIR` when the
  runner works in the temporary directory) passed the "under the root" check
  and made every job visible. Only directories strictly below the root count.
- **Assignment version snapshots capture files on macOS.** The walk trimmed
  `workDir`'s path off each entry, which matched nothing when the enumerator
  reported `/private/var/…` for a `workDir` under `/var`.

### Changed

- **The test suite passes on macOS.** Linux-only tests (private `/tmp` and
  discarded writes in the sandbox, `/proc` censuses) are compiled on Linux only;
  fixtures account for bsdtar, APFS case-insensitivity, `/usr/bin/true`, and
  the macOS Java stub.
