### Changed

- **Five authoring helpers leave `Routes/Web`.** `AssignmentHelpers`, `MultipartHelpers` and `SuiteEditHelpers` move to `Helpers/`, and `AssignmentRequirementHelpers` and `SuiteRowHelpers` to `Utilities/`. Three tests that read them by path name the new paths. These are pure moves with no change in behaviour (#2847).
