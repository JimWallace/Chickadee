### Changed

- **Six worker and evaluator comments say what the code does now.** The zip note that described a lock the subprocess layer no longer has is gone, as is the Pyodide name in the native executor's header. The evaluator header names all seven drivers, the executor's environment field says it merges over the allowlist, the test-setup cache describes its real key and root, and the capability-profiles doc says the gate asks `languagesRequiredToGrade` (#1798).
