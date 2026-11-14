### Changed

- **Mutation run on the authoring validators.** The steward ran the mutation tool on four APIServer files that the weekly sweep does not cover (`IdentifierValidation`, `PatternFamilyValidator`, `PatternFamilyAuthoredGraph`, `NotebookCheckValidator`). Two new test suites, `AuthoredGraphPhaseTests` and `PatternFamilyCrossFamilyValidationTests`, kill the seven survivors: cycle detection, the order of new families and checks, a family that depends on itself, family-variable references, filename collisions between families, and the heredoc delimiter in a reference implementation.
