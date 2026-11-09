### Fixed

- **The workbench pill no longer stays on "Validating…".** After Save & validate, the rail asked for the result once, while it was still pending, and never asked again, so the pill changed only on a reload. It now asks every 2 seconds for the first 30 seconds, then every 5 seconds, and stops after ten minutes. It waits briefly for the starter run too, and redraws the server's wording ("✗ Validation failed", "No runner") when the status moves.
