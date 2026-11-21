### Added

- **Tests for the authoring snapshot loader and the assignment version store failure paths.** New suites pin what `check_assignment` loads (notebook cells, a missing setup zip, the variant batch behind the student-data wall, one expression evaluation per variant seed) and how version recording and blob reclamation fail safe.
