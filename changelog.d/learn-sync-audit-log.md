### Added

- **Actor-driven LEARN sync actions now appear in the admin audit log.** A new
  "LEARN sync" audit category records who did what on the grade-sync surface:
  deployment key authorized/cleared (admin), instructor LEARN account
  connected/disconnected, course sync identity designated, org unit
  bound/cleared, grade-item mapping changes (including "Do not sync"),
  auto-map runs, manual "Sync now", and per-assignment "Push all". Individual
  grade pushes remain in `brightspace_sync_log` — the audit log covers only
  the human actions around them.
