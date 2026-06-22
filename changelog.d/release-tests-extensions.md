### Fixed

- **Release-tier results now respect per-student extensions.** Release-test
  output is gated on the student's *effective* deadline — the later of the
  assignment due date and their own extension — instead of the bare
  assignment-wide due date. A student with an active extension no longer has
  the hidden release tests revealed while their extended submission window is
  still open; the reveal is only postponed to their own deadline, not
  suppressed. Both the JSON results API
  (`GET /api/v1/submissions/:id/results`) and the web submission page route
  their tier-visibility decision through `effectiveDueAt(for:user:)`.
