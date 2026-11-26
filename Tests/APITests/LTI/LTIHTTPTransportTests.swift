// Tests/APITests/LTI/LTIHTTPTransportTests.swift
//
// `LTIHTTPTransport` against a local server (docs/compliance/lti-audit-2026-10.md
// L-4): a normal answer comes back whole, with its status, headers and body;
// a body over the cap is refused; and a body that arrives slowly is cut off at
// the deadline even though bytes keep arriving, which the client's read timeout
// and AsyncHTTPClient's own deadline do not do.

import AsyncHTTPClient
import Foundation
import NIOCore
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(1))) struct LTIHTTPTransportTests {
    /// Runs `body` against a local server with three routes, then shuts both
    /// the server and the client down.
    private func withPlatform(_ body: (String, HTTPClient) async throws -> Void) async throws {
        let server = try await Application.make(Environment(name: "testing", arguments: ["test"]))
        server.http.server.configuration.hostname = "127.0.0.1"
        server.http.server.configuration.port = 0
        server.post("token") { req async throws -> Response in
            let response = Response(status: .created, body: .init(string: #"{"echo":"\#(req.body.string ?? "")"}"#))
            response.headers.contentType = .json
            response.headers.replaceOrAdd(name: "X-Platform", value: "test")
            return response
        }
        server.get("large") { _ async throws -> Response in
            Response(status: .ok, body: .init(string: String(repeating: "x", count: 4096)))
        }
        server.get("drip") { _ async throws -> Response in
            let response = Response(status: .ok)
            response.body = .init(asyncStream: { writer in
                // One byte every 100 ms for 10 s: never idle long enough for a
                // read timeout, far past the test's deadline.
                // Vapor asserts that a stream ends with `.end` or `.error`,
                // and the client hangs up partway, so the error is sent too.
                do {
                    for _ in 0..<100 {
                        try await writer.write(.buffer(ByteBuffer(string: "x")))
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    try await writer.write(.end)
                } catch {
                    try? await writer.write(.error(error))
                }
            })
            return response
        }
        server.environment.arguments = ["serve"]
        try await server.asyncBoot()
        try await server.startup()
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        do {
            let port = try #require(server.http.server.shared.localAddress?.port)
            try await body("http://127.0.0.1:\(port)", client)
        } catch {
            try await client.shutdown()
            try await server.asyncShutdown()
            throw error
        }
        try await client.shutdown()
        try await server.asyncShutdown()
    }

    @Test func answerComesBackWithStatusHeadersAndBody() async throws {
        try await withPlatform { base, client in
            var headers = HTTPHeaders()
            headers.contentType = .plainText
            let response = try await LTIHTTPTransport.send(
                ClientRequest(
                    method: .POST, url: URI(string: base + "/token"), headers: headers,
                    body: ByteBuffer(string: "grant")),
                on: client)
            #expect(response.status == .created)
            #expect(response.headers.first(name: "X-Platform") == "test")
            #expect(response.body.map { String(buffer: $0) } == #"{"echo":"grant"}"#)
        }
    }

    @Test func bodyOverTheCapIsRefused() async throws {
        try await withPlatform { base, client in
            await #expect(throws: LTIHTTPTransport.Failure.responseTooLarge) {
                _ = try await LTIHTTPTransport.send(
                    ClientRequest(method: .GET, url: URI(string: base + "/large")), on: client,
                    maximumBodyBytes: 1024)
            }
        }
    }

    @Test func slowBodyIsCutOffAtTheDeadline() async throws {
        try await withPlatform { base, client in
            let start = ContinuousClock.now
            await #expect(throws: LTIHTTPTransport.Failure.timedOut) {
                _ = try await LTIHTTPTransport.send(
                    ClientRequest(method: .GET, url: URI(string: base + "/drip")), on: client,
                    timeout: .milliseconds(500))
            }
            #expect(ContinuousClock.now - start < .seconds(5))
        }
    }
}
