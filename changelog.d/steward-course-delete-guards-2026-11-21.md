### Changed

- **One course-delete route test.** `DeleteCourseCoverageTests` and `DeleteCourseDatasetDealsTests` are folded into one test in `StudentWorkDeletionCoverageTests`, which deletes a course through the admin route and checks that another course's coverage and deal rows stay.
