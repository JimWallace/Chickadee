### Changed

- **The web and MCP version capture share one scope.** The web middleware and the MCP dispatcher each had a copy of the capture scope and of the loop that records a version. Both now use `AssignmentVersionCaptureScope` and its `begin` and `recordRegistered` steps, and keep only their own seam, origin label and database. Behaviour is unchanged (#2259).
