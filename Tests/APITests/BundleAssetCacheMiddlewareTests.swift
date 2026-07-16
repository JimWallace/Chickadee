import Testing
import VaporTesting

@testable import APIServer

/// BundleAssetCacheMiddleware stamps cache policy on the editor-bundle assets
/// that ride the SLOW path (FileMiddleware) rather than the fast path — chiefly
/// /jupyterlite/jupyter-lite.json and the lab/notebooks/repl entry HTML. Pins:
///   1. stable-name bundle files (json, html) get `no-cache` so a deploy is
///      picked up on the next load instead of waiting on cache heuristics;
///   2. content-hashed chunks still get immutable caching;
///   3. paths outside /jupyterlite/ and /pyodide/ are left untouched.
@Suite final class BundleAssetCacheMiddlewareTests {
    private let publicDir: String
    private let tempRoot: String

    init() throws {
        tempRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-bundlecache-\(UUID().uuidString)")
            .path
        publicDir = tempRoot + "/Public/"
        let fixtures: [(String, String)] = [
            ("jupyterlite/jupyter-lite.json", "{}"),
            ("jupyterlite/lab/index.html", "<html></html>"),
            ("jupyterlite/build/100.5a28c9e.js", "hashed-chunk"),
            ("styles.css", "body{}"),
        ]
        for (relativePath, contents) in fixtures {
            let absolute = publicDir + relativePath
            try FileManager.default.createDirectory(
                atPath: (absolute as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try contents.write(toFile: absolute, atomically: true, encoding: .utf8)
        }
    }

    deinit { try? FileManager.default.removeItem(atPath: tempRoot) }

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(BundleAssetCacheMiddleware())
        app.middleware.use(FileMiddleware(publicDirectory: publicDir))
        return app
    }

    @Test func stableNameBundleConfigRevalidates() async throws {
        try await withApp(try await makeApp()) { app in
            for path in ["/jupyterlite/jupyter-lite.json", "/jupyterlite/lab/index.html"] {
                try await app.testing().test(.GET, path) { res async in
                    #expect(res.status == .ok)
                    #expect(res.headers.first(name: .cacheControl) == "no-cache")
                }
            }
        }
    }

    @Test func contentHashedSlowPathChunkIsImmutable() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/jupyterlite/build/100.5a28c9e.js") { res async in
                #expect(res.status == .ok)
                #expect(
                    res.headers.first(name: .cacheControl)
                        == "public, max-age=31536000, immutable")
            }
        }
    }

    @Test func nonBundlePathsAreUntouched() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/styles.css") { res async in
                #expect(res.status == .ok)
                // Not under /jupyterlite/ or /pyodide/, so this middleware adds nothing.
                #expect(res.headers.first(name: .cacheControl) == nil)
            }
        }
    }

    @Test(arguments: [
        ("/jupyterlite/build/100.5a28c9e.js", true),
        ("/jupyterlite/extensions/x/static/remoteEntry.c6732262d69c5d22.js", true),
        ("/jupyterlite/build/154.377fd2862adcf65a4294.js", true),
        ("/jupyterlite/jupyter-lite.json", false),
        ("/jupyterlite/extensions/x/static/pypi/all.json", false),
        ("/jupyterlite/extensions/x/static/pypi/pyodide_kernel-0.7.2-py3-none-any.whl", false),
        ("/pyodide/pyodide.asm.wasm", false),
        ("/pyodide/pyodide.asm.js", false),
        ("/jupyterlite/lab/index.html", false),
    ])
    func contentHashDetection(path: String, expected: Bool) {
        #expect(BundleAssetCacheMiddleware.isContentHashed(path) == expected)
    }
}
