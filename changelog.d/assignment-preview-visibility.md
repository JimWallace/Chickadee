### Added

- **Preview (staff-only) assignment visibility.** Assignments now have a
  three-state visibility — `closed`, `preview`, or `open` — replacing the
  `is_open` boolean. `preview` is a staff-only beta state: students can't see
  it (it behaves exactly like `closed` for them), but course staff can
  test-submit to it to exercise the real grading path before publishing. The
  lifecycle is one-way (closed → preview → open); entering preview requires
  runner validation to have passed, and an already-open assignment can't be
  pulled back into preview. Staff test submissions are recorded as a new
  `preview` submission kind so they grade normally but never count toward
  student stats, grades, or badges. Settable from the instructor dashboard
  status control and over MCP (`update_assignment` `visibility`); course
  bundles round-trip the new field.
