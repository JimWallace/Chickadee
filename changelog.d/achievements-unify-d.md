### Removed

- **Achievements unification (D): retired the legacy editor endpoints + JS.**
  With the single Achievements table live, the per-card endpoints
  (`/instructor/:id/badges` and `/instructor/:id/built-in-awards`) and their JS
  (`class-goals-editor.js`, `badges-editor.js`, `builtin-awards-editor.js`) are
  removed. Authoring is now exclusively the unified `GET`/`PUT /achievements`.
  The evaluation logic, the `/achievements` legacy `goals` back-compat, and the
  disabled-built-in honoring are unchanged. This completes the unification:
  one `Achievement` model, one endpoint, one editor table.
