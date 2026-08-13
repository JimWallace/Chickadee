### Changed

- **Instructor-side file writes come off the cooperative pool.** The nine
  synchronous notebook/zip writes left behind by the student-path fix — the
  setup upload's flat-notebook extraction, the notebook edit save, both
  assignment save paths, the draft solution writes, the validation
  submission write and its personalization sidecar, and the course-bundle
  import's per-setup zip copy + notebook write — now go through
  `req.fileio.writeFile`, or the thread pool where the code runs inside the
  import transaction and cannot hold a request (#1382 item 9).
