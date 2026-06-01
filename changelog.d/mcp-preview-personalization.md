### Added

- **MCP personalization tools — preview.** New read-only `preview_personalization`
  tool resolves what a student would see for an assignment: the `name → value`
  map (global + section literals, plus per-student expressions evaluated against
  a seed — supply `seedHex` for a specific student or use your own) and a
  starter-notebook `{{placeholder}}` audit (which resolve, which don't). It drives
  the same `PersonalizationSubstitution` resolver the student first-open path now
  uses, so the preview matches reality. Completes the four-part series exposing
  per-student personalization authoring over MCP.
