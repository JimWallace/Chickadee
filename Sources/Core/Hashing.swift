import Crypto
import Foundation

/// Lowercase-hex SHA-256 digest of `data`. Output is a stable 64-character
/// string. Used as a content fingerprint for manifest cache keys, the
/// v0.4.93 retest dedup column (`test_setups.last_retested_manifest_hash`),
/// and short cache busters.
///
/// Both `chickadee-server` and `chickadee-runner` rely on this format
/// matching byte-for-byte. Changing the algorithm or encoding would
/// silently break the retest gate — see `HashingTests` for the format
/// invariants enforced by the test suite.
public func sha256HexDigest(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Lowercase-hex SHA-256 digest of `string` interpreted as UTF-8 bytes.
public func sha256HexDigest(_ string: String) -> String {
    sha256HexDigest(Data(string.utf8))
}
