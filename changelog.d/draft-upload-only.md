### Fixed

- **An assignment made on the create page keeps the upload-only mode its language set.** Declaring C++, Racket or Java on the create page sets `uploadOnly` and `worker`, but the draft's suite rebuilds and the publish rebuilt the manifest from scratch and stored `notebook` and the section's grading mode, the pair every authoring door refuses. Grading was not affected, but `get_assignment` reported the stored values. The three rebuilds now start from the draft's own manifest, so every field the create page recorded survives without being named (#1720).
