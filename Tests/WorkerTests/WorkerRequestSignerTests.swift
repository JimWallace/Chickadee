import Crypto
import Foundation
import XCTest

@testable import chickadee_runner

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class WorkerRequestSignerTests: XCTestCase {

    func testSignerProducesExpectedHeadersAndSignature() {
        let signer = WorkerRequestSigner(sharedSecret: "secret-123", workerID: "worker-1")
        let url = URL(string: "http://localhost:8080/internal/worker/ping")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = #"{"submission":"sub_1"}"#.data(using: .utf8)

        let timestamp: Int64 = 1_700_000_000
        let nonce = "nonce-abc"
        signer.sign(&request, timestamp: timestamp, nonce: nonce)

        let bodyBytes = Array(#"{"submission":"sub_1"}"#.utf8)
        let bodyHash = Data(SHA256.hash(data: Data(bodyBytes))).hexEncodedString()

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Worker-Id"), "worker-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Worker-Timestamp"), String(timestamp))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Worker-Nonce"), nonce)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Worker-Body-SHA256"), bodyHash)

        let payload = ["POST", "/internal/worker/ping", bodyHash, String(timestamp), nonce]
            .joined(separator: "\n")
        let expected = hmacSHA256Hex(message: payload, secret: "secret-123")

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Worker-Signature"), expected)
    }

    func testSignerOmitsWorkerIDWhenNil() {
        let signer = WorkerRequestSigner(sharedSecret: "secret-123", workerID: nil)
        let url = URL(string: "http://localhost:8080/internal/worker/ping")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        signer.sign(&request, timestamp: 1_700_000_000, nonce: "nonce-xyz")

        XCTAssertNil(request.value(forHTTPHeaderField: "X-Worker-Id"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Worker-Signature"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Worker-Timestamp"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Worker-Nonce"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Worker-Body-SHA256"))
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
