### Security

- **Browser-runner endpoints gated on assignment visibility, not just
  enrollment.** `GET /api/v1/browser-runner/testsetups/:id/{download,manifest,seed}`
  previously checked only course enrollment, so an enrolled student who supplied
  a `testSetupID` could pull a closed, not-yet-opened, or staff-only (preview)
  assignment's test scripts and — via the seed endpoint — its per-student
  resolved personalization values, which can encode solution-derived expected
  answers. All three now require the assignment to be effectively open for the
  caller (staff bypass), falling back to the enrollment check only when no
  assignment owns the setup. Regression tests cover the closed-student-blocked
  and preview-staff-visible cases.

### Fixed

- **`create_pattern_family` (MCP) advertises `unordered_equality`.** The tool's
  input-schema `kind` enum, its description, and the `initialize` server
  instructions omitted the `unordered_equality` kind, so an agent validating
  against the schema couldn't author one even though the handler accepted it.
