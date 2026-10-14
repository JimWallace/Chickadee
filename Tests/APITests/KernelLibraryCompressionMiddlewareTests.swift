// Compression happens in the HTTP server's channel pipeline, not in
// middleware, so the wire tests run against a real listening server
// (`.running`), as `ResponseCompressionTests` does. The files are served by a
// real FileMiddleware, so its Range and HEAD handling is part of the test.

import Testing
import VaporTesting

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) final class KernelLibraryCompressionMiddlewareTests {
    private static let kernelLibraryPath = "/jupyterlite/xeus/chickadee-octave/xoctave/liboctave.so"
    private static let otherLibraryPath = "/downloads/liboctave.so"

    private let publicDir: String
    private let tempRoot: String

    init() throws {
        tempRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-kernellib-\(UUID().uuidString)")
            .path
        publicDir = tempRoot + "/Public/"
        // Repeated bytes, so compression is unambiguously worthwhile.
        let library = String(repeating: "\u{7F}ELF side module bytes ", count: 200)
        for path in [Self.kernelLibraryPath, Self.otherLibraryPath] {
            let absolute = publicDir + path.dropFirst()
            try FileManager.default.createDirectory(
                atPath: (absolute as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try library.write(toFile: absolute, atomically: true, encoding: .utf8)
        }
    }

    deinit { try? FileManager.default.removeItem(atPath: tempRoot) }

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.http.server.configuration.responseCompression = .enabledForCompressibleTypes
        app.middleware.use(KernelLibraryCompressionMiddleware())
        app.middleware.use(FileMiddleware(publicDirectory: publicDir))
        return app
    }

    @Test func kernelLibraryIsGzippedOverTheWire() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                method: .running(hostname: "localhost", port: 0),
                .GET, Self.kernelLibraryPath,
                headers: ["Accept-Encoding": "gzip"]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentEncoding) == "gzip")
                #expect(res.headers[.vary].contains("Accept-Encoding"))
                // The override marker is internal. It must never reach the wire.
                #expect(res.headers.first(name: "X-Vapor-Response-Compression") == nil)
            }
        }
    }

    @Test func octetStreamOutsideTheKernelTreeIsNotCompressed() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                method: .running(hostname: "localhost", port: 0),
                .GET, Self.otherLibraryPath,
                headers: ["Accept-Encoding": "gzip"]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentEncoding) == nil)
            }
        }
    }

    @Test func clientWithoutAcceptEncodingGetsIdentity() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                method: .running(hostname: "localhost", port: 0),
                .GET, Self.kernelLibraryPath
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentEncoding) == nil)
            }
        }
    }

    /// A 206 keeps its identity `Content-Range`, so its body must stay identity.
    @Test func rangeRequestIsNotCompressed() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                method: .running(hostname: "localhost", port: 0),
                .GET, Self.kernelLibraryPath,
                headers: ["Accept-Encoding": "gzip", "Range": "bytes=0-99"]
            ) { res async in
                #expect(res.status == .partialContent)
                #expect(res.headers.first(name: .contentEncoding) == nil)
                #expect(res.body.readableBytes == 100)
            }
        }
    }

    /// A HEAD has no body to compress, so it must not advertise gzip.
    @Test func headRequestIsNotMarkedCompressed() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                method: .running(hostname: "localhost", port: 0),
                .HEAD, Self.kernelLibraryPath,
                headers: ["Accept-Encoding": "gzip"]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: .contentEncoding) == nil)
            }
        }
    }

    @Test(arguments: [
        ("/jupyterlite/xeus/chickadee-octave/xoctave/liboctinterp.so", true),
        ("/jupyterlite/xeus/chickadee-r/xr/libR.so", true),
        ("/jupyterlite/xeus/chickadee-python/kernel_packages/numpy-2.3.0.tar.gz", false),
        ("/jupyterlite/xeus/chickadee-python/bin/xpython.wasm", false),
        ("/jupyterlite/files/users/abc/liboctave.so", false),
    ])
    func pathClassification(path: String, isLibrary: Bool) {
        #expect(KernelLibraryCompressionMiddleware.isKernelSharedLibrary(path: path) == isLibrary)
    }
}
