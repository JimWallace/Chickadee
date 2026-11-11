### Fixed

- **Moving an assignment moves its attached material.** A move to another course section (the dashboard drag and MCP `set_assignment_course_section`) now sets the section of every content item attached to the assignment in the same transaction, so the item's stored section matches its assignment's. Students saw no effect: their dashboard draws an attached item in its assignment's row and never reads the item's section. Staff could see the old section in `list_content_items`, and an edit that named the assignment's current section was refused as a move.
