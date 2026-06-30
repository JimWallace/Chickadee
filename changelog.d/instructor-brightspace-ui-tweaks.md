### Changed

- **Instructor LEARN tab: "Sync now" is now a hard reset and lives up top.**
  The button moved next to "Export Grades CSV" and now also re-queues every
  previously-errored grade push (the old separate "Retry failed" button, which
  is gone) before sweeping — so terminal failures the auto-reaper leaves alone
  get retried with one click.
- **LEARN grade-item mapping gained a "Do not sync" option.** An instructor can
  now explicitly exclude an assignment's grades from LEARN, distinct from simply
  leaving it unmapped; the sweep skips excluded assignments and the row shows a
  "Do not sync" pill with an "Enable sync" action to undo it.
- **Per-assignment Synced/Failed counts now count distinct students by their
  most recent attempt** instead of summing every historical result row, so the
  numbers reflect how many students are currently delivered to LEARN and how
  many need a fix.
- **LEARN Class Roster polish.** The Match and Delete actions are now icon
  buttons matching the rest of the UI, and the Issue column reads a simple
  "Couldn't match to LEARN".
