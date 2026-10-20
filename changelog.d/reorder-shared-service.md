### Changed

- **One reorder service, one set of rules (#2713).** The four web reorder routes
  and the four MCP reorder tools now call `SortOrderRenumbering`. A TA can
  reorder every kind: course sections, section items, assignments and content
  items. Before, the web assignment reorder and the section reorder (web and
  MCP) needed an instructor. Every reorder refuses a duplicate id, an unknown
  item type and items of two course sections. The web section reorder must name
  every section of the course, as MCP `reorder_course_sections` already did.
  Each reorder runs in one transaction, so a failure part-way leaves the old
  order.
