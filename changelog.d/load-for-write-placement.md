### Changed

- **The assignment loaders live in `AssignmentHelpers.swift`.** `loadAssignmentForWrite` and `loadAssignmentAndSetupForWrite` sat under the suite-editing helper file, while their 39 callers in 21 files are grading actions, lifecycle actions and BrightSpace. The read loaders and the private resolvers they share moved with them. A pure move (#1717).
