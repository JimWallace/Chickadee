### Added

- **A FHIR feed and helper for HLTH 230.** `docs/examples/fhir/` holds four
  files:
  - a generator for a simulated emergency department feed, 300 patients as
    FHIR R4 NDJSON, which writes the same bytes from the same seed;
  - `chickadee_fhir.py`, a support-file helper with FHIR-style search, paging
    and a simulated clock, which works offline when graded;
  - the helper's checks;
  - a proposed Assignment 3 question, a screen for the SIRS vital-sign
    criteria, with its reference solution.
