### Changed

- **Thread-pool use is behind `runBlocking` again (#1523).** The notebook merge in `SubmissionRoutes` and the DNS lookup in `SupportFileURLFetcher` called `threadPool.runIfActive` directly. They now call `runBlocking(on:)`, so `BlockingWork.swift` is the only file that touches the NIO thread pool. Behaviour does not change. A later Vapor 5 port changes one file, not three.
