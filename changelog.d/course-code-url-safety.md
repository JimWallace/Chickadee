### Fixed

- **A course code must be usable in a link.** A code with `/`, `\`, `?`, `#`
  or `%`, or a code that is `.` or `..`, got a 404 for its links: the link
  splits or ends at that character. The vanity links and the staff
  student-history links now percent-encode the key (`urlEncode`), so the links
  Chickadee writes work for any code, and a key with a space gives a valid
  `Location` header. Course create, edit, clone, new term, bundle import and
  un-archive now refuse such a new code. A space or a non-ASCII letter still
  works, because the router decodes each parameter. A course that already holds
  a refused code can still be edited, and the new `courseCodeNotURLSafe` health
  rule reports it until it is renamed. The one-click copy of such a course asks
  for the rename instead of reporting that no free code exists.

### Added

- **Tests for the course-code refusals at the instructor new-term clone and at
  bundle import**, which #2666 added without a test of their own.
