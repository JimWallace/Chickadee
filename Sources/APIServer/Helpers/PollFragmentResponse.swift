// APIServer/Helpers/PollFragmentResponse.swift
//
// Conditional responses for the three `?fragment=rows` poll endpoints
// (`/instructor/students-data`, `/admin/users-data`, `/admin/runners`).
//
// `table-poll.js` refetches these every five seconds for as long as a
// dashboard is open, and until now every response was a 200 carrying the whole
// table — so an idle roster nobody was touching still replaced its `<tbody>`
// twelve times a minute. That is not just bytes: replacing the rows throws away
// their DOM state and forces the page to rebuild what the server does not know
// about — relative times, the user's sort, the user's filter, each page's own
// decorations — and destroys anything else in there, such as a pending
// student's open registration panel.
//
// An ETag over the rendered bytes makes "nothing changed" cost one 304 and no
// client work at all. The hash is SHA-256 rather than Swift's `Hasher`, whose
// seed is per-process: two app processes behind the load balancer would
// otherwise disagree about the ETag for identical rows and each poll would
// repaint whichever process it did not hit last.
//
// The rows carry CSRF tokens, and every token has a fresh random salt, so two
// renders of the same rows never have the same bytes. The ETag is therefore
// taken over the rows with the request's token removed. On a 304 the client
// keeps its rows, and their older tokens stay valid for the same session. A
// new session secret (a log-in as someone else in another tab) makes them
// stale; the page is then stale anyway, and a reload fixes both.
//
// What this deliberately does NOT save is the server's own work: the rows are
// queried and rendered before they can be hashed. Skipping that needs a cheap
// version stamp per table (a max(updated_at) + count probe), which is a
// different and more invasive change; the win here is on the client, where the
// repaint was doing real damage.

import Core
import Crypto
import Foundation
import Vapor

extension Response {
    /// The empty-body case (no active course) takes the same path, so a client
    /// polling an empty table also settles into 304s instead of re-clearing it.
    static func emptyPollFragment(for req: Request) -> Response {
        pollFragment(html: "", for: req)
    }

    /// `csrfToken` is the token the rows were rendered with. It is left out
    /// of the ETag, so unchanged rows get the same ETag on every poll.
    static func pollFragment(html: String, csrfToken: String? = nil, for req: Request) -> Response {
        let etag = Self.weakETag(for: html, ignoring: csrfToken)
        if let notModified = notModified(etag: etag, for: req) { return notModified }

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
        headers.replaceOrAdd(name: .eTag, value: etag)
        // `no-cache` means "revalidate", not "do not store": the client is
        // expected to come back with If-None-Match, which is the whole point.
        headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        return Response(status: .ok, headers: headers, body: .init(string: html))
    }

    /// A 304 when the request already holds `etag`, else nil. Shared by the
    /// HTML fragments and the class composite's JSON (`conditionalJSON`).
    static func notModified(etag: String, for req: Request) -> Response? {
        // A conditional request lists one or more candidates; `*` matches any
        // existing representation.
        let candidates = req.headers[.ifNoneMatch]
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard candidates.contains(etag) || candidates.contains("*") else { return nil }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .eTag, value: etag)
        headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        return Response(status: .notModified, headers: headers)
    }

    /// SHA-256 over `html` with every `csrfToken` removed, as the first 32
    /// lowercase hex digits. The rows are hashed in the pieces between the
    /// tokens rather than through a token-free copy: on a 1000-student roster
    /// `replacingOccurrences` alone took about 60 ms per poll, and the byte
    /// scan takes about 2 ms. The bytes hashed are the same, so the ETag is.
    static func weakETag(for html: String, ignoring csrfToken: String? = nil) -> String {
        let bytes = Array(html.utf8)
        var hasher = SHA256()
        if let csrfToken, !csrfToken.isEmpty {
            if let kept = rangesOutsideToken(Array(csrfToken.utf8), in: bytes) {
                for range in kept { hasher.update(data: bytes[range]) }
            } else {
                hasher.update(data: Data(html.replacingOccurrences(of: csrfToken, with: "").utf8))
            }
        } else {
            hasher.update(data: bytes)
        }
        return "W/\"\(lowercaseHex(hasher.finalize().prefix(16)))\""
    }

    /// The ranges of `bytes` left once every occurrence of `token` is cut,
    /// leftmost first and without overlap, as `replacingOccurrences(of:with:)`
    /// cuts them. nil when that call might cut a different set, and the caller
    /// then makes it: it matches composed characters, not bytes, so an
    /// occurrence next to a combining mark is one it may skip. A token of
    /// lowercase hex digits and dashes (every CSRF token) with an ASCII byte
    /// or the end of the rows on each side matches both ways.
    private static func rangesOutsideToken(_ token: [UInt8], in bytes: [UInt8]) -> [Range<Int>]? {
        let isTokenByte: (UInt8) -> Bool = { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte) || byte == UInt8(ascii: "-")
        }
        guard let first = token.first, token.allSatisfy(isTokenByte) else { return nil }
        var kept: [Range<Int>] = []
        var start = 0
        var index = 0
        while index + token.count <= bytes.count {
            guard bytes[index] == first, bytes[index..<index + token.count].elementsEqual(token) else {
                index += 1
                continue
            }
            let end = index + token.count
            if index > 0, bytes[index - 1] >= 0x80 { return nil }
            if end < bytes.count, bytes[end] >= 0x80 { return nil }
            kept.append(start..<index)
            start = end
            index = end
        }
        kept.append(start..<bytes.count)
        return kept
    }
}
