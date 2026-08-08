### Fixed

- **The test harness no longer leaks its scratch directories.** `makeTestApp`
  built its per-app temp path with a trailing slash inside
  `appendingPathComponent`, and `URL.path` strips that — so the five directories
  it then created by string concatenation were *siblings* of the intended
  parent rather than children (`…/<uuid>content-files/`). Nothing created the
  parent, so `tearDownTestApp`'s `removeItem` deleted a path that never existed,
  and its `try?` swallowed the error: cleanup reported success while removing
  nothing. A full suite run leaked ~1.4 GB across ~6,900 `/tmp` entries, enough
  to fill a 252 GB disk over a working session. Measured after the fix, the same
  run leaves 45 MB. Two regression tests assert the outcome — that the
  configured directories are inside the recorded root, and that nothing matching
  the app's prefix survives teardown — rather than asserting that cleanup ran,
  which is what was true the whole time it was broken. (#1298)
