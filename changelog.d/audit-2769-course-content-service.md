### Fixed

- **Course content items and sections share one service (#2769).** The web routes and the MCP tools now call `CourseContentService` and `CourseSectionService` for the field rules and the writes, with typed errors. The web content-item form now refuses an unknown kind, as MCP does. Before, the web stored it as a link with no error. The web checks the section grading mode against `GradingMode`, not against string literals.
