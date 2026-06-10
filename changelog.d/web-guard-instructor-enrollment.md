### Security

- **Instructor web access is now enrollment-scoped.** The shared course
  guard (`requireCourseEnrollment`) no longer waves instructors through:
  like students, they must be enrolled in the course that owns the content.
  Previously any instructor account could fetch another course's notebook
  and test setup — including secret tests and the reference solution — by
  URL, even though the dashboard never showed it. Admins keep the bypass
  (they administer the deployment and can grant themselves enrollment);
  their MCP agents remain enrollment-scoped, so agent scope stays a subset
  of human scope for every role.
