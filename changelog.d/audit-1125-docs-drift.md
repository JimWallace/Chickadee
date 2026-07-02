### Fixed

- **Docs drift corrected (#1125).** CLAUDE.md now describes the post-#417
  two-level role model (deployment `user`/`admin` + per-course
  `student`/`ta`/`instructor`), the real counts (~276 Swift test files, 40 MCP
  tools, 8 pattern kinds), and gains a themed digest for v0.4.351–v0.4.583
  (the #417 series, the LEARN sync arc, datasets, zero-downtime deploys).
  `docs/multi-course-roles.md` is updated to shipped reality (TA rung, global
  roles physically removed) and finally defines the "Slice A–G2" vocabulary
  ~20 code comments cite. `docs/mcp-authoring-roadmap.md` gains the missing
  `set_time_limit` row plus a sync test that fails the build when a registered
  tool has no row. `docs/audit-2026-06.md` carries a "status as of v0.4.582 —
  read as history" note.
