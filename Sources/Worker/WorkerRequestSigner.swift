import Crypto
import Core
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Signs worker → server requests with per-request HMAC signatures.
///
/// Call `sign(_:)` on a fully-configured URLRequest (method and body already
/// set) before sending it. The added headers are validated server-side by
/// `WorkerHMACAuthMiddleware`.
///
/// Signed payload format (fields joined by newlines):
///   METHOD\nPATH\nBODY_SHA256\nTIMESTAMP\nNONCE
struct WorkerRequestSigner: Sendable {
    let sharedSecret: String
    let workerID: String?

    init(sharedSecret: String, workerID: String? = nil) {
        self.sharedSecret = sharedSecret
        self.workerID = workerID
    }

    /// Adds HMAC auth headers to `request` in-place.
    /// The request's `httpMethod` and `httpBody` must be set before calling this.
    func sign(_ request: inout URLRequest) {
        applySignature(
            to: &request,
            timestamp: Int64(Date().timeIntervalSince1970),
            nonce: UUID().uuidString
        )
    }

    /// Adds HMAC auth headers with explicit timestamp and nonce (for testing).
    func sign(_ request: inout URLRequest, timestamp: Int64, nonce: String) {
        applySignature(to: &request, timestamp: timestamp, nonce: nonce)
    }

    private func applySignature(to request: inout URLRequest, timestamp: Int64, nonce: String) {
        let method   = (request.httpMethod ?? "GET").uppercased()
        let path     = request.url?.path ?? "/"
        let bodyBytes = request.httpBody.map { Array($0) } ?? []

        let tsString  = String(timestamp)
        let bodyHash  = sha256HexDigest(Data(bodyBytes))
        let payload   = [method, path, bodyHash, tsString, nonce].joined(separator: "\n")
        let signature = hmacSHA256Hex(message: payload, secret: sharedSecret)

        request.setValue(tsString, forHTTPHeaderField: "X-Worker-Timestamp")
        request.setValue(nonce,    forHTTPHeaderField: "X-Worker-Nonce")
        request.setValue(bodyHash, forHTTPHeaderField: "X-Worker-Body-SHA256")
        request.setValue(signature, forHTTPHeaderField: "X-Worker-Signature")
        if let workerID, !workerID.isEmpty {
            request.setValue(workerID, forHTTPHeaderField: "X-Worker-Id")
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
