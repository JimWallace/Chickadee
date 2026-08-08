### Fixed

- **C++ assignments could not be graded at all in production.** The generated
  C++ wrapper compiles a binary into the job working directory and then
  `exec`s it, and the runner container mounts `/tmp` — where job workspaces
  were rooted — as `tmpfs ... noexec`. Every C++ test died with
  `exec: ./.ck_bin_...: Permission denied` despite a `-rwxr-xr-x` binary and a
  clean compile; the mount flag, not the file mode, was the cause. Job
  workspaces and scratch copies now honour `RUNNER_WORK_DIR`, so an operator
  can point them at a writable, exec-capable path.
- **A runner advertised C++ it could not run.** Capability discovery probed
  only `g++ --version`, which succeeds on a `noexec` host — so the runner
  claimed `cpp`, the language gate routed every C++ job to it, and each failed
  with a message that reads as a broken test script. Discovery now compiles and
  runs a trivial program in the runner's actual work directory for any language
  whose grading path executes its own build output, and a runner that cannot do
  both stops advertising the language. C++ is the only such language today.
- **A newly created C++ assignment stored an incoherent grading mode.**
  Declaring `cpp` set `submissionMode` to `uploadOnly` but left `gradingMode` at
  the new-assignment default of `browser` — the pair every other authoring
  surface explicitly refuses. Grading was never wrong (upload-only assignments
  are coerced to native grading at consumption), but the stored value was
  reported back verbatim, so a fresh C++ assignment looked browser-graded.
  Declaration now sets both.

### Added

- **`get_assignment` reports `submissionMode` and `language`.**
  `set_submission_mode` told callers to read the current mode from
  `get_assignment`, which never returned it, leaving an authoring agent no way
  to check the mode it had just been told to verify. `gradingMode` is now the
  effective mode, so an upload-only assignment no longer reports a grading path
  that cannot run.

### Changed

- **Octave's notebook-check count corrected in the docs.** `CLAUDE.md` and the
  Octave renderer's own header comment both claimed "seven of ten"; the code
  supports five (`variableExists`, `functionExists`, `numericArrayClose`,
  `cellContains`, `figureCount`). The surrounding prose in both places already
  described five — only the count was wrong.
