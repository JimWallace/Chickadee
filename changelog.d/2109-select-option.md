### Changed

- **One `SelectOption` type for every form select (#2109).** Seven web view models each held the same three fields, `value`, `label` and `selected`. They are now one `SelectOption`. The builders that fill each select keep their names and return the shared type. `AdminMCPCourseRef` and `AdminUserCourseRow`, two copies of one course reference, are now one `AdminCourseRef`. The templates do not change.
