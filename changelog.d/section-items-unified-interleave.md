### Changed

- **Course sections interleave materials and assignments into one list.**
  Within a course section, ungraded content items (reference material) and
  graded assignments now share a single drag-orderable `sort_order` sequence
  instead of living in two stacked lanes — a reading can sit between two labs.
  The student and instructor dashboards render one table per section; a new
  `POST /instructor/section-items/reorder` persists the mixed order across both
  tables, and a newly published or moved assignment appends to its section lane
  (per-section, not course-global). The Grades CSV column order is now
  section-aware. Assignment drag-and-drop moved to `Public/section-items-dnd.js`
  and now drags both row types.

### Added

- **MCP `reorder_section_items`.** Orders a section's items (assignments and
  content items mixed) in one call — the primary ordering tool. `reorder_assignments`
  is reworked to renumber a section's assignments (was a course-global full
  permutation); `reorder_content_items` remains for content-only sections.
