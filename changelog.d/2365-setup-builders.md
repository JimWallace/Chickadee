### Tests

- **One test-setup builder.** `wrInsertSetup`, `arInsertSetup` and six private copies now call the shared `makeTestSetup`, which can skip the zip file. `WorkerRoutesTests` no longer hides the shared builder behind its own `makeTestSetup`. (#2365)
