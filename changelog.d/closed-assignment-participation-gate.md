### Changed

- **Closed assignments are gated on a durable participation record.** A
  student only reaches a closed assignment's notebook or upload form if they
  previously engaged with it; everyone else is sent to their dashboard, so
  assignment links can be posted in advance without spoiling not-yet-opened
  labs. "Engaged" is now recorded in a new `assignment_participations` table
  (one row per student per assignment, written the first time they open it
  while it's open), which survives redeploys — rather than being inferred from
  the on-disk notebook working copy. Existing student submissions still count,
  so anyone who has submitted keeps access. Previously-opened closed
  assignments also stay on the dashboard with their Edit link.
