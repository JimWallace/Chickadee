### Changed

- **Strict memory safety for the tests.** The test targets now build with strict memory safety too, so every target uses one setting list. `MockURLProtocol` keeps its state in a `Mutex` instead of `nonisolated(unsafe)` statics, and the test helpers use swift-system for raw writes, pipes and `fstat`. The socket, `posix_spawn`, `setenv` and `sigaction` calls that remain are marked `unsafe`, with a reason (#2683).
