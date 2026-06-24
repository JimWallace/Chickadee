### Added

- **Grade students who haven't logged into Chickadee yet (LEARN roster import +
  override-only sync).** A new **"Import students from LEARN"** action on the
  instructor LEARN tab provisions the bound course's classlist as real,
  enrolled, passwordless Chickadee student accounts — caching each member's D2L
  UserId + student number from the classlist so grade sync resolves with no
  lookup. Combined with a new override-only push wired into **"Sync now"**, an
  instructor can now set a grade override on a student with **no submission** and
  have it sync to LEARN (the result-based sweep only ever saw submitters). This
  makes it possible to grade non-submitters, and to exercise grade sync without a
  student ever logging in.

  Caveat (Phase 2 pending): provisioned accounts carry `authProvider
  "learn-roster"` and no SSO subject, so until SSO-adoption-on-login ships, a
  real student who later logs in via SSO would collide on the unique username —
  intended for test accounts that won't log in, not yet a live class.
