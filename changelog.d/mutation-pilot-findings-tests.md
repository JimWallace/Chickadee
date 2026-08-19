### Added

- **Tests for the six real gaps the mutation pilot found**, each seen to fail
  under the mutation it exists to catch: the suite runner's `willRun` /
  `didFinish` event stream (which drives the runner's `test_execution_start` /
  `test_execution_end` / `timeout` log events), the classifier's comment-and-blank
  line filter and its five Python keywords taken one at a time, the leading
  BOM/whitespace trim, and the JSON footer's exponent — where the existing tests
  proved the number *parsed* without ever reading its value.

### Fixed

- **The mutation pilot's write-up, which overstated its own findings.** Of the
  eleven survivors examined, four were already covered by the suite and one is
  unkillable by construction; only six were real. `Tools/mutation/report.py`
  exists to catch that class automatically and did not exist when the pilot ran.
