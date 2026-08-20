### Fixed

- **The graded submission result page now has pixel and accessibility
  coverage.** Its baseline captured only the pending spinner, because the
  fixture attaches no runner and a worker-graded submission therefore never
  finishes — so the score band, the count tiles, partial-credit points labels,
  the collapsed output panel and the masked hidden-test rows had no coverage on
  any page, in either scheme. The seed now posts a fixed
  `TestOutcomeCollection` through the same endpoint the in-browser grader uses,
  producing a second, graded submission beside the pending one. Adding the
  coverage immediately caught a layout defect it would otherwise have hidden:
  the count tiles collapsed to a single column beside the grade, because a
  shared auto-fit grid receives only its content width inside a flex row.
