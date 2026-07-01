### Changed

- **One course write-access policy, explicit role floors (#1113).** The web
  `requireCourseWriteAccess` and MCP `authorizeCourseWriteAccess` were
  hand-maintained twins of the same policy (admin bypass → role floor →
  archived block). The policy now lives once in the throwless
  `evaluateCourseWrite(…) -> CourseWriteDenial?`; the two wrappers only map
  the denial to their surface's error type. `authorizeCourseAccess` returns
  the resolved acting user so MCP write authorization no longer re-resolves
  the token subject per call. All `atLeast:` role-floor defaults are removed
  — every call site states its floor explicitly (content/grading = `.ta`,
  lifecycle/structure = `.instructor`); the convention is recorded in
  `docs/multi-course-roles.md`. No behavioural change to any route or tool.
