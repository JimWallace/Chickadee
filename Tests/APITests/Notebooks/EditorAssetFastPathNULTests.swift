import ChickadeeTestSupport
import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// A NUL in the decoded path must not reach the file APIs, which stop at it,
/// and a trailing slash must not reach `FilePath`, which drops it.
/// The fast path alone is registered, so a path it refuses falls through to
/// the router and gets 404.
@Suite final class EditorAssetFastPathNULTests {
    private let tempRoot: String
    private let publicDir: String

    init() throws {
        tempRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-fastpath-nul-\(UUID().uuidString)")
            .path
        publicDir = tempRoot + "/Public/"
        for relativePath in ["jupyterlite/build/stable.js", "vendor/jszip.min.js"] {
            let absolute = publicDir + relativePath
            try FileManager.default.createDirectory(
                atPath: URL(fileURLWithPath: absolute).deletingLastPathComponent().path,
                withIntermediateDirectories: true)
            try "bytes".write(toFile: absolute, atomically: true, encoding: .utf8)
        }
    }

    deinit {
        try? FileManager.default.removeItem(atPath: tempRoot)
    }

    @Test(arguments: [
        "/jupyterlite/build/stable.js%00.5a28c9e.js",
        "/vendor/jszip.min.js%00x",
        "/vendor/jszip.min.js/",
    ])
    func aSuspectPathIsNotServed(path: String) async throws {
        let app = try await Application.make(.testing)
        app.middleware.use(EditorAssetFastPathMiddleware(publicDirectory: publicDir))
        try await withApp(app) { app in
            try await app.asyncTest(.GET, path) { res async in
                #expect(res.status == .notFound)
                #expect(res.headers.first(name: .cacheControl) != "public, max-age=31536000, immutable")
            }
        }
    }

    @Test func theFileItselfIsServed() async throws {
        let app = try await Application.make(.testing)
        app.middleware.use(EditorAssetFastPathMiddleware(publicDirectory: publicDir))
        try await withApp(app) { app in
            try await app.asyncTest(.GET, "/vendor/jszip.min.js") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "bytes")
            }
        }
    }
}
