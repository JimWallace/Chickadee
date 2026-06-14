### Fixed

- **Clearing a pattern family's prerequisites now actually drops them from the
  generated test rows.** Generated-case `dependsOn` was rebuilt as
  `[guard] + family.dependsOn + the prior manifest row's deps`, and that last
  term made a once-set family-level prerequisite permanently "sticky": once a
  family pointed at a script (e.g. a hand-written `*_exists` check), every
  regeneration re-read the old generated row and re-added the dependency, so
  clearing `family.dependsOn` never propagated. The practical symptom was an
  un-deletable script — the suite editor and the MCP `delete_suite_item` /
  `update_pattern_family` tools both rejected removing it with a dangling
  "depends on … which is not listed in testSuites" error, because a
  hand-written script is not a generated file and so never entered the deletion
  diff. Generated-case dependencies are now derived solely from the current
  spec (`[guard] + family.dependsOn`), so clearing the family's prerequisites
  removes them from every generated row and unblocks the delete.
