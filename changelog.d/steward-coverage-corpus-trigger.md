### Changed

- **Tests: a worker report on a contribution assignment schedules the class corpus run.** `ClassCorpusTests` now posts a student's result through the real worker result route and checks that the class corpus run starts, and that an ordinary assignment starts none. The worker result-report helpers moved from `WorkerRoutesTests` to the shared `WorkerClaimTestFixture.swift`.
