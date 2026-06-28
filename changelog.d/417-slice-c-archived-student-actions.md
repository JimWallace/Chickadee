### Security

- **Block writes to archived courses: per-student instructor actions, clone, and
  `set_assignment_course_section` (#417, follow-up to Slice A).** Slice A wired
  the assignment *editor* mutations through `requireCourseWriteAccess` but
  explicitly deferred the per-student dashboard actions (retest, retest-all,
  notebook reset, grade-override save/delete), their per-course-student-page
  twins (plus deadline extensions), the assignment **clone** endpoint, and the
  MCP `set_assignment_course_section` tool because they resolve their course
  differently. Those handlers now authorize against the *assignment's own*
  course, so a per-course instructor can no longer retest/override/reset/clone
  into an **archived** course — or drive any of those against a *different*
  course by URL — which the active-course group middleware can't see. Admins
  remain exempt; read paths (history, audits) stay readable on archived courses.
