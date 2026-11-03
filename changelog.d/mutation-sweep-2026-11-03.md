### Fixed

- **The 2026-11-03 mutation sweep survivors are answered.** The three survivors were all in `TestProperties.hasCourseScopedDatasets`, which no Core test read directly. New tests pin that only a library attachment with the course scope counts: the course scope without a source, or a source with the assignment scope, does not.
