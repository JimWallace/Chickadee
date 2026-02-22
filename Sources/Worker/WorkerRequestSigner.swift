import Crypto
import Foundation
import Vapor

/// Builds HMAC-signed headers for worker -> server internal requests.
///
/// This is intentionally not wired into request sending yet.
struct WorkerRequestSigner {
    let sharedSecret: String
    let workerID: String?

    init(sharedSecret: String, workerID: String? = nil) {
        self.sharedSecret = sharedSecret
        self.workerID = workerID
    }

    /// Generates headers matching `WorkerHMACAuthMiddleware` expectations.
    /// Signed payload format:
    ///   METHOD\nPATH\nBODY_SHA256\nTIMESTAMP\nNONCE
    func signedHeaders(
        method: HTTPMethod,
        path: String,
        body: ByteBuffer? = nil,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970),
        nonce: String = UUID().uuidString
    ) -> HTTPHeaders {
        let bodyBytes = bytes(from: body)
        let bodyHash = sha256Hex(bodyBytes)

        let timestampString = String(timestamp)
        let payload = [
            method.rawValue.uppercased(),
            path,
            bodyHash,
            timestampString,
            nonce
        ].joined(separator: "\n")

        let signature = hmacSHA256Hex(message: payload, secret: sharedSecret)

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: "X-Worker-Timestamp", value: timestampString)
        headers.replaceOrAdd(name: "X-Worker-Nonce", value: nonce)
        headers.replaceOrAdd(name: "X-Worker-Signature", value: signature)
        if let workerID, !workerID.isEmpty {
            headers.replaceOrAdd(name: "X-Worker-Id", value: workerID)
        }
        return headers
    }

    private func bytes(from body: ByteBuffer?) -> [UInt8] {
        guard var copy = body else { return [] }
        return copy.readBytes(length: copy.readableBytes) ?? []
    }

    private func sha256Hex(_ bytes: [UInt8]) -> String {
        let digest = SHA256.hash(data: Data(bytes))
        return Data(digest).hexEncodedString()
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
