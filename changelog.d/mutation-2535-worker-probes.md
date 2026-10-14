### Changed

- **Mutation triage (#2535): the sandbox probes, the job cgroup files and the runner's last log line have tests.** The probe verdict and the probe directory are shared helpers of `SandboxedScriptRunner`, and new tests pin them, the `JobCgroup` control-file write and removal, the stream count of `ScriptCapture`, the `runner_shutdown` status and the capability-probe timeout log.
