### Changed

- **Mutation triage (#2535): the runner's startup decisions have tests.** The process-inspection label, the `--worker-secret` flag use and the container memory budget check moved into functions a test can call, and `WorkerCommandStartupTests` pins them together with the job-limit validation, the startup log fields, the job-cgroups warning and the SIGTERM drain.
