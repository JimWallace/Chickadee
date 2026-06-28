### Changed

- **Instructor nav is always reachable, and every course is one click away.**
  The nav bar's Instructor entry now shows whenever you instruct *any* enrolled
  course, not only when your currently active course happens to be one you teach.
  Instruct exactly one course and you get a single direct "Instructor" link;
  instruct several and a per-course Instructor strip appears, each chip jumping
  straight into that course's instructor dashboard. The existing course strip
  continues to give every enrolled student direct access to each of their
  courses. Course selection still flows through `POST /courses/:id/activate`,
  which now accepts an optional `next` destination (validated as a safe local
  path) and falls back to the home dashboard rather than dropping a non-instructor
  into a 403.
