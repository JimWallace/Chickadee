// APIServer/Middleware/RunnerWasmCacheMiddleware.swift
//
// Cache + content-type discipline for the browser wasm runner served out of
// Public/runner-wasm/. Registered immediately OUTSIDE FileMiddleware so it can
// rewrite the headers on FileMiddleware's static-file responses (FileMiddleware
// short-circuits the chain, so a middleware registered *after* it never sees
// these responses).
//
// Two artifacts, two policies:
//   * RunnerWasm.<hash>.wasm — content-hashed filename, so the bytes behind a
//     given URL never change. Cache it immutably for a year; a re-vendor
//     produces a new hash → new URL → clean bust. Also force
//     `Content-Type: application/wasm`, which WebAssembly.instantiateStreaming
//     requires (a wrong type silently disables streaming compilation).
//   * runner-core.js — the loader keeps a stable name and embeds the current
//     wasm hash, so it must revalidate to pick up a new hash after a re-vendor.
//     `no-cache` means "revalidate before use"; with FileMiddleware's ETag this
//     is a cheap 304 when unchanged.
//
// This lives at the origin (Vapor); the production nginx reverse proxy passes
// `/` straight through, so these headers reach the browser unmodified.

import Vapor

struct RunnerWasmCacheMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)

        let path = request.url.path
        guard path.hasPrefix("/runner-wasm/") else { return response }

        if path.hasSuffix(".wasm") {
            response.headers.replaceOrAdd(name: .contentType, value: "application/wasm")
            response.headers.replaceOrAdd(
                name: .cacheControl, value: "public, max-age=31536000, immutable")
        } else if path.hasSuffix(".js") {
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        }
        return response
    }
}
