### Fixed

- **The Instructor nav link no longer disappears on the Admin (and other)
  pages.** Pages whose handlers build only a course-free user context — the
  admin panel, the account page, and many others — were dropping the nav's
  Instructor link and course tabs. A new `NavCourseContextMiddleware` resolves
  the course-aware nav context once per authenticated web request (cached, so it
  shares the existing active-course resolution), so the Instructor link and
  course tabs now render on every page.
