// Tests/APITests/Infrastructure/SmallJSONCompressionTests.swift
//
// JSON under `SecurityHeadersMiddleware.smallJSONLimit` bytes goes out
// uncompressed (#2905): the result view's 2 s status poll is about 170 bytes,
// and a compressor per response cost more CPU than the bytes it saved. Larger
// JSON and other compressible types keep compression. Compression happens in
// the HTTP server's channel pipeline, so these tests run against a real
// listening server, as ResponseCompressionTests does.

import Testing
import VaporTesting

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct SmallJSONCompressionTests {

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.http.server.configuration.responseCompression = .enabledForCompressibleTypes
        app.middleware.use(SecurityHeadersMiddleware())
        app.get("small.json") { _ -> Response in
            Self.response(contentType: .json, bytes: 200)
        }
        app.get("large.json") { _ -> Response in
            Self.response(contentType: .json, bytes: 4096)
        }
        app.get("small.css") { _ -> Response in
            Self.response(contentType: HTTPMediaType(type: "text", subType: "css"), bytes: 200)
        }
        return app
    }

    private static func response(contentType: HTTPMediaType, bytes: Int) -> Response {
        let res = Response(status: .ok)
        res.headers.contentType = contentType
        let unit = contentType == .json ? "{\"key\":\"value\"}," : "a{b:c} "
        res.body = .init(string: String(String(repeating: unit, count: bytes / unit.utf8.count + 1).prefix(bytes)))
        return res
    }

    private func contentEncoding(of path: String) async throws -> (String?, String?) {
        var result: (String?, String?) = (nil, nil)
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                method: .running(hostname: "localhost", port: 0),
                .GET, path,
                headers: ["Accept-Encoding": "gzip"]
            ) { res async in
                #expect(res.status == .ok)
                result = (
                    res.headers.first(name: .contentEncoding), res.headers.first(name: "X-Vapor-Response-Compression")
                )
            }
        }
        return result
    }

    @Test func smallJSONIsNotCompressed() async throws {
        let (encoding, marker) = try await contentEncoding(of: "/small.json")
        #expect(encoding == nil)
        // The opt-out marker is internal; it must never reach the wire.
        #expect(marker == nil)
    }

    @Test func largeJSONIsStillCompressed() async throws {
        let (encoding, _) = try await contentEncoding(of: "/large.json")
        #expect(encoding == "gzip")
    }

    @Test func aSmallNonJSONTypeIsStillCompressed() async throws {
        let (encoding, _) = try await contentEncoding(of: "/small.css")
        #expect(encoding == "gzip")
    }
}
