### Fixed

- **Each result and heartbeat retry gets a fresh signature.** The runner signed a request once and sent the same nonce on every retry, so the server's replay guard refused each retry after the first attempt reached it. The runner now signs each attempt again. (#2270)
