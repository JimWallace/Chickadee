### Changed

- **The product targets use two upcoming language features.**
  `ExistentialAny` requires `any P` for an existential type, and
  `MemberImportVisibility` requires each file to import the modules whose
  members it uses. Both are defaults of a future language mode. The fix-its
  touch about 320 files and change no behaviour. The test targets do not use
  the features yet, because their fix-its change existing tests.
  `scripts/check-runnercore-embedded.sh` compiles RunnerCore with the same
  features.
