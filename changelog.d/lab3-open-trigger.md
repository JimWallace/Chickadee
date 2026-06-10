### Fixed

- **Scheduled open date now publishes Preview assignments.** The scheduled-open
  sweep only auto-opened `.closed` assignments, so an assignment left in the
  staff-only Preview state silently sailed past its open date and never reached
  students (this is what kept a lab from opening at its scheduled 8am). Preview +
  open date is the intended workflow — staff test now, students get it when the
  date arrives — so the sweep now publishes Preview assignments too, with the
  same guards as before (validation must have passed, the due date must not
  already be behind us).
