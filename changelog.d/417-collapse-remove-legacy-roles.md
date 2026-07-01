### Removed

- **Retired the deprecated global `student` / `instructor` user roles (#417).**
  The deployment role enum is now `user` / `admin` / `mcp` only; teaching
  authority lives entirely on the per-course enrollment (`CourseRole`). The
  transitional `APIUser.isInstructor` shim and the `RoleMiddleware(.instructor)`
  tier are gone — the `CourseAccessHelpers` per-course chokepoints
  (`requireCourseRole`, `isCourseStaff`, `isStaffAnywhere`) are the sole
  authority. MCP consent/eligibility (`ToolContext.requireEligibleSubject`,
  the OAuth content surface's `permits`) now key off `isStaffAnywhere`, and
  auto-enrollment (`saveSeededEnrollment`) seeds a per-course instructor only
  for admins; every other account auto-enrolls as a student and the roster
  grants staff explicitly. Production DBs that still carry the legacy role
  strings decode them as ordinary non-admin users, and the `CollapseUserRoles`
  migration rewrites them to `user`.
