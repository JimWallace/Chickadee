import Core
import Testing
import XCTVapor

@testable import APIServer

@Suite struct StaticAssetCacheMiddlewareTests {

    private static let immutable = "public, max-age=31536000, immutable"

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(StaticAssetCacheMiddleware())
        app.get("styles.css") { _ -> Response in
            let res = Response(status: .ok)
            res.headers.contentType = HTTPMediaType(type: "text", subType: "css")
            res.body = .init(string: "body {}")
            return res
        }
        // Mirrors RunnerWasmCacheMiddleware's loader policy: a more specific
        // Cache-Control set further down the chain must survive.
        app.get("runner-core.js") { _ -> Response in
            let res = Response(status: .ok)
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
            return res
        }
        app.get("page") { _ in "html" }
        return app
    }

    @Test func versionedAssetGetsImmutableCacheControl() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(
                .GET, "/styles.css?v=\(ChickadeeVersion.current)"
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .cacheControl) == Self.immutable)
            }
        }
    }

    @Test func unversionedAssetKeepsDefaultRevalidation() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/styles.css") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .cacheControl) == nil)
            }
        }
    }

    @Test func staleVersionIsNotStamped() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/styles.css?v=0.0.0-stale") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .cacheControl) == nil)
            }
        }
    }

    @Test func existingCacheControlIsPreserved() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(
                .GET, "/runner-core.js?v=\(ChickadeeVersion.current)"
            ) { res async in
                #expect(res.headers.first(name: .cacheControl) == "no-cache")
            }
        }
    }

    @Test func nonAssetPathIsNotStamped() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(
                .GET, "/page?v=\(ChickadeeVersion.current)"
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .cacheControl) == nil)
            }
        }
    }

    @Test(arguments: [
        ("/styles.css", true),
        ("/app.js", true),
        ("/images/chickadee-icon-alt.png", true),
        ("/vendor/codemirror.js", true),
        ("/favicon.ico", true),
        ("/", false),
        ("/submissions/abc123", false),
        ("/testsetups/setup_1/notebook", false),
        ("/noextension", false),
    ])
    func isCacheableAssetPath(path: String, expected: Bool) {
        #expect(StaticAssetCacheMiddleware.isCacheableAssetPath(path) == expected)
    }
}
