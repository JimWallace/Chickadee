### Changed

- **One request pushes a changed grade to both LMS integrations.** A new result, a grade override and a frozen class-goal bonus each called the BrightSpace and the LTI grade sync separately. They now call `requestGradePush`, and `GradePushCoverageTests` fails when a file outside it asks only one integration. Behaviour is unchanged (#2259).
