### Added

- **Reference solution is now importable in personalization expressions
  (`shared/solution.py` kept in sync).** Saving an assignment's reference
  solution now (re)writes a server-side `shared/{setupID}/solution.py` from the
  solution notebook's code cells, so a Global Input expression can compute an
  expected value as `solution.<fn>(...)` — a single source of truth — instead of
  a hand-maintained answer key that can silently drift from the solution. The
  file lives **only** in the shared directory: it is never written into the
  test-setup zip, so it never reaches the worker, the browser runner, or a
  student support-file download (the same treatment `solution.ipynb` already
  gets). The shared-directory rebuild that runs on every suite edit now
  preserves this file across its wipe when the zip does not itself carry the
  solution, so `import solution` keeps working after an edit. Previously this
  worked only for setups whose uploaded zip happened to contain `solution.ipynb`
  (draft-/MCP-created assignments never do), leaving the feature dormant for
  them.
