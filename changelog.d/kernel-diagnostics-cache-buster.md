### Fixed

- **Editor kernel-diagnostics collector is now cache-busted, so collector changes
  actually reach returning students.** `jl-kernel-diagnostics.js` was injected
  into the editor documents as a bare `<script src="/jl-kernel-diagnostics.js">`
  with no version query, so a browser that had cached an older copy kept running
  it after a deploy — the editor page cache-busts itself, but this separately
  referenced script did not. The result: collector changes (e.g. the v0.4.544
  CASE 2 `bootContext` fields) silently failed to reach returning students until
  the browser cache TTL expired. The injected tag now carries a `?v=<hash>`
  derived from the collector's own bytes (`scripts/patch-jupyterlite-diagnostics.py`),
  so a deploy that changes the script forces a fresh fetch while an unchanged
  script keeps a stable, cacheable URL. `verify-jupyterlite.sh` now asserts the
  tag's hash matches the current script, so a stale tag fails the build instead
  of silently serving an old collector.
