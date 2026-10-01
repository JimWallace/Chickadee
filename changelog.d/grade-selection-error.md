### Changed

- **Grade selection has its own error type.** `bestGradeForStudent` now throws `GradeSelectionError` instead of a Valence-named error. The Valence sweep maps it to its own `missingPoints`, so the sync log reads as before, and the AGS sweep classifies it without importing the Valence error taxonomy (#1651).
