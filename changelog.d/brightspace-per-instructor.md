### Added

- **Per-instructor BrightSpace grade-sync identity.** Grade sync can now push as
  an individual instructor's connected LEARN account instead of a single
  deployment-wide service account — the model UW requires, since a service
  account can't be enrolled in courses but instructors already are. On the
  instructor **LEARN** tab, "Connect my LEARN account" verifies a pasted Valence
  User ID + User Key via `whoami` and stores it against that instructor; each
  course designates one connected instructor (`brightspace_sync_user_id`,
  default = whoever connects, reassignable via "Use my account for this course").
  The sweep, manual sync, grade-object listing, connection test, and classlist
  reconcile all resolve the course's designated identity (cached per identity in
  a new `BrightSpaceClientRegistry`), falling back to the deployment-wide
  (admin/env) identity when a course has none. A course whose designated
  instructor hasn't connected yet **defers** (rows stay pending) rather than
  clearing — so the grade pushes once they connect. The admin authorize / env
  path is retained as the fallback identity. New columns:
  `brightspace_credentials.user_id` (NULL = deployment-wide) and
  `courses.brightspace_sync_user_id`.
