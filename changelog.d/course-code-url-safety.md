### Fixed

- **A course code must be usable in a link.** Nothing encodes a course key
  when it writes a link, so a code with `/`, `\`, `?`, `#` or `%`, or a code
  that is `.` or `..`, got a 404 for every link: the link splits or ends at
  that character. Course create, edit, clone, new term, bundle import and
  un-archive now refuse such a new code. A space or a non-ASCII letter still
  works, because the router decodes each parameter. A course that already holds
  a refused code can still be edited, and the new `courseCodeNotURLSafe` health
  rule reports it until it is renamed. The one-click copy of such a course asks
  for the rename instead of reporting that no free code exists.

### Added

- **Tests for the course-code refusals at the instructor new-term clone and at
  bundle import**, which #2666 added without a test of their own.
