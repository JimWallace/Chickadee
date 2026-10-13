// APIServer/Utilities/BlockingWork.swift
//
// Thread-pool offload for blocking work on request paths (#1156). Vapor
// route handlers run on the cooperative pool, which has only a handful of
// threads: synchronous file I/O or a subprocess wait on a handler parks one
// of them, and a burst of such requests (a lab section opening a notebook)
// starves every other request. Wrap the blocking section instead.

import NIOPosix

/// Runs `body` on NIO's shared blocking thread pool, keeping the cooperative
/// pool free. Use for synchronous file I/O, zip subprocess helpers, and
/// anything else that blocks.
///
/// This is the pool Vapor 4 hands out as `application.threadPool`, so the
/// behaviour is unchanged. It is reached directly, without an event loop,
/// because Vapor 5 has neither (docs/vapor-5-migration.md).
func runBlocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await NIOThreadPool.singleton.runIfActive(body)
}
