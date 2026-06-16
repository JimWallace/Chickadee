### Added

- **Clone / duplicate an assignment from the instructor dashboard (#546).**
  Each published assignment row gains a "Duplicate" action that copies the
  assignment (notebooks, test-setup zip, manifest) into a new closed,
  unvalidated copy in the same course (`POST /instructor/:assignmentID/clone`),
  then drops the instructor on the copy's edit page to set a due date and
  re-validate before opening. The web action and the `clone_assignment` MCP
  tool both go through `AssignmentAuthoringService.cloneAssignment`, so the two
  clone paths can't drift.
