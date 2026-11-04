### Added

- **`check_assignment` MCP tool and the authoring-check framework (#2747).** A
  new `content:read` tool runs rule-based checks over an assignment's stored
  content and returns findings in one format (`AuthoringFinding`: check id,
  severity, location, message, suggested fix). The format already has a
  `reviewer` source and location kinds that no check uses yet, because the
  model reviewers planned in #2747 will report in it too. The first three checks report a manifest that breaks a coherence rule,
  a suite with no public test, and a zero-point test. The tool reads stored
  content only; it starts no run and changes nothing.
