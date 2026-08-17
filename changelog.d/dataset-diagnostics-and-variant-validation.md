### Added

- **Per-student dataset estimates in the Files panel.** Each marked dataset row
  gains a collapsed "Per-student estimates" disclosure answering the two
  questions the parameters could not: how many rows two students share
  (closed-form overlap, with the unluckiest pair in a class and — for a
  stratified sample — the most copyable category by name), and how far a
  student's slice drifts from the pool (per-column Wasserstein-1 in pool-SD
  units for numeric columns, total variation for categorical, measured through
  the real materializer over derived preflight seeds). The numbers recompute on
  every saved parameter edit and never alter a delivered byte.
- **Multi-variant validation.** On an assignment that varies by student (a
  per-student `=` expression or a per-student dataset), every validation
  enqueue now also grades the reference solution against four derived
  per-student seeds — the same preflight seeds the estimates sample — so a
  solution that only works for some students' material fails validation
  instead of failing a student. Per-variant verdicts appear under the
  validation cell on the instructor assignments list (with a link to the
  failing variant's per-test results) and in the MCP `get_validation_result`
  tool, which reports each variant's seed and its failing outcomes.
