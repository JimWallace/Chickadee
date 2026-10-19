### Changed

- **Strict memory safety for the server and runner.** The product targets build with Swift's strict memory safety mode, so unsafe code that is not marked `unsafe` does not compile. Most of the old unsafe calls now use safe swift-system and NIO APIs. The marks that remain (DNS resolution, `waitid`, the stream read, cgroup `mkdir`/`rmdir`) each have a comment that says why (#2683).
