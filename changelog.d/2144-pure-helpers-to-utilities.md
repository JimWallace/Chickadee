### Changed

- **Eight pure files moved from `Helpers/` to `Utilities/`, and the boundary is now checked from both sides (#2144).** `AchievementSignalPresentation`, `TierFilter`, `FailureDetailMasking`, `NotebookContributionSlots`, `SingleFlightCache`, `ManifestCoherence`, `SupportFileNames` and `SecretFile` import no framework and name no model. `scripts/check-utilities-imports.sh` now also fails on a `Helpers/` file that imports none of Vapor, Fluent and Leaf and names no model, with a fixture. No behaviour change.
