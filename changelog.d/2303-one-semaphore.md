### Changed

- **One async semaphore.** `WorkerClaimQueue` is now a one-permit `AsyncCountingSemaphore`, and the semaphore has a `withPermit` method that releases its slot on every exit path. The personalization evaluator uses it instead of three hand-written releases. (#2303)
