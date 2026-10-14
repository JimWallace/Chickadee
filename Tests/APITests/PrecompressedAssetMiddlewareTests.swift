import Testing
import VaporTesting

@testable import APIServer

/// PrecompressedAssetMiddleware serves the image build's `<file>.br` copy of a
/// large kernel file to a browser that accepts br, and leaves every other
/// request to FileMiddleware.
@Suite final class PrecompressedAssetMiddlewareTests {
    private static let wasmPath = "/jupyterlite/xeus/chickadee-python/bin/xpython.wasm"
    private static let identityBody = "identity wasm bytes"
    private static let brotliBody = "brotli wasm bytes"

    private let publicDir: String
    private let tempRoot: String

    init() throws {
        tempRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-precompressed-\(UUID().uuidString)")
            .path
        publicDir = tempRoot + "/Public/"
        let fixtures: [(String, String)] = [
            (Self.wasmPath, Self.identityBody),
            (Self.wasmPath + ".br", Self.brotliBody),
            // A kernel file the image build left without a copy.
            ("/jupyterlite/xeus/chickadee-r/bin/xr.js", "identity r bytes"),
            // A copy outside the kernel tree is never served.
            ("/vendor/jszip.min.js", "identity vendor bytes"),
            ("/vendor/jszip.min.js.br", "brotli vendor bytes"),
        ]
        for (path, contents) in fixtures {
            let absolute = publicDir + path.dropFirst()
            try FileManager.default.createDirectory(
                atPath: (absolute as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try contents.write(toFile: absolute, atomically: true, encoding: .utf8)
        }
    }

    deinit { try? FileManager.default.removeItem(atPath: tempRoot) }

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(PrecompressedAssetMiddleware(publicDirectory: publicDir))
        app.middleware.use(FileMiddleware(publicDirectory: publicDir))
        return app
    }

    @Test func brotliClientGetsTheCopyWithTheOriginalType() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                .GET, Self.wasmPath, headers: ["Accept-Encoding": "gzip, deflate, br"]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == Self.brotliBody)
                #expect(res.headers.first(name: .contentEncoding) == "br")
                #expect(res.headers.contentType == HTTPMediaType(type: "application", subType: "wasm"))
                #expect(res.headers[.vary].contains("Accept-Encoding"))
                #expect(res.headers.responseCompression == .disable)
            }
        }
    }

    @Test func headRequestDescribesTheCopy() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.HEAD, Self.wasmPath, headers: ["Accept-Encoding": "br"]) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentEncoding) == "br")
            }
        }
    }

    @Test func theCopyRevalidatesOnItsOwnETag() async throws {
        try await withApp(try await makeApp()) { app in
            var etag: String?
            try await app.asyncTest(.GET, Self.wasmPath, headers: ["Accept-Encoding": "br"]) { res async in
                etag = res.headers.first(name: .eTag)
            }
            let brotliETag = try #require(etag)
            try await app.asyncTest(
                .GET, Self.wasmPath, headers: ["Accept-Encoding": "br", "If-None-Match": brotliETag]
            ) { res async in
                #expect(res.status == .notModified)
            }
        }
    }

    @Test(arguments: [
        ["Accept-Encoding": "gzip, deflate"],
        ["Accept-Encoding": "br;q=0, gzip"],
        ["Accept-Encoding": "br", "Range": "bytes=0-3"],
        [:],
    ])
    func otherRequestsGetTheOriginal(headers: [String: String]) async throws {
        try await withApp(try await makeApp()) { app in
            let requestHeaders = HTTPHeaders(headers.map { ($0.key, $0.value) })
            try await app.asyncTest(.GET, Self.wasmPath, headers: requestHeaders) { res async in
                #expect(res.status == .ok || res.status == .partialContent)
                #expect(res.headers.first(name: .contentEncoding) == nil)
                #expect(Self.identityBody.hasPrefix(res.body.string))
            }
        }
    }

    @Test(arguments: [
        ("/jupyterlite/xeus/chickadee-r/bin/xr.js", "identity r bytes"),
        ("/vendor/jszip.min.js", "identity vendor bytes"),
    ])
    func aFileWithoutAServedCopyGetsTheOriginal(path: String, body: String) async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.GET, path, headers: ["Accept-Encoding": "br"]) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == body)
                #expect(res.headers.first(name: .contentEncoding) == nil)
            }
        }
    }

    /// A traversal or a NUL in the path falls through to FileMiddleware, which
    /// refuses it or serves no copy.
    @Test(arguments: [
        "/jupyterlite/xeus/%2e%2e/%2e%2e/vendor/jszip.min.js",
        "/jupyterlite/xeus/../../vendor/jszip.min.js",
        "/jupyterlite/xeus/chickadee-python/bin/xpython.wasm%00",
    ])
    func aSuspectPathIsNeverServedACopy(path: String) async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.GET, path, headers: ["Accept-Encoding": "br"]) { res async in
                #expect(res.headers.first(name: .contentEncoding) == nil)
                #expect(!res.body.string.hasPrefix("brotli"))
            }
        }
    }

    /// The copy still gets the editor's isolation and cache headers from the
    /// middlewares registered before it, as in AppMiddleware.
    @Test func theCopyKeepsTheIsolationAndCacheHeaders() async throws {
        let app = try await Application.make(.testing)
        app.middleware.use(BundleAssetCacheMiddleware())
        app.middleware.use(NotebookAssetIsolationMiddleware(enabled: true))
        app.middleware.use(PrecompressedAssetMiddleware(publicDirectory: publicDir))
        app.middleware.use(FileMiddleware(publicDirectory: publicDir))
        try await withApp(app) { app in
            try await app.asyncTest(.GET, Self.wasmPath, headers: ["Accept-Encoding": "br"]) { res async in
                #expect(res.headers.first(name: .contentEncoding) == "br")
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == "require-corp")
                #expect(res.headers.first(name: "Cross-Origin-Resource-Policy") == "same-origin")
                #expect(res.headers.first(name: .cacheControl) == "no-cache")
            }
        }
    }

    @Test(arguments: [
        (["br"], true),
        (["gzip, deflate, br, zstd"], true),
        (["gzip", "br;q=0.5"], true),
        (["BR"], true),
        (["br;q=0"], false),
        (["br; q=0.0"], false),
        (["gzip"], false),
        (["brotli"], false),
        ([], false),
    ])
    func acceptEncodingParsing(values: [String], accepts: Bool) {
        #expect(PrecompressedAssetMiddleware.acceptsBrotli(values) == accepts)
    }
}
