### Fixed

- **Personalization / suite edits on a brand-new assignment no longer fail with
  an opaque error.** When a test setup had no files yet — e.g. attaching global
  inputs (a personalized fortune) to a fresh notebook assignment before
  authoring any test — the save threw an internal error. `repackZipFromDirectory`
  shelled out to `zip -r .`, which aborts with "Nothing to do!" (exit 12) on an
  empty directory, and that raw error escaped `update_global_inputs`'s
  error mapping. It now emits a valid empty archive instead, so an empty test
  suite is a legitimate state. (Workaround until now: author one test before
  adding personalization.)
