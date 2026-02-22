import XCTest
import XCTVapor
import Crypto
@testable import chickadee_server

final class WorkerHMACAuthMiddlewareTests: XCTestCase {
    private let sharedSecret = "test-shared-secret"
    private let workerID = "worker-a"

    private func makeApp() throws -> Application {
        let app = Application(.testing)
        let middleware = WorkerHMACAuthMiddleware(
            configuration: .init(
                sharedSecret: sharedSecret,
                maxClockSkewSeconds: 60,
                nonceTTLSeconds: 300,
                requiredWorkerID: workerID
            )
        )
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
        let bodyHash = SHA256.hash(data: Data(bodyBytes)).hexString
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

    func testAcceptsValidSignature() throws {
        let app = try makeApp()
        defer { app.shutdown() }

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

        try app.test(.POST, path, beforeRequest: { req in
            req.headers = headers
            req.body = body
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })
    }

    func testRejectsMissingHeaders() throws {
        let app = try makeApp()
        defer { app.shutdown() }

        try app.test(.POST, "/internal/worker/ping", beforeRequest: { req in
            req.headers.contentType = .json
            req.body = ByteBuffer(string: #"{"ok":true}"#)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testRejectsStaleTimestamp() throws {
        let app = try makeApp()
        defer { app.shutdown() }

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

        try app.test(.POST, path, beforeRequest: { req in
            req.headers = headers
            req.body = body
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testRejectsReplayNonce() throws {
        let app = try makeApp()
        defer { app.shutdown() }

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

        try app.test(.POST, path, beforeRequest: { req in
            req.headers = headers
            req.body = body
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })

        try app.test(.POST, path, beforeRequest: { req in
            req.headers = headers
            req.body = body
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    func testRejectsBadSignature() throws {
        let app = try makeApp()
        defer { app.shutdown() }

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

        try app.test(.POST, path, beforeRequest: { req in
            req.headers = headers
            req.body = body
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .unauthorized)
        })
    }

    private func hmacSHA256Hex(message: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac).hexEncodedString()
    }
}

private extension Digest {
    var hexString: String {
        Data(self).hexEncodedString()
    }
}

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
