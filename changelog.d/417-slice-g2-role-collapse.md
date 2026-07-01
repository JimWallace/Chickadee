### Changed

- **Deployment role collapsed to `user` | `admin` (#417 Slice G2).** With teaching
  authority fully per-course (`CourseRole` on the enrollment), the global
  `student` / `instructor` roles no longer carry meaning. A new `CollapseUserRoles`
  migration rewrites every such row to `user` (it runs *after*
  `AddCourseEnrollmentRole`, which already seeded each enrollment's per-course
  role from the then-current global role, so no authority is lost). New accounts
  are provisioned `user` (or `admin` for the first-registered / SSO-allowlisted
  operator); `student` / `instructor` are dropped from `autoAssignableRoles` so an
  SSO claim can't re-mint them; and the admin **Users** page role control is now a
  `user` / `admin` toggle (with `mcp` service accounts shown read-only so they
  can't be flipped to a human role by mistake).
- **Roster-student queries key off the per-course role.** Every "students in this
  course" query (dashboard cards, submissions denominators, grade CSV, LEARN
  reconcile, roster counts) now counts `.student`-role *enrollments* instead of
  the retired global `role == "student"` — behaviour-preserving against existing
  data (the enrollment role was seeded from the global role) and correct going
  forward (a student who is a TA in another course is counted only where they're
  a student). Shared helper `studentUserIDsInCourse(_:on:)` in `CourseRosterCounts`.
- **MCP eligibility keys off course staff.** The MCP tool-eligibility and OAuth
  consent gates now admit course staff (`isStaffAnywhere`) rather than the retired
  global instructor role, so an instructor whose deployment role is now `user`
  keeps MCP access. (A transition-only `isInstructor` term remains alongside it
  until the test corpus is migrated off the legacy role strings.)

### Notes

- The `UserRole.student` / `.instructor` enum cases are retained as
  deprecated, decode-only vocabulary so historical rows and the large test corpus
  that still writes those strings keep resolving; a follow-up removes them once
  those are migrated. `CollapseUserRoles.revert` is a deliberate no-op (the
  student/instructor split isn't reconstructible from `user`, and nothing reads
  the global role for teaching authority any more).
