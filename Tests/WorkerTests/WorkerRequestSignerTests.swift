import XCTest
import Vapor
import Crypto
@testable import chickadee_runner

final class WorkerRequestSignerTests: XCTestCase {
    func testSignerProducesExpectedHeadersAndSignature() {
        let signer = WorkerRequestSigner(sharedSecret: "secret-123", workerID: "worker-1")
        let path = "/internal/worker/ping"
        let body = ByteBuffer(string: #"{"submission":"sub_1"}"#)
        let timestamp: Int64 = 1_700_000_000
        let nonce = "nonce-abc"

        let headers = signer.signedHeaders(
            method: .POST,
            path: path,
            body: body,
            timestamp: timestamp,
            nonce: nonce
        )

        XCTAssertEqual(headers.first(name: "X-Worker-Id"), "worker-1")
        XCTAssertEqual(headers.first(name: "X-Worker-Timestamp"), String(timestamp))
        XCTAssertEqual(headers.first(name: "X-Worker-Nonce"), nonce)

        var bodyCopy = body
        let bodyBytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
        let bodyHash = SHA256.hash(data: Data(bodyBytes)).hexString
        let payload = [
            "POST",
            path,
            bodyHash,
            String(timestamp),
            nonce
        ].joined(separator: "\n")
        let expected = hmacSHA256Hex(message: payload, secret: "secret-123")

        XCTAssertEqual(headers.first(name: "X-Worker-Signature"), expected)
    }

    func testSignerOmitsWorkerIDWhenNil() {
        let signer = WorkerRequestSigner(sharedSecret: "secret-123", workerID: nil)
        let headers = signer.signedHeaders(
            method: .GET,
            path: "/internal/worker/ping",
            body: nil,
            timestamp: 1_700_000_000,
            nonce: "nonce-xyz"
        )

        XCTAssertNil(headers.first(name: "X-Worker-Id"))
        XCTAssertNotNil(headers.first(name: "X-Worker-Signature"))
        XCTAssertNotNil(headers.first(name: "X-Worker-Timestamp"))
        XCTAssertNotNil(headers.first(name: "X-Worker-Nonce"))
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
