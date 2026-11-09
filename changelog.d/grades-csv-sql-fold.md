### Fixed

- **A 199-of-200 score no longer reads 100% on the student dashboard or the instructor roster.** The two SQL grade folds rounded the best raw fraction, so a near-full mark rounded up to 100, while every other surface (by the rule of `GradePercent.of`) shows 99. `GradePercentSQL` now holds that rule once for every SQL fold.

### Changed

- **The grades CSV export folds grades in the database.** It loaded every student submission and every result of the course as Fluent models (44,000 rows, 2.6 s at one course's scale) to keep one best grade per student and assignment. `bestGradePercentByStudentAndSetup` returns those 3,600 numbers directly, in about 25 ms of database time. The values are unchanged, including results graded from their stored collection.
