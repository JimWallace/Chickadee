### Changed

- **The draft and scaffold helpers live below the routes (#2142).** `AssignmentDraftHelpers.swift` and `NotebookScaffoldHelpers.swift` are in `Helpers/`, `NewAssignmentDraftPayload.swift` sits beside `NewAssignmentDraftService`, `resolveSectionID` and `newAssignmentSectionGradingMode` share the new `Helpers/CourseSectionLookup.swift`, and `NotebookFileKind` lives in `NotebookWorkingCopyStore`. The layering baseline loses ten lines. No behaviour change.
