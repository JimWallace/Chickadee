import Testing
import VaporTesting

@testable import APIServer

/// Exercises EditorAssetFastPathMiddleware in the production ordering:
/// fast path → UserFileNamespaceMiddleware → FileMiddleware.  The suite
/// pins the two invariants the fast path must never break:
///
///   1. The auth guard on /jupyterlite/…/files/users/ still runs — the
///      fast path must not serve student working copies to anonymous
///      callers just because they live under /jupyterlite/.
///   2. Immutable cache headers land only on content-hashed bundle
///      filenames; everything else gets an explicit `no-cache` so a
///      re-vendor that rewrites bytes in place is picked up on the next load
///      (an ETag alone lets the browser cache heuristically and skip the check).
@Suite final class EditorAssetFastPathMiddlewareTests {
    private let publicDir: String
    private let tempRoot: String

    init() throws {
        tempRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-fastpath-\(UUID().uuidString)")
            .path
        publicDir = tempRoot + "/Public/"
        let fixtures: [(relativePath: String, contents: String)] = [
            ("jupyterlite/build/100.5a28c9e.js", "hashed-chunk"),
            ("jupyterlite/build/MathJax_Main-Regular.woff", "font-bytes"),
            ("jupyterlite/extensions/@jupyterlite/kernel/static/154.377fd2862adcf65a4294.js", "hashed-ext"),
            ("jupyterlite/extensions/@jupyterlite/kernel/install.json", "{}"),
            ("jupyterlite/files/users/5f1c0b9a-0000-0000-0000-000000000000/work.ipynb", "student-work"),
            ("pyodide/pyodide-lock.json", "{}"),
            ("vendor/jszip.min.js", "jszip"),
        ]
        for fixture in fixtures {
            let absolute = publicDir + fixture.relativePath
            let directory = (absolute as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
            try fixture.contents.write(
                toFile: absolute, atomically: true, encoding: .utf8)
        }
        // A file OUTSIDE the public root — must never be reachable via the
        // fast path, traversal or otherwise.
        try "top-secret".write(
            toFile: tempRoot + "/secret.txt", atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempRoot)
    }

    private func makeApp(crossOriginIsolation: Bool = false) async throws -> Application {
        let app = try await Application.make(.testing)
        // Production order: fast path runs before any session/auth work,
        // the user-namespace guard and FileMiddleware after it.
        app.middleware.use(
            EditorAssetFastPathMiddleware(
                publicDirectory: publicDir, crossOriginIsolation: crossOriginIsolation))
        app.middleware.use(UserFileNamespaceMiddleware())
        app.middleware.use(FileMiddleware(publicDirectory: publicDir))
        return app
    }

    @Test func hashedBuildChunkIsServedWithImmutableCaching() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/jupyterlite/build/100.5a28c9e.js") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "hashed-chunk")
                #expect(
                    res.headers.first(name: .cacheControl)
                        == "public, max-age=31536000, immutable")
            }
        }
    }

    @Test func hashedExtensionAssetIsServedWithImmutableCaching() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(
                .GET, "/jupyterlite/extensions/@jupyterlite/kernel/static/154.377fd2862adcf65a4294.js"
            ) { res async in
                #expect(res.status == .ok)
                #expect(
                    res.headers.first(name: .cacheControl)
                        == "public, max-age=31536000, immutable")
            }
        }
    }

    @Test func unhashedBundleFilenameKeepsRevalidating() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(
                .GET, "/jupyterlite/build/MathJax_Main-Regular.woff"
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .cacheControl) == "no-cache")
                #expect(res.headers.first(name: .eTag) != nil)
            }
            try await app.testing().test(
                .GET, "/jupyterlite/extensions/@jupyterlite/kernel/install.json"
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .cacheControl) == "no-cache")
            }
        }
    }

    @Test func pyodideAndVendorAreFastPathedWithoutImmutableCaching() async throws {
        try await withApp(try await makeApp()) { app in
            for path in ["/pyodide/pyodide-lock.json", "/vendor/jszip.min.js"] {
                try await app.testing().test(.GET, path) { res async in
                    #expect(res.status == .ok)
                    #expect(res.headers.first(name: .cacheControl) == "no-cache")
                    #expect(res.headers.first(name: .eTag) != nil)
                }
            }
        }
    }

    @Test func userNamespaceFilesStillRequireAuthentication() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(
                .GET,
                "/jupyterlite/files/users/5f1c0b9a-0000-0000-0000-000000000000/work.ipynb"
            ) { res async in
                #expect(res.status == .unauthorized)
                #expect(res.body.string.contains("student-work") == false)
            }
        }
    }

    @Test func traversalAttemptsAreNotServedByTheFastPath() async throws {
        try await withApp(try await makeApp()) { app in
            for path in [
                "/jupyterlite/build/../../secret.txt",
                "/jupyterlite/build/%2e%2e/%2e%2e/secret.txt",
            ] {
                try await app.testing().test(.GET, path) { res async in
                    #expect(res.status != .ok)
                    #expect(res.body.string.contains("top-secret") == false)
                }
            }
        }
    }

    @Test func missingFastPathFileFallsThroughToTheNormalChain() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/jupyterlite/build/absent.js") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    // When cross-origin isolation is OFF (the default), the fast path must NOT
    // add COEP — the long-standing non-isolated behaviour the editor relies on
    // for its service-worker sync path.
    @Test func fastPathOmitsCOEPWhenIsolationDisabled() async throws {
        try await withApp(try await makeApp(crossOriginIsolation: false)) { app in
            for path in [
                "/jupyterlite/extensions/@jupyterlite/kernel/static/154.377fd2862adcf65a4294.js",
                "/pyodide/pyodide-lock.json",
            ] {
                try await app.testing().test(.GET, path) { res async in
                    #expect(res.status == .ok)
                    #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
                }
            }
        }
    }

    // When cross-origin isolation is ON, the fast path must stamp the COOP +
    // COEP + CORP trio on the vendored editor assets it serves — especially the
    // Pyodide kernel WORKER chunk, whose missing COEP was the worker-block: an
    // isolated editor page spawning a worker without COEP is blocked by Chrome.
    @Test func fastPathIsolatesEditorAssetsWhenEnabled() async throws {
        try await withApp(try await makeApp(crossOriginIsolation: true)) { app in
            // The hashed extension chunk stands in for the kernel worker chunk.
            for path in [
                "/jupyterlite/extensions/@jupyterlite/kernel/static/154.377fd2862adcf65a4294.js",
                "/jupyterlite/build/100.5a28c9e.js",
                "/pyodide/pyodide-lock.json",
                "/vendor/jszip.min.js",
            ] {
                try await app.testing().test(.GET, path) { res async in
                    #expect(res.status == .ok)
                    #expect(
                        res.headers.first(name: "Cross-Origin-Embedder-Policy") == "require-corp",
                        "fast-path asset \(path) must carry COEP so the isolated worker can load")
                    #expect(
                        res.headers.first(name: "Cross-Origin-Opener-Policy") == "same-origin")
                    #expect(
                        res.headers.first(name: "Cross-Origin-Resource-Policy") == "same-origin")
                }
            }
        }
    }

    @Test(arguments: [
        ("/jupyterlite/build/100.5a28c9e.js", true),
        ("/jupyterlite/build/154.377fd2862adcf65a4294.js.map", true),
        ("/jupyterlite/extensions/@jupyterlite/kernel/static/remoteEntry.5a28c9e12345.js", true),
        ("/jupyterlite/build/MathJax_Main-Regular.woff", false),
        ("/jupyterlite/extensions/@jupyterlite/kernel/install.json", false),
        ("/jupyterlite/build/bundle.js", false),
        ("/pyodide/pyodide.asm.wasm", false),
        ("/vendor/codemirror.js", false),
    ])
    func contentHashDetection(path: String, expected: Bool) {
        #expect(EditorAssetFastPathMiddleware.isContentHashedBundleAsset(path: path) == expected)
    }
}
