### Changed

- **One table names the role floor of each operation (#2772).** `CourseRoleFloor` replaces `DashboardRoleFloor` and adds content items, the course dataset library, Student Options, the class activity and the BrightSpace binding. The web routes, their MCP twins and the views read the same constant, so a floor change on one surface reaches the others. `CourseRoleFloorGuardTests` refuses a new literal floor in a file that implements a named operation. No floor changes value.
