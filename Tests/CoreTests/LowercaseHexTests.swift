// Tests/CoreTests/LowercaseHexTests.swift
//
// `lowercaseHex` replaced a `String(format: "%02x")` call per byte in the
// SHA-256 digests, the runner's HMAC signatures and the poll ETags. The server
// and the runner compare those strings byte for byte, so these tests pin the
// table lookup to the format call for every byte value and for real digests.

import Crypto
import Foundation
import Testing

@testable import Core

@Suite struct LowercaseHexTests {

    private static func formatHex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(cFormat: "%02x", $0) }.joined()
    }

    @Test func everyByteValueMatchesTheFormatCall() {
        let all = (0...255).map { UInt8($0) }
        #expect(lowercaseHex(all) == Self.formatHex(all))
        #expect(lowercaseHex([]) == "")
        #expect(lowercaseHex([0x00, 0x0A, 0xF0, 0xFF]) == "000af0ff")
    }

    @Test(arguments: ["", "abc", "Ünïcødé", String(repeating: "x", count: 10_000)])
    func digestsMatchTheFormatCall(text: String) {
        let digest = SHA256.hash(data: Data(text.utf8))
        #expect(sha256HexDigest(text) == Self.formatHex(digest))
        #expect(lowercaseHex(digest.prefix(16)) == String(Self.formatHex(digest).prefix(32)))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(text.utf8), using: SymmetricKey(data: Data("secret".utf8)))
        #expect(WorkerHMACSigning.hmacSHA256Hex(message: text, secret: "secret") == Self.formatHex(mac))
    }
}
