### Changed

- **The browser runner's executors are their own file.** `RoutingExecutor`, `GradingWorkerExecutor`, `UnavailableExecutor` and the script helpers moved from `Public/browser-runner.js` to `Public/grading-executors.js`. The runner keeps the page wiring, the submission path, the notebook extraction and the generated language tables, and builds the router over the two tables it needs with one call. `browser-runner.js` drops from 1,377 lines to 895 (#1965).
