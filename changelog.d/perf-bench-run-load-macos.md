### Fixed

- **The performance bench kit runs on macOS.** `Tools/perf-bench/run-load.sh`
  read the server's CPU time from `/proc`, which macOS does not have, so the
  weekly check stopped after the page measurements. It now falls back to `ps`
  where `/proc` is missing.
