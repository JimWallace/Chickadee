### Added

- **Assignment open dates (auto-open).** Instructors can set an optional open
  date on an assignment (new + edit pages, next to the due date). The
  assignment opens to students automatically once that time arrives — a
  periodic sweep mirrors the deadline auto-close, flipping the assignment open
  and consuming the date (a later manual close is never undone). Auto-open is
  held until runner validation passes. Manually opening an assignment early
  clears any pending open date. Existing assignments have no open date and are
  unaffected; the field round-trips through course bundle export/import.
- **MCP open-date support.** `update_assignment` accepts a `startsAt` argument
  (ISO 8601, or empty string to clear); `get_assignment` and `list_assignments`
  report it.
