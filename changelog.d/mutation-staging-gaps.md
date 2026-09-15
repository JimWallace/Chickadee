### Fixed

- **Closed four mutation survivors on the test-setup cache key and the
  protected-filename set.** CLAUDE.md states the cache contract in one line —
  any suite edit busts the entry — and nothing asserted it. The survivor that
  drops the manifest from the hashed material makes an edited suite key to the
  same cache entry as the suite it replaced, so every later submission grades
  against a cached copy of the old tests, silently.
