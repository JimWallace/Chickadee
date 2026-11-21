### Removed

- **Test-suite cleanup.** Removed seven per-tool MCP enrollment-denial tests that `MCPEnrollmentDenialContractTests` already covers, two scope-gate tests that `AdminMCPDispatcherTests` covers, and the Swift runner-bucket reference code (`RunnerBucketAccumulator`, `accumulateRunnerSnapshots`, `summarizeRunnerBuckets`) that only tests called. Zip and python tests now skip through host-condition traits instead of a silent `return`, and three suites gained time limits.
