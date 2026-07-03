// APIServer/Utilities/BlockingWork.swift
//
// Thread-pool offload for blocking work on request paths (#1156). Vapor
// route handlers run on the cooperative pool, which has only a handful of
// threads: synchronous file I/O or a subprocess wait on a handler parks one
// of them, and a burst of such requests (a lab section opening a notebook)
// starves every other request. Wrap the blocking section instead.

import NIOCore
import Vapor

/// Runs `body` on the application's NIOThreadPool, keeping the request's
/// event loop free. Use for synchronous file I/O, zip subprocess helpers,
/// and anything else that blocks.
func runBlocking<T: Sendable>(
    on req: Request,
    _ body: @escaping @Sendable () throws -> T
) async throws -> T {
    try await req.application.threadPool.runIfActive(eventLoop: req.eventLoop, body).get()
}

/// Application-scoped variant for call sites without a `Request`.
func runBlocking<T: Sendable>(
    app: Application,
    _ body: @escaping @Sendable () throws -> T
) async throws -> T {
    try await app.threadPool.runIfActive(eventLoop: app.eventLoopGroup.next(), body).get()
}
