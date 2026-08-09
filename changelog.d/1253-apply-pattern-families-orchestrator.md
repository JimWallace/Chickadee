### Changed

- **`applyPatternFamilies` carries no lint exemptions at all.** Its remaining
  four phases — resolving caller arguments against the stored manifest,
  rebuilding the authored ordering, resolving the assignment language, and
  rewriting the manifest — moved into
  `PatternFamilyApplication+Inputs.swift` and `+Manifest.swift`. The function
  is now a 90-line orchestrator over six named phases, down from 575 lines
  when the work started, and the `function_body_length` exemption is gone.
  No behavioural change: the manifests and file lists produced for a fixture
  covering families, existence guards, notebook checks with sidecars,
  sections, global variables, `family:` dependency expansion, disabled cases,
  the deletion diff and the carry-forward path are unchanged.
