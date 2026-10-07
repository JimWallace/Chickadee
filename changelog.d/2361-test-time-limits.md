### Fixed

- **Nine test suites that spawn python3 or bind a loopback server now have a time limit.** A stall now fails with a named test, not by holding the CI job to its 20-minute kill. The raw loopback exchange in `ExtensionCSRFTokenTests` sets a receive timeout, because a time limit cannot interrupt a blocking `recv`. The five tests that run a generated case under python3 now carry `.requiresPython3`, so a host without python3 skips them instead of failing. (#2361)
