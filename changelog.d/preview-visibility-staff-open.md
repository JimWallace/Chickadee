### Changed

- **Preview assignment visibility simplified to "Open, but staff-only."** A
  Preview assignment now behaves exactly like an Open one for course
  staff/admins (bundled solution and tests, normal grading, editable notebook,
  normal submissions) while appearing **Closed** to students. Switching an
  already-validated assignment to Preview is a pure visibility change — it no
  longer re-validates, asks for a reference-solution upload, or closes the
  assignment, and it can be set to/from any state. Staff see a subtle
  "staff-only" marker on the dashboard; students see no Preview badge. Removed
  the separate `preview` submission kind (staff submissions behave like any
  other), so no behaviour of Open assignments changed.
