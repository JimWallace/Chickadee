### Fixed

- **Reset-notebook now personalizes the restored starter.** All three
  reset-notebook actions (student self-service, and the two instructor-driven
  resets on the per-assignment roster and the course-student page) overwrote
  the working copy with the raw starter template, skipping the `{{name}}`
  personalization substitution that first-open seeding applies. On a
  personalized assignment a reset left the student staring at
  `patients = {{patients}}` and a `NameError`, with no self-service way back.
  The three paths now funnel through one helper that substitutes global/section
  variables and per-student expressions before writing, exactly like first
  open.
