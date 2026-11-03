### Fixed

- **A course code that matches a server path is refused (#2666).** The router
  tries a fixed path segment before a parameter and never backtracks, so a
  course coded `data`, `lab`, `login` or any other first segment of a fixed
  route lost every vanity link to a 404 or the wrong page. Course create, edit,
  clone, new term, bundle import and un-archive now refuse such a code. The
  reserved set is read from the registered routes, so a new route reserves its
  own segment. A new health rule, `courseKeyShadowed`, reports any active
  course that already holds one, or that a new route comes to shadow.

### Changed

- **The vanity routes are one table.** The five copied redirect handlers in
  `VanityURLRoutes` are one loop over the suffixes, and the enrollment check
  uses the shared `userIsEnrolled`.
