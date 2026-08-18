### Security

- **Course-section management is instructor-level again.** Creating, renaming,
  reordering and deleting a course's sections, and moving an assignment between
  them, enforced nothing beyond the `/instructor` area gate — so any TA of the
  course could restructure it, including in an archived course. The floor was
  already documented in three places (the convention on `evaluateCourseWrite`,
  the header of `CourseAdminRoutes+ContentItems.swift`, and the MCP twins in
  `CourseSectionTools.swift`, whose comments read "instructor-level (#417),
  matching the web"), and the MCP surface has always enforced it; the web half
  did not. All five handlers now call
  `requireCourseWriteAccess(atLeast: .instructor)`, which also brings them under
  the archived-course block they were missing.

### Changed

- **The web authorization matrix is derived over `CourseRole.allCases`.**
  `RouteAuthorizationMatrixTests` walked every parameterized `/instructor` and
  `/courses` route but crossed it with only two personas — a student of the
  owning course and an instructor of a different one — so `.ta` appeared nowhere
  in it and an instructor-only route that forgot its floor passed: a TA of the
  owning course is neither persona. The matrix now states each route's floor
  once, in a declared map the discovered route table keeps exhaustive (a walked
  route with no entry fails by name), and crosses it with every `CourseRole`,
  asserting denial below the floor and non-denial at or above it. That replaced
  six of the eight hand-written spot tests in `TARoleRouteTests` — the two that
  remain cover vanity-URL routes the walk cannot reach — and found the
  course-section defect above. `CourseRole` gained `CaseIterable` so a fourth
  rung would get its row with no edit to the test.
