### Fixed

- **A dotfile script name no longer slips past the runner capability gate.**
  `AssignmentLanguage` treats a base name beginning with `.` as extensionless,
  but the runner's own classifier rejected only a name whose *only* dot was
  leading — so a suite entry like `.hidden.lua` required no Lua of the runner
  that claimed the job, and was then dispatched to `lua` anyway, dying at
  `exit 127` in front of a student. The two scanners now apply the same rule,
  held together by a differential test.
