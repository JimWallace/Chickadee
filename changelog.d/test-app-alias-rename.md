### Removed

- **The old test-app helper names are gone.** `withAssignmentRoutesApp` and `withWebRoutesApp` were pass-through names for `withTestApp`; their 865 call sites in 149 test files now call `withTestApp`.
