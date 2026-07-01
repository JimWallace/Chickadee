### Changed

- **MCP close-on-edit contract is now a guarded chokepoint (#1115).**
  `update_solution` no longer hand-rolls the "close if open" rule (it now
  closes via the shared `closeOpenAssignmentForContentEdit`, remaining the one
  documented exemption from `finalizeContentEdit` — it enqueues its own
  validation carrying the new solution, and a solution-only edit never changes
  the manifest, so the manifest-gated regrade is deliberately skipped,
  matching the web save). New `MCPContentEditCoverageTests` classifies every
  `content:write` tool (content-edit vs non-closing, each with a
  justification) and fails the build for any new write tool that isn't
  classified. The agent-facing instructions now state explicitly that
  `update_global_inputs` / `update_section_variables` neither close nor
  regrade (matching the web Global Inputs panel), closing the ambiguity where
  those tools appeared in neither contract list.
