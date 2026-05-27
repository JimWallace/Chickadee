### Fixed

- **A failed nb_mypy load no longer bricks the in-browser editor.** nb_mypy was
  preloaded on the kernel-boot critical path (`loadPyodideOptions.packages`), so
  any failure loading it — a bad PEP 503 lock key, a future Pyodide bump dropping
  the wheel, an ABI mismatch — took down the entire editor kernel
  (`kernel-unhealthy` / `watchdog_timeout`), even though type-checking is only an
  optional nicety. nb_mypy is now loaded lazily in a background task after the
  kernel is healthy, wrapped so any failure degrades to "no type warnings" while
  the editor stays usable. Type-checking still works on the happy path.
