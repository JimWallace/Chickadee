### Added

- **The course dataset library records a format.** A library dataset is now
  CSV or FHIR NDJSON, set when it is created and kept for every version. A FHIR
  version is checked as FHIR at upload and stores a summary: its patient count,
  its resource types and the codes in use. Attaching a FHIR dataset delivers
  the whole file and refuses a sample. Moving a `.ndjson` support file into
  the library makes a FHIR dataset. A course clone and a course bundle carry
  the format; a bundle with a FHIR dataset is version 3, which an older server
  refuses. The staff download names a FHIR version `.ndjson`. The pages and
  the MCP tools offer the choice in a later release
  (docs/fhir-datasets-plan.md).
