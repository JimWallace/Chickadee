### Fixed

- **A clone and a course bundle copy the runner requirements an assignment declared (#2167).** The `assignment_requirements` row (platform, architecture, languages, capabilities) was copied by no path and named by no doc. `cloneAssignment` copies it for every clone, `BundledAssignment` carries it as an optional `requirement`, and the two docs name it.
