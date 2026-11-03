### Removed

- **Dead code, test-only wrappers and legacy aliases (#2783).** The unused
  `JSONRPCError.missingRequiredClientCapability` factory is gone; its error
  code stays, because the transport maps it to HTTP 400. The test-only
  wrappers `crownFirstChampion`, `currentChampion`,
  `gradePercentFromCollectionJSON` and `VanityURLRoutes.slugify` are gone, and
  the tests call `Hill`, `CollectionGradeFields` and `assignmentSlug(fromTitle:)`
  directly. The aliases `RankedIdentities`, `ConditionInput`,
  `AchievementInput` and `WebAssignmentError` are gone; code uses
  `AvatarIdentity`, `ConditionRow`, `AchievementRow` and `AppError`. No
  behaviour changes.
