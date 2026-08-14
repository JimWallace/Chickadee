// APIServer/Utilities/PollFragmentResponse.swift
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
// What this deliberately does NOT save is the server's own work: the rows are
// queried and rendered before they can be hashed. Skipping that needs a cheap
// version stamp per table (a max(updated_at) + count probe), which is a
// different and more invasive change; the win here is on the client, where the
// repaint was doing real damage.

import Crypto
import Foundation
import Vapor

extension View {
    /// Encode a rendered row fragment as a conditional response: an `ETag` over
    /// the bytes, and `304 Not Modified` when the client already has them.
    ///
    /// The ETag is weak (`W/`) because these fragments are equivalent-for-
    /// display, not byte-identical resources — nothing does range requests
    /// against them.
    func encodePollFragment(for req: Request) -> Response {
        Response.pollFragment(html: data, for: req)
    }
}

extension Response {
    /// The empty-body case (no active course) takes the same path, so a client
    /// polling an empty table also settles into 304s instead of re-clearing it.
    static func emptyPollFragment(for req: Request) -> Response {
        pollFragment(html: ByteBuffer(), for: req)
    }

    static func pollFragment(html: ByteBuffer, for req: Request) -> Response {
        let etag = Self.weakETag(for: html)

        // A conditional request lists one or more candidates; `*` matches any
        // existing representation.
        let candidates = req.headers[.ifNoneMatch]
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if candidates.contains(etag) || candidates.contains("*") {
            var headers = HTTPHeaders()
            headers.replaceOrAdd(name: .eTag, value: etag)
            headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
            return Response(status: .notModified, headers: headers)
        }

        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
        headers.replaceOrAdd(name: .eTag, value: etag)
        // `no-cache` means "revalidate", not "do not store": the client is
        // expected to come back with If-None-Match, which is the whole point.
        headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        return Response(status: .ok, headers: headers, body: .init(buffer: html))
    }

    static func weakETag(for buffer: ByteBuffer) -> String {
        let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
        let digest = SHA256.hash(data: Data(bytes))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "W/\"\(hex.prefix(32))\""
    }
}
