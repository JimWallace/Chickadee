### Added

- **MCP `get_assignment` now reports `gradingMode`.** Its output includes
  whether an assignment is graded by the native runner (`"worker"`) or
  in-browser via Pyodide (`"browser"`), read from the test setup's manifest
  (`TestProperties.gradingMode`). Previously no MCP tool surfaced the grading
  mode, so an agent had to guess it.
