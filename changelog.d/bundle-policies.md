### Fixed

- **A course bundle carries the four per-assignment policies and the course authoring guide.** Secret reveal, passing threshold, solution reveal and LMS sync exclusion, and the course's own MCP guide, were dropped on export, so an imported course lost settings the clone keeps. Each is optional in the manifest, so an older bundle still imports with the column defaults. The bundle is a faithful restore: unlike the clone, it carries the solution reveal, the dates and the open state as they were (#1737).
