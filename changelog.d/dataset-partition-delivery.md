### Changed

- **A partitioned dataset is linked to a stored part, not copied per student.** Each part of a partition with no transforms is now written once per assignment and source, under `dataset-parts/`, and each student's editor copy links to their own part. A class-composite student with no slot yet links to the header row. Existing copies become links on the student's next visit. Parts no longer current are swept after a day. MCP `get_support_files` reports `datasetDelivery: "perPart"` for such a file. See `docs/dataset-shared-delivery.md`.
