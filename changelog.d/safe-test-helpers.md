### Changed

- **Fewer unsafe calls in the tests.** The daemon retry tests pass their retry delays through the daemon's `config` instead of `setenv`, so they no longer need an exit test. The two raw-socket test clients use AsyncHTTPClient and NIO's `ClientBootstrap` (#2683).
