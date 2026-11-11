### Added

- **A dataset format, and FHIR NDJSON in Core.** A dataset spec now records its
  format, CSV or FHIR NDJSON. A stored manifest keeps its bytes, because the
  format is written only when it is not CSV. A FHIR NDJSON file is delivered
  whole and byte for byte to every student. Saving a FHIR spec refuses a
  sample, a partition, a stratum and transforms, and checks that each line is
  a JSON object with a resource type and an id. Core also summarizes a FHIR
  file (resource counts and the codes in use) and pretty-prints one resource
  without reordering it. Nothing can attach a FHIR dataset yet; the course
  library gains the format next (docs/fhir-datasets-plan.md).
