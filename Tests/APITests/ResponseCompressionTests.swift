// Exercises the response-compression configuration end to end.  Compression
// happens in the HTTP server's channel pipeline, not in middleware, so these
// tests must run against a real listening server (`.running`) — in-memory
// tests bypass the compressor entirely.

import Testing
import VaporTesting

@testable import APIServer

@Suite struct ResponseCompressionTests {

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.http.server.configuration.responseCompression = .enabledForCompressibleTypes
        app.middleware.use(SecurityHeadersMiddleware())
        // Bodies are repeated text so compression is unambiguously worthwhile.
        let filler = String(repeating: "body { color: #333; margin: 0 auto; } ", count: 100)
        app.get("styles.css") { _ -> Response in
            let res = Response(status: .ok)
            res.headers.contentType = HTTPMediaType(type: "text", subType: "css")
            res.body = .init(string: filler)
            return res
        }
        app.get("page") { _ -> Response in
            let res = Response(status: .ok)
            res.headers.contentType = .html
            res.body = .init(string: "<html><body>\(filler)</body></html>")
            return res
        }
        return app
    }

    @Test func compressibleAssetIsGzippedOverTheWire() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing(method: .running(hostname: "localhost", port: 0)).test(
                .GET, "/styles.css",
                headers: ["Accept-Encoding": "gzip"]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentEncoding) == "gzip")
            }
        }
    }

    @Test func htmlIsExcludedFromCompression() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing(method: .running(hostname: "localhost", port: 0)).test(
                .GET, "/page",
                headers: ["Accept-Encoding": "gzip"]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentEncoding) == nil)
                // The opt-out marker is internal — it must never reach the wire.
                #expect(res.headers.first(name: "X-Vapor-Response-Compression") == nil)
            }
        }
    }

    @Test func clientWithoutAcceptEncodingGetsIdentity() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing(method: .running(hostname: "localhost", port: 0)).test(
                .GET, "/styles.css"
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentEncoding) == nil)
            }
        }
    }
}
