### Changed

- **The last two wide parameter lists are gone (#1253).** `createAssignmentWithUniquePublicID` takes a `NewAssignmentFields` value, and `persistNewAssignmentSetup` takes the planned paths as one value. No `function_parameter_count` lint exemption remains. Behaviour does not change.
- **Migration consolidation, round 3 (#1252).** The two slip-day migrations, `AddCourseSlipDaySettings` and `AddEnrollmentSlipDaysAdjustment`, are folded into `CreateCourses` and `CreateCourseEnrollments`. Deployed databases already have the columns and do not run the changed migrations again. A fresh database gets the same schema.

### Fixed

- **Racket per-student inputs are now tested against a real `racket` (#1393).** A new `RacketNativeGradingTests` case writes `_ck_inputs.rkt` with `renderInputsFile` and reads the values back through `chickadee-inputs`. Lua, Octave and C++ already had this test.
