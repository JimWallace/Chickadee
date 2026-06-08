### Added

- **Author class goals from the assignment editor (achievements Phase 5).** A
  new "Class Goals" card on the instructor assignment edit page lets you add
  class-wide goals — a name, a per-student grade threshold, the share of the
  class that must reach it, and the bonus points everyone who submitted earns —
  persisted to the manifest via `PUT /instructor/:id/achievements`. Class goals
  are display-only, so saving doesn't retest submissions or re-validate. The
  student progress bar (Phase 3a) and the grade bonus (Phase 3b) read these.
