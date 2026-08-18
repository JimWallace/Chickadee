### Fixed

- **`browser-runner-tests` no longer dies on a slow Ubuntu mirror.** Its
  `apt-get` step hung for ~9m20s five times in one afternoon and was killed by
  the 10-minute job ceiling, reporting `cancelled` — indistinguishable from a
  wedged test suite, and with no test body having run. Each attempt is now
  bounded by `timeout` and retried up to three times, with apt's own transfer
  timeouts so it abandons an unresponsive mirror instead of waiting on it. A
  bare retry would not have helped: the failure is a hang, not a fast error, so
  the first attempt would still have consumed the whole budget.
