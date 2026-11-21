### Changed

- **Slowest suites in the CI summary.** Each Swift test lane now writes its 20 slowest suites, from the xUnit report, to the job summary. The step never fails the job.
