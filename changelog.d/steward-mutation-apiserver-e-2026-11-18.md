### Changed

- **Tests for the support-file list, from a mutation run on six more APIServer helpers.** A steward mutation run on `ClientNetwork`, `SecretFile`, `SupportFileNames`, `WorkerClaimToken`, `FreshShortID` and `CourseRoleFloor` in `Sources/APIServer/Utilities` found one survivor: `currentSupportFileNames` had no test, so its filter could keep a suite script as a support file and no test failed. A new database-free suite, `SupportFileNamesTests`, kills it. No product code changes.
