### Changed

- **The student guide reads anchors through the shared anchor service.** `NotebookGuideBuilder` now calls `SuiteAnchorResolution`, as the workbench outline and MCP `get_suite` do. Before a solution exists, the guide takes anchors from the assignment's template starter rather than the student's personalized copy, so every student, the workbench and MCP see a test on the same cell. The guide still shows each student's own starter code beside a task.
