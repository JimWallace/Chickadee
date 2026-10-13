### Changed

- **The session driver wrapper is async.** `UnchangedSessionSkippingDriver` now conforms to `AsyncSessionDriver` and has no `EventLoopFuture` code. Behaviour does not change: an untouched session still skips its write. This removes the last future-based code from the server sources, which prepares for Vapor 5.
