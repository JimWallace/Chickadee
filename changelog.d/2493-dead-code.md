### Changed

- **Dead code removed.** Two grade-point wrappers that only forwarded to `CollectionGradeFields`, and three `NotebookExtractor` wrappers that only forwarded to RunnerCore, are gone; the callers use the owners directly. The activity-window gate reads the manifest once. Three functions that exist only for tests now say so (#2493).
