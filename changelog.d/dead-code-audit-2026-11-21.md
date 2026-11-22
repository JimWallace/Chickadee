### Removed

- **Five functions that only tests called.** The 2026-11-21 audit of code that only tests use removed `WorkerActivityStore.knownRunnerVersions`, `loadClassGoalViews`, `MetricsCardWindow.label(forBucketStart:)`, `ReflectionCells.hasTaggedCells` and the `DatasetResolver.resolve` overload with a course seed and no deal number. The tests now call the production functions. No behaviour changes.
