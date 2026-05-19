import Core
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Signs worker → server requests with per-request HMAC signatures.
///
/// Call `sign(_:)` on a fully-configured `URLRequest` (method and body
/// already set) before sending it.  The added headers are validated
/// server-side by `WorkerHMACAuthMiddleware`.  Both sides delegate to
/// `Core/WorkerHMACSigning.swift` so the algorithm and signed-payload
/// format can't drift between server and worker.
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
        let method = (request.httpMethod ?? "GET").uppercased()
        let path = request.url?.path ?? "/"
        let body = request.httpBody ?? Data()

        let headers = WorkerHMACSigning.signedHeaders(
            method: method,
            path: path,
            body: body,
            secret: sharedSecret,
            workerID: workerID,
            timestamp: timestamp,
            nonce: nonce
        )

        request.setValue(headers.timestamp, forHTTPHeaderField: WorkerHMACSigning.Header.timestamp)
        request.setValue(headers.nonce, forHTTPHeaderField: WorkerHMACSigning.Header.nonce)
        request.setValue(headers.bodyHash, forHTTPHeaderField: WorkerHMACSigning.Header.bodyHash)
        request.setValue(headers.signature, forHTTPHeaderField: WorkerHMACSigning.Header.signature)
        if let workerID = headers.workerID, !workerID.isEmpty {
            request.setValue(workerID, forHTTPHeaderField: WorkerHMACSigning.Header.workerID)
        }
    }
}
