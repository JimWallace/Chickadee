### Fixed

- **TAs can reach the Instructor tab.** Clicking the Instructor nav button
  POSTs to `/courses/:id/activate` with `next=/instructor`; the
  dead-end guard there gated the redirect on `role >= .instructor`, so a
  TA — who the `/instructor` area gate (`ActiveCourseStaffMiddleware`) admits
  at `role >= .ta` — was silently bounced to the home page with no error
  instead of landing on the instructor view. The guard now matches the area
  gate's `.ta` threshold.
