### Changed

- **Course and section loaders (#2773).** `loadCourse`, `loadCourseForWrite` and `loadCourseSectionForWrite` now sit beside the assignment loaders. Eleven course handlers and two section handlers call them in place of a hand-written guard. Status codes and error messages do not change.
