### Fixed

- **"Highest grade wins" is now one shared fold, and the per-student
  drilldown uses it (#1111).** The policy existed as one helper plus three
  inline copies (student dashboard, grades CSV, BrightSpace sync), and the
  per-student drilldown pages still showed the *worker-preferred* grade — so
  a submission with a 100 % browser result later regraded 80 % by the worker
  showed 100 % on the roster but 80 % on the page the instructor opened from
  that roster row. Policy (pure `bestGradePercent` / `bestGradeResult` folds)
  is now split from I/O (the chunked grouped loader) in one file; all four
  surfaces and the three drilldown sites go through it. Badges still use the
  worker-preferred result.
