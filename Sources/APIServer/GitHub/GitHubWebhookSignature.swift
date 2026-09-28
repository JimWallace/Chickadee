// APIServer/GitHub/GitHubWebhookSignature.swift
//
// The check on every webhook delivery (docs/github-submissions.md slice 5):
// `X-Hub-Signature-256` must be `sha256=` and the hex HMAC-SHA256 of the raw
// body under the App's webhook secret. The comparison is constant time.

import Crypto
import Foundation

enum GitHubWebhookSignature {
    static let prefix = "sha256="

    static func isValid(body: Data, header: String?, secret: String) -> Bool {
        guard !secret.isEmpty, let header, header.hasPrefix(prefix),
            let mac = bytes(fromHex: String(header.dropFirst(prefix.count))), mac.count == SHA256.byteCount
        else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            mac, authenticating: body, using: SymmetricKey(data: Data(secret.utf8)))
    }

    /// The header value for `body`, as GitHub computes it. Tests use it.
    static func header(body: Data, secret: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        return prefix + mac.map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}
