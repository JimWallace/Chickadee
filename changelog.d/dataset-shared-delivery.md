### Changed

- **A dataset given whole to every student is linked, not copied.** A dataset file with no sample size, no partition and no transforms now reaches each student's editor as a link to the assignment's one shared copy, as an ordinary support file does, instead of a copy per student. Existing copies become links on the student's next visit. The Files panel and MCP `get_support_files` (`datasetDelivery`) show whether each dataset is shared or per student. See `docs/dataset-shared-delivery.md`.
