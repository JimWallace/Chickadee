### Fixed

- **The local runner autostart cannot start two runners at once.** `LocalRunnerManager.ensureRunning` checked for a runner, then awaited the worker secret, then stored the new runner. Two saves at the same moment could both pass the check and start two processes, and one of them could then never be stopped. It now reads the secret before the check. `stopIfRunning` clears its handle before it awaits the stop. The validation pre-check's wait now ends when the request is cancelled. (#2299)
