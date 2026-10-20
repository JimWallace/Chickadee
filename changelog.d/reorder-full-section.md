### Changed

- **A section-item reorder names the whole section (#2713).** The web and MCP
  section-item reorders now refuse a list that leaves out an item of the
  section. Assignments and content items share one order in each section, so a
  partial list gave two items the same position. `reorder_assignments` and
  `reorder_content_items` now refuse a section that holds both kinds; use
  `reorder_section_items` there. The dashboard drag already sends the whole
  section, so the page does not change.
