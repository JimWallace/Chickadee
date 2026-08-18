### Fixed

- **`browser-runner-tests` no longer installs its own interpreters.** It was the
  last job apt-installing `lua5.4` and `octave` on a bare runner — the exact
  thing the CI image was built to stop — which left ~500 interpreter-independent
  tests depending on an Ubuntu mirror. On 2026-08-18 that mirror took the job out
  five times in seven runs, each time hanging ~9m20s in `apt-get update` and
  dying at the job ceiling as `cancelled`, indistinguishable from a wedged suite
  and with no test body having run. The job now runs in the CI image, which
  already ships `lua5.4`, `octave`, `python3` and `node`, so the failure mode is
  gone rather than retried. The two suites that genuinely execute an interpreter
  keep their guard asserting it is present under CI.
