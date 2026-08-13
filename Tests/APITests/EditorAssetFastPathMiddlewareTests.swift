import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

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
            ("jupyterlite/xeus/chickadee-python/kernel_packages/numpy-2.5.1-py313h.tar.gz", "pkg"),
            ("jupyterlite/xeus/kernels.json", "[]"),
            ("jupyterlite/xeus/chickadee-python/xpython/kernel.json", "{}"),
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

    // Unhashed names on the fast path revalidate rather than cache immutably:
    // re-vendoring rewrites those bytes in place under a stable name, so
    // freezing them would pin a stale copy (#574's failure class).
    @Test func unhashedBundleAssetsAndVendorAreFastPathedWithoutImmutableCaching() async throws {
        try await withApp(try await makeApp()) { app in
            for path in ["/jupyterlite/build/MathJax_Main-Regular.woff", "/vendor/jszip.min.js"] {
                try await app.testing().test(.GET, path) { res async in
                    #expect(res.status == .ok)
                    #expect(res.headers.first(name: .cacheControl) == "no-cache")
                    #expect(res.headers.first(name: .eTag) != nil)
                }
            }
        }
    }

    // The kernel packages are the volume — up to 51 requests per boot — so they
    // take the fast path. Unhashed conda filenames keep revalidating: a
    // re-vendor rewrites those bytes under the same name.
    @Test func kernelPackagesAreFastPathed() async throws {
        try await withApp(try await makeApp(crossOriginIsolation: true)) { app in
            try await app.testing().test(
                .GET, "/jupyterlite/xeus/chickadee-python/kernel_packages/numpy-2.5.1-py313h.tar.gz"
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .cacheControl) == "no-cache")
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == "require-corp")
            }
        }
    }

    // …but the kernel STARTUP JSON deliberately is not. `kernels.json` and each
    // `kernel.json` are fetched while the editor is still coming up, before any
    // kernel exists, and short-circuiting the chain for those skips the cache
    // and isolation middlewares for the requests that bring the app up. The
    // whole-tree prefix (`/jupyterlite/xeus/`) would capture them, which is why
    // the middleware lists the `kernel_packages/` subtree instead. Asserted in
    // both directions so a well-meaning prefix widening fails here.
    @Test(arguments: [
        "/jupyterlite/xeus/kernels.json",
        "/jupyterlite/xeus/chickadee-python/xpython/kernel.json",
    ])
    func kernelStartupJSONStaysOnTheNormalChain(path: String) async throws {
        try await withApp(try await makeApp(crossOriginIsolation: true)) { app in
            try await app.testing().test(.GET, path) { res async in
                #expect(res.status == .ok, "\(path) must still be served")
                #expect(
                    res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil,
                    "\(path) is startup JSON and must not be short-circuited by the fast path")
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
                "/vendor/jszip.min.js",
            ] {
                try await app.testing().test(.GET, path) { res async in
                    #expect(res.status == .ok)
                    #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
                }
            }
        }
    }

    // When cross-origin isolation is ON, the fast path must stamp the COOP +
    // COEP + CORP trio on the vendored editor assets it serves — especially a
    // kernel WORKER chunk, whose missing COEP was the worker-block: an isolated
    // editor page spawning a worker without COEP is blocked by Chrome.
    @Test func fastPathIsolatesEditorAssetsWhenEnabled() async throws {
        try await withApp(try await makeApp(crossOriginIsolation: true)) { app in
            // The hashed extension chunk stands in for the kernel worker chunk.
            for path in [
                "/jupyterlite/extensions/@jupyterlite/kernel/static/154.377fd2862adcf65a4294.js",
                "/jupyterlite/build/100.5a28c9e.js",
                "/jupyterlite/build/MathJax_Main-Regular.woff",
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
        // Not on the fast path at all (see the middleware's prefix list), so it
        // can never be stamped immutable however its name looks.
        ("/jupyterlite/xeus/chickadee-python/bin/xpython.wasm", false),
        ("/vendor/codemirror.js", false),
    ])
    func contentHashDetection(path: String, expected: Bool) {
        #expect(EditorAssetFastPathMiddleware.isContentHashedBundleAsset(path: path) == expected)
    }

    private static var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)  // .../Tests/APITests/<thisFile>
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    /// Reads the SHIPPED bytes, not the language table, and requires every
    /// vendored kernel to be on the fast path.
    ///
    /// The hand-written list this replaced named Python and R only, so Lua and
    /// Octave — the largest env we ship — booted on the slow path, each of ~50
    /// package tarballs paying a session lookup it never needed. It fails open,
    /// which is why it went unnoticed: nothing breaks, the boot is just
    /// expensive. Deriving the list fixes today's gap; checking it against disk
    /// is what stops the next one, since a vendored kernel whose language
    /// forgot to declare a kernel would be invisible to a check that only read
    /// `allCases`.
    @Test func everyVendoredKernelPackageTreeTakesTheFastPath() throws {
        let xeusDir = Self.repoRoot.appendingPathComponent("Public/jupyterlite/xeus")
        let vendored = try FileManager.default.contentsOfDirectory(atPath: xeusDir.path)
            .filter { $0.hasPrefix("chickadee-") }
            .filter { environment in
                var isDirectory: ObjCBool = false
                let packages = xeusDir.appendingPathComponent("\(environment)/kernel_packages").path
                let exists = FileManager.default.fileExists(
                    atPath: packages, isDirectory: &isDirectory)
                return exists && isDirectory.boolValue
            }
            .sorted()

        // A derivation that silently produced nothing looks identical to a
        // correct one, so assert the check found something before trusting it.
        #expect(
            !vendored.isEmpty,
            "No vendored kernel_packages trees found under \(xeusDir.path) — this check read the wrong path"
        )

        for environment in vendored {
            let prefix = "/jupyterlite/xeus/\(environment)/kernel_packages/"
            #expect(
                EditorAssetFastPathMiddleware.fastPathPrefixes.contains(prefix),
                """
                \(environment) ships kernel_packages but is not on the editor asset fast path, so \
                every tarball of its boot rides the full session/auth chain. The prefix list is \
                derived from AssignmentLanguage.allCases — check that language's editorSupport.
                """
            )
        }
    }

    /// One prefix per kernel language, and none for an upload-only one: those
    /// envs are never vendored, so a prefix for them would be a dead string
    /// tested against every request path.
    @Test func kernelPrefixesTrackEditorSupportExactly() {
        let kernelLanguages = AssignmentLanguage.allCases.filter { language in
            if case .notebookKernel = language.editorSupport { return true }
            return false
        }
        #expect(!kernelLanguages.isEmpty)
        #expect(
            EditorAssetFastPathMiddleware.vendoredKernelPackagePrefixes.count
                == kernelLanguages.count)

        for language in AssignmentLanguage.allCases where language.editorSupport == .uploadOnly {
            let prefix =
                "/jupyterlite/xeus/\(KernelEnvironment.environmentName(for: language))/kernel_packages/"
            #expect(!EditorAssetFastPathMiddleware.fastPathPrefixes.contains(prefix))
        }
    }
}
