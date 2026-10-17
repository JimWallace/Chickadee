### Added

- **Course dataset library, slices 1 and 2.** A dataset spec can now record the library version it came from and whether its rows are the same in every assignment, and stored manifests encode to the same bytes as before. The server gains the `course_datasets` and `course_dataset_versions` tables and a service that creates, versions, describes, publishes and deletes library datasets, with a data dictionary inferred from each upload. The blob collector counts library versions as references. Nothing in the interface uses the library yet. The plan is `docs/datasets-course-library.md`.
