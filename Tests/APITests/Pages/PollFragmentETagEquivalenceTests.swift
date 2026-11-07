// Tests/APITests/Pages/PollFragmentETagEquivalenceTests.swift
//
// `Response.weakETag` hashes the rows in the pieces between the CSRF tokens
// instead of hashing a token-free copy made with `replacingOccurrences`. A
// client holds the old ETag across a deploy, and two processes behind the
// load balancer must agree, so the new ETag must be byte-identical to the
// old one for every input. These tests compare it with the old computation,
// kept here verbatim: real rows, tokens at the edges and back to back, and
// the inputs where a byte match and a composed-character match could
// disagree (a combining mark or a joiner beside a token, a token that is not
// lowercase hex).

import Crypto
import Foundation
import Testing

@testable import APIServer

/// A CSRF token in the shape the middleware mints: hex salt, a dash, hex digest.
private let token = "0f1e2d3c4b5a6978-" + String(repeating: "9a8b7c6d", count: 8)

@Suite struct PollFragmentETagEquivalenceTests {

    /// The ETag as `weakETag` computed it before the byte scan.
    private static func legacyETag(for html: String, ignoring csrfToken: String?) -> String {
        var text = html
        if let csrfToken, !csrfToken.isEmpty {
            text = text.replacingOccurrences(of: csrfToken, with: "")
        }
        let digest = SHA256.hash(data: Data(text.utf8))
        let hex = digest.map { String(cFormat: "%02x", $0) }.joined()
        return "W/\"\(hex.prefix(32))\""
    }

    private static var rosterRows: String {
        (0..<200).map { index in
            """
            <tr data-id="\(index)"><td>Ünïcødé Student \(index)</td><td><form method="post">\
            <input type="hidden" name="csrfToken" value="\(token)"><button>Reset</button></form>\
            <form><input type="hidden" name="csrfToken" value="\(token)"></form></td></tr>

            """
        }.joined()
    }

    @Test(arguments: [
        "", "no token here", token, "\(token)\(token)", "\(token)x\(token)", "x\(token)",
        "\(token)x", "\"\(token)\"", "é\(token)é", "e\u{301}\(token)\"", "\"\(token)\u{301}\"",
        "\"\(token)\u{200D}\"", "\u{200D}\(token)\"", "\u{1F1E6}\(token)\u{1F1E8}",
        "\r\(token)\n", String(token.dropLast()), "\(token.dropLast())é",
    ])
    func matchesTheReplacingOccurrencesETag(html: String) {
        #expect(Response.weakETag(for: html, ignoring: token) == Self.legacyETag(for: html, ignoring: token))
    }

    @Test func rosterRowsMatchTheReplacingOccurrencesETag() {
        let rows = Self.rosterRows
        #expect(Response.weakETag(for: rows, ignoring: token) == Self.legacyETag(for: rows, ignoring: token))
        #expect(Response.weakETag(for: rows) == Self.legacyETag(for: rows, ignoring: nil))
        #expect(Response.weakETag(for: rows, ignoring: "") == Self.legacyETag(for: rows, ignoring: ""))
    }

    @Test(arguments: ["K", "\u{212A}", "a;b", "ABC-def", "x\u{301}", "-", "f"])
    func tokensOutsideLowercaseHexMatchTheReplacingOccurrencesETag(token: String) {
        let html = "<p>K\u{212A};\u{37E}ABC-defx\u{301}-f\(token)\"\(token)\u{301}</p>"
        #expect(Response.weakETag(for: html, ignoring: token) == Self.legacyETag(for: html, ignoring: token))
    }
}
