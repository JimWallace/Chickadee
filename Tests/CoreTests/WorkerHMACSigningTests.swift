// Tests/CoreTests/WorkerHMACSigningTests.swift
//
// `constantTimeEquals` is the comparison every runner request is admitted or
// refused by: `WorkerHMACAuthMiddleware` computes the expected signature and
// hands both strings here. Its two mutants from the 2026-08-19 sweep (run
// 32265903112) are the two ways a comparison can be wrong, and they fail in
// opposite, equally serious directions —
//
//   * `left.count != right.count` refuses every well-formed request: two
//     signatures of the same length return false before the loop runs, so the
//     runner fleet cannot authenticate at all.
//   * `result != 0` accepts every request whose signature is the wrong length
//     *and* rejects every correct one — an inverted verdict on a security
//     boundary.
//
// Both are killed by the full suite, via APITests' middleware tests, which the
// sweep does not run. A security primitive in Core whose only assertions are in
// an APIServer route suite is one refactor away from having none, so the
// primitive is pinned here directly.

import Foundation
import Testing

@testable import Core

@Suite struct WorkerHMACSigningTests {

    // MARK: - constantTimeEquals

    @Test func identicalStringsCompareEqual() {
        #expect(WorkerHMACSigning.constantTimeEquals("", ""))
        #expect(WorkerHMACSigning.constantTimeEquals("a", "a"))
        let signature = WorkerHMACSigning.hmacSHA256Hex(message: "m", secret: "s")
        #expect(WorkerHMACSigning.constantTimeEquals(signature, signature))
    }

    @Test func sameLengthDifferentContentComparesUnequal() {
        #expect(!WorkerHMACSigning.constantTimeEquals("abc", "abd"))
        // A single flipped bit in the first byte, and in the last: the XOR
        // accumulator must carry a difference wherever it occurs.
        #expect(!WorkerHMACSigning.constantTimeEquals("abc", "bbc"))
        #expect(!WorkerHMACSigning.constantTimeEquals("0000", "0001"))
    }

    @Test func differentLengthsCompareUnequal() {
        #expect(!WorkerHMACSigning.constantTimeEquals("abc", "abcd"))
        #expect(!WorkerHMACSigning.constantTimeEquals("abcd", "abc"))
        #expect(!WorkerHMACSigning.constantTimeEquals("", "a"))
        // A prefix is not a match, which is the case a length-blind loop over
        // the shorter side would accept.
        #expect(!WorkerHMACSigning.constantTimeEquals("a", "ab"))
    }

    /// The comparison is over UTF-8 bytes, not characters, so a multi-byte
    /// scalar cannot collapse two different strings onto one length.
    @Test func comparisonIsOverBytes() {
        #expect(WorkerHMACSigning.constantTimeEquals("é", "é"))
        #expect(!WorkerHMACSigning.constantTimeEquals("é", "e"))
    }

    // MARK: - hmacSHA256Hex

    /// RFC 4231 test case 1, so the digest is pinned against the standard
    /// rather than against itself. BrightSpace Valence signing shares this
    /// function, so a change here moves two callers at once.
    @Test func hmacMatchesTheRFC4231Vector() {
        let key = String(repeating: "\u{0b}", count: 20)
        #expect(
            WorkerHMACSigning.hmacSHA256Hex(message: "Hi There", secret: key)
                == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    }

    @Test func theDigestIsLowercaseHexOfFixedWidth() {
        let digest = WorkerHMACSigning.hmacSHA256Hex(message: "payload", secret: "secret")
        #expect(digest.count == 64)
        #expect(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}
