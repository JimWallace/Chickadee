### Changed

- **MCP course and section resolution lives in one file.** `resolveCourse` and `resolveCourseForWrite` move beside `resolveMCPCourse`, with comments that match what they do (the role floor is a parameter). The "check a section id belongs to this course" step, written twice, is now one `resolveCourseSectionID`, and `list_assignments` uses `resolveCourse` instead of inlining it. (#2341)
