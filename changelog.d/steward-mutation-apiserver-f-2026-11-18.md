### Changed

- **Boundary tests for the alert-summary wording.** A steward mutation run on four helpers in `Sources/APIServer/Utilities` (`AlertText`, `LanguageProse`, `GeneratedMessageVocabulary`, `AchievementSignalPresentation`) gave four mutants, and the existing tests killed all four. A boundary check by hand found that no test held a list of exactly five names, so "and 0 more" could appear in an alert summary without a failure. The new suite `AlertTextBoundaryTests` holds the list at the limit and the durations on each hour and day boundary. No product code changes.
