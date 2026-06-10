### Security

- **MCP admin agents are now enrollment-scoped.** An agent token authorized by
  an admin can act only on the courses that admin is enrolled in — the same
  rule every other account already had — instead of every course on the
  deployment. Enrolling widens an agent's reach; unenrolling revokes it on the
  agent's next call. Archived courses are likewise hidden from the agent's
  `list_courses` / `resources/list` view, matching the dashboard. The
  dashboard tab strip and the MCP listing now share one visibility resolver
  (`enrolledCourses`), and the web guard and MCP authorization share one
  enrollment predicate (`userIsEnrolled`), so the user view and the agent
  view can no longer drift. Existing admin agents that relied on global
  reach must enroll the admin account in the relevant courses.
