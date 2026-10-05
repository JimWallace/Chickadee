### Changed

- **`RunnerValidationHelpers.swift` is now `Services/RunnerValidationService.swift` (#2140).** The validation-submission lifecycle is code over models and a database that shared code calls, so it lives below the routes, and `loadAssignmentRequirementSpec`, which only the validation pre-check uses, moves with it. Signatures are unchanged, and the layering baseline loses one line.
