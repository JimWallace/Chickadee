### Added

- **Students can reset their own notebook to the starter.** The student
  dashboard gains a per-assignment reset action (`POST
  /testsetups/:id/reset-notebook`) that restores the canonical starter
  notebook over their working copy. It is gated on course enrollment and the
  assignment being open to that student, and never touches past submissions.

### Changed

- **Instructor "reset notebook" icon no longer looks like a delete button.**
  The per-student reset control on the submissions page now uses a
  counterclockwise "restore" glyph instead of a trash can, so it reads as
  "restore the starter" rather than "delete submissions" (which it never did).
