### Fixed

- **A course with GitHub repositories stays bound to their organization.** Binding a course to a different organization overwrote the binding, so existing course repositories read as not found, new students could not generate from the old template, and archiving failed. The binding is now refused while the course has course repositories or templates in another organization.
