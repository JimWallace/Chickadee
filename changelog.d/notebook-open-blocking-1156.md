### Changed

- **Notebook-open path no longer blocks server threads (#1156).** Every
  notebook page/source request previously ran synchronous file reads/writes,
  the support-file symlink pass, dataset materialization, and (on first open
  of a personalized assignment) an unbounded `python3` subprocess directly on
  Vapor's small cooperative thread pool — a lab section opening an assignment
  stalled unrelated requests. The filesystem work now runs on the blocking
  thread pool; concurrent personalization interpreters are capped by a
  counting semaphore (≈ CPU count, excess evaluations queue without holding
  a thread); zip entry listings are single-flighted and computed off the
  cooperative pool (concurrent misses on one zip share one subprocess);
  student notebook/support-file downloads and the JupyterLite contents
  endpoint offload their reads and extractions the same way, and the
  support-file download reuses the entry-list cache instead of spawning a
  fresh `unzip` per request.
