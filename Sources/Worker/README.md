# chickadee-runner

The runner daemon. It polls the server for jobs, prepares a workspace from the
cached test setup and the submission, runs each test script in a subprocess
(inside a sandbox with `--sandbox`), and reports a `TestOutcomeCollection`
back over HMAC-signed requests. It advertises a capability profile, so the
server hands it only the jobs it can grade.

Run `chickadee-runner --help` for the flags. The shared secret comes from
`--worker-secret`, the `RUNNER_SHARED_SECRET` variable, or the `.worker-secret`
file the server writes.

Read [CLAUDE.md](../../CLAUDE.md) for the test-script contract and the
sandbox boundary,
[docs/runner-capability-profiles.md](../../docs/runner-capability-profiles.md)
for job matching, and [docs/architecture.md](../../docs/architecture.md) for
the grading pipeline.
