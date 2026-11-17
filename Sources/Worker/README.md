# chickadee-runner

The runner daemon. It polls the server for jobs, prepares a workspace from the
cached test setup and the submission, runs each test script in a subprocess
(inside a sandbox with `--sandbox`), and reports a `TestOutcomeCollection`
back over HMAC-signed requests. It advertises a capability profile, so the
server hands it only the jobs it can grade.

Run `chickadee-runner --help` for the flags. The shared secret comes from the
`RUNNER_SHARED_SECRET` variable, or from the `.worker-secret` file the server
writes. There is no command-line flag for it: `--worker-secret` was removed
at 0.6.0, because it put the secret in the runner's command line, where every
test script can read it. A runner started with it exits at once with
ArgumentParser's "unknown option" error.

Read [CLAUDE.md](../../CLAUDE.md) for the test-script contract and the
sandbox boundary,
[docs/runner-capability-profiles.md](../../docs/runner-capability-profiles.md)
for job matching, and [docs/architecture.md](../../docs/architecture.md) for
the grading pipeline.
