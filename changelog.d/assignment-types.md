### Added

- **Assignment types.** Every assignment now declares one of three types:
  Assignment, Lab or Class activity (docs/assignment-types.md). A one-time
  migration records the type of each existing assignment from its manifest.
  Browser grading means a Lab; otherwise an activity block means a Class
  activity; otherwise it is an Assignment. Instructors change the type with
  the Type select on the assignment edit page, and agents through
  `update_assignment`; `get_assignment` reports it. Bundles and clones carry
  it.
- **A row icon and colour for each type.** On the instructor dashboard, the
  student course page, the admin course page and the LEARN and AI agents
  tabs, an Assignment keeps the teal
  clipboard, a Lab shows an indigo flask and a Class activity a magenta group,
  in light and dark themes. The type changes no grading behaviour yet.
