### Fixed

- **A flaky 60 s statement timeout in the APITests lane.** A recycled test schema could carry planner statistics that read zero rows on non-empty pages. Autovacuum wrote them after the DELETE sweep. The LEARN tab summary query in `CourseWideResultQueryBindLimitTests` then ran as a nested loop of 4.3 billion comparisons. Pooled test schemas now have autovacuum off, and the return sweep TRUNCATEs any table past 1 MiB (Family 10 in `docs/ci-flakiness.md`).
