### Fixed

- The server compiles again on `main`. #1873 added a call to the old `AssignmentLanguage.resolve(for:manifest:)` in the solution extractor after #1878 had validated the deletion of that parameter, so the two merges crossed and `main` failed to build.
