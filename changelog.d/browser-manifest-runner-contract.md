### Security

- **The browser runner's manifest endpoint serves only the runner contract.** `GET /api/v1/browser-runner/testsetups/:id/manifest` sent an enrolled student the whole stored manifest except grader-only file names, including `=` expression source (which can call the reference solution), pattern-family reference implementations and expected values, notebook-check expected data and dataset specs. It now serves `RunnerManifest`, the same fields the native runner receives, which are the only fields `browser-runner.js` reads.
