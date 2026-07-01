### Changed

- **Per-course staff view/access gates (#417 Slice G, part 1).** The view- and
  access-shaping checks that used to key on the deployment-global
  `APIUser.isInstructor` now resolve staff status **per course** — a viewer sees
  instructor-level detail only for the courses they actually staff (per-course
  role ≥ `.ta`, or admin), not deployment-wide. Two new resolvers in
  `CourseAccessHelpers` back this: `isCourseStaff(_:inCourse:db:)` for gates that
  know their resource's course, and `isStaffAnywhere(_:db:)` for the few
  deployment-wide surfaces (MCP eligibility + OAuth content-scope consent, the
  JupyterLite virtual filesystem, the user-file namespace, the new-setup form)
  where no single course is in scope. Converted gates include: tier visibility
  (`visibleTiers` / `itemizedTiers` / `releaseOutputVisible` now take an
  `isStaff` bool computed against the submission's course), the submission
  view/download/results/query paths, the reference-solution and notebook-source
  endpoints, the closed-assignment gate, the assignment-open deadline gate, the
  student dashboard, and the vanity-URL enrollment gate. This closes a
  cross-course read gap — a global instructor could previously see any course's
  submissions, secret tests, and solutions by URL — and prepares the ground for
  collapsing the global role (part 2). No enum or migration changes yet; the
  global `UserRole` still has its `student` / `instructor` cases.
