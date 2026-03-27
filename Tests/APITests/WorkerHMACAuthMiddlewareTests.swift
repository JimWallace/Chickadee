import XCTest
import XCTVapor
import Crypto
@testable import chickadee_server

final class WorkerHMACAuthMiddlewareTests: XCTestCase {
    private let sharedSecret = "test-shared-secret"
    private let workerID = "worker-a"

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.workerSecretStore = WorkerSecretStore(initialOverride: sharedSecret)
        let middleware = WorkerHMACAuthMiddleware(maxClockSkewSeconds: 60, nonceTTLSeconds: 300)
        app.grouped(middleware).post("internal", "worker", "ping") { _ in
            HTTPStatus.ok
        }
        return app
    }

    private func signedHeaders(
        method: HTTPMethod,
        path: String,
        body: ByteBuffer,
        timestamp: Int64,
        nonce: String
    ) -> HTTPHeaders {
        var bodyCopy = body
        let bodyBytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
        let bodyHash = Data(SHA256.hash(data: Data(bodyBytes))).hexEncodedString()
        let payload = [
            method.rawValue.uppercased(),
            path,
            bodyHash,
            String(timestamp),
            nonce
        ].joined(separator: "\n")
        let signature = hmacSHA256Hex(message: payload, secret: sharedSecret)

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: "X-Worker-Id", value: workerID)
        headers.replaceOrAdd(name: "X-Worker-Timestamp", value: String(timestamp))
        headers.replaceOrAdd(name: "X-Worker-Nonce", value: nonce)
        headers.replaceOrAdd(name: "X-Worker-Signature", value: signature)
        headers.contentType = .json
        return headers
    }

    func testAcceptsValidSignature() async throws {
        let path = "/internal/worker/ping"
        let now = Int64(Date().timeIntervalSince1970)
        let body = ByteBuffer(string: #"{"ok":true}"#)
        let headers = signedHeaders(
            method: .POST,
            path: path,
            body: body,
            timestamp: now,
            nonce: UUID().uuidString
        )

        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.POST, path, beforeRequest: { req async in
                req.headers = headers
                req.body = body
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .ok)
            })
        }
    }

    func testRejectsMissingHeaders() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.POST, "/internal/worker/ping", beforeRequest: { req async in
                req.headers.contentType = .json
                req.body = ByteBuffer(string: #"{"ok":true}"#)
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .unauthorized)
            })
        }
    }

    func testRejectsStaleTimestamp() async throws {
        let path = "/internal/worker/ping"
        let old = Int64(Date().timeIntervalSince1970) - 10_000
        let body = ByteBuffer(string: #"{"ok":true}"#)
        let headers = signedHeaders(
            method: .POST,
            path: path,
            body: body,
            timestamp: old,
            nonce: UUID().uuidString
        )

        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.POST, path, beforeRequest: { req async in
                req.headers = headers
                req.body = body
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .unauthorized)
            })
        }
    }

    func testRejectsReplayNonce() async throws {
        let path = "/internal/worker/ping"
        let now = Int64(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString
        let body = ByteBuffer(string: #"{"ok":true}"#)
        let headers = signedHeaders(
            method: .POST,
            path: path,
            body: body,
            timestamp: now,
            nonce: nonce
        )

        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.POST, path, beforeRequest: { req async in
                req.headers = headers
                req.body = body
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .ok)
            })

            try await app.testable().test(.POST, path, beforeRequest: { req async in
                req.headers = headers
                req.body = body
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .unauthorized)
            })
        }
    }

    func testRejectsBadSignature() async throws {
        let path = "/internal/worker/ping"
        let now = Int64(Date().timeIntervalSince1970)
        let body = ByteBuffer(string: #"{"ok":true}"#)
        var headers = signedHeaders(
            method: .POST,
            path: path,
            body: body,
            timestamp: now,
            nonce: UUID().uuidString
        )
        headers.replaceOrAdd(name: "X-Worker-Signature", value: "deadbeef")

        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.POST, path, beforeRequest: { req async in
                req.headers = headers
                req.body = body
            }, afterResponse: { res async in
                XCTAssertEqual(res.status, .unauthorized)
            })
        }
    }

    /// Regression test: sends a real HTTP request through Vapor's HTTP server
    /// to verify the middleware collects the streaming body before hashing.
    ///
    /// The in-memory `.test()` helper pre-buffers the body, so `request.body.data`
    /// is always non-nil. In production, the body arrives as a stream and must be
    /// explicitly collected in middleware before `request.body.data` is available.
    /// Without the `body.collect()` call in the middleware, the body hash is always
    /// SHA256(""), causing every signed POST to fail with "Invalid worker signature."
    func testAcceptsValidSignatureOverRealHTTP() async throws {
        let path = "/internal/worker/ping"
        let now = Int64(Date().timeIntervalSince1970)
        let body = ByteBuffer(string: #"{"workerID":"test","hostname":"localhost"}"#)
        let headers = signedHeaders(
            method: .POST,
            path: path,
            body: body,
            timestamp: now,
            nonce: UUID().uuidString
        )

        try await withApp(try await makeApp()) { app in
            try await app.testable(method: .running(hostname: "localhost", port: 0)).test(
                .POST,
                path,
                headers: headers,
                body: body
            ) { res async in
                XCTAssertEqual(res.status, .ok,
                    "HMAC with non-empty body must succeed over real HTTP — "
                    + "middleware must collect() the streaming body before computing the hash")
            }
        }
    }

    private func hmacSHA256Hex(message: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac).hexEncodedString()
    }
}

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
