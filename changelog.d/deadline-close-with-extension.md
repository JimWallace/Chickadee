### Fixed

- **Assignments now auto-close at their deadline even when a student has an
  active extension.** The deadline sweep was refusing to close the
  assignment-wide window whenever any per-student extension (e.g. an
  AccessAbility accommodation) was still active, so an assignment with any
  extension appeared never to close — it kept reading as "open" on the
  instructor dashboard and in every student's list past its deadline. The
  assignment-wide visibility now always closes at the deadline; per-student
  access is preserved downstream as designed — the submission gate
  (`isAssignmentOpenForUser`) keeps submitting open for a student whose
  extension is still in the future, and the student dashboard re-includes
  setups where the viewer holds an active extension.
