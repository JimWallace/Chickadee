import Fluent
import Testing
import XCTVapor

@testable import APIServer

@Suite struct RunnerWasmCacheMiddlewareTests {

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(RunnerWasmCacheMiddleware())
        // Stand in for FileMiddleware's static-file responses.
        app.get("runner-wasm", "RunnerWasm.deadbeef.wasm") { _ in "wasmbytes" }
        app.get("runner-wasm", "runner-core.js") { _ in "loader" }
        app.get("styles.css") { _ in "css" }
        return app
    }

    @Test func hashedWasmIsImmutableAndApplicationWasm() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/runner-wasm/RunnerWasm.deadbeef.wasm") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentType) == "application/wasm")
                #expect(
                    res.headers.first(name: .cacheControl) == "public, max-age=31536000, immutable")
            }
        }
    }

    @Test func loaderRevalidates() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/runner-wasm/runner-core.js") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .cacheControl) == "no-cache")
            }
        }
    }

    @Test func unrelatedAssetIsUntouched() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/styles.css") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .cacheControl) == nil)
            }
        }
    }
}
