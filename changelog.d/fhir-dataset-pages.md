### Added

- **The dataset pages handle FHIR NDJSON.** The Datasets tab's upload form asks
  for the format. A FHIR dataset's page lists its resource types and codes, each
  with a description field. It also shows the example resource that the Data
  page displays, and the instructor can pick a different one. The student Data
  page shows the patient count, the resource types and the codes grouped by
  system (LOINC, SNOMED CT, ICD-10), with the example pretty-printed. The
  student's copy downloads as `mine.ndjson`. In the assignment editor's Files
  panel, a FHIR dataset has no sample fields, and a `.ndjson` support file can
  be moved into the course library (docs/fhir-datasets-plan.md).
