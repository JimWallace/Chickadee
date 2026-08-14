### Performance

- **Dashboard polls are conditional.** The three `?fragment=rows` endpoints
  (`/instructor/students-data`, `/admin/users-data`, `/admin/runners`) now carry
  an `ETag` over their rendered rows, and `table-poll.js` sends it back as
  `If-None-Match`. An unchanged table answers `304` and the client does nothing
  at all — no `innerHTML` write, no relative-time pass, no re-sort, no
  re-filter, no `chickadee:table-repaint` for the page's own decorations. On an
  idle dashboard that is every poll, twelve times a minute, for as long as the
  tab is open. (The server still queries and renders the rows in order to hash
  them; skipping that needs a per-table version stamp, which is a separate
  change.)

### Fixed

- **A background repaint no longer closes an open panel.** Polling was
  suppressed while focus was inside the table, but the students roster's
  pending-enrolment rows carry a `<details>` registration panel — and reading
  it, or clicking away to copy a value into it, moves focus off the table while
  the panel is still open and wanted. Any open `<details>` in a polled table now
  defers the repaint, alongside the existing focus and hidden-tab rules.

### Added

- **`table-poll.js` has unit tests.** The visual harness's repaint probe proved
  a repaint respects the sort and the filter; nothing covered *when* a repaint
  should happen, which is where the cost was. The suite pins the skip
  conditions, the conditional-fetch handshake, the 304 no-op, the re-apply
  order, and that a transient server error leaves the rows on screen and the
  stored ETag intact.
