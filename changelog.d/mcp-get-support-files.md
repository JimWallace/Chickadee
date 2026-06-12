### Added

- **MCP `get_support_files` tool.** An authorized agent can now list an
  assignment's support files — the non-graded helper/data files bundled in the
  test-setup zip (e.g. the CSV a notebook check loads) — and read one as UTF-8
  text, byte-capped (default 64 KB) so large datasets return a useful head.
  Previously an agent could *write* a support file via
  `author_script(tier:"support")` but had no way to confirm what was bundled or
  author data-aware checks against its contents. Graded scripts and the
  starter/solution notebooks are excluded (their dedicated read tools cover
  them). `content:read`, course-scoped, instructor-authored content only.
