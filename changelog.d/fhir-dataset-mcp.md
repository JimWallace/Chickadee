### Added

- **The MCP dataset tools handle FHIR NDJSON.** `create_dataset` takes a
  `format` of `csv` or `fhirNdjson`. It refuses a filename of the other format
  with a message that names `format`. `list_datasets` reports each dataset's
  format. `get_dataset` also reports a FHIR dataset's summary: patients,
  resource types, codes in use, descriptions and the example resource. For a FHIR dataset,
  `get_dataset` shows the first resource lines. `update_dataset` describes a
  FHIR dataset by `entries`, which are resource types and codes, and by
  `example`. `attach_dataset`, `get_assignment` and `get_support_files` report
  the attached file's format. The `initialize` instructions describe FHIR
  datasets (docs/fhir-datasets-plan.md §7).
