// APIServer/Middleware/CSRFTokenRetrieval.swift
//
// Custom CSRF token-retrieval used by the app's single `CSRF` instance.
//
// It is byte-for-byte equivalent to the vendored library's default retrieval
// (same header keys, same `_csrf` body field, same `403 "No CSRF token
// provided."` on a miss) with one addition: when no token is found, it emits a
// structured `csrf_token_missing` log line.
//
// Why this exists: a "No CSRF token provided." 403 means the token never
// reached the server in the request — distinct from "Invalid CSRF token."
// (token present, wrong session). The two are diagnosed completely differently,
// but the bare library throws with no context, so production failures were
// invisible. The log line records enough to tell the sub-cases apart:
//   * no body / GET-shaped body            → a redirect swallowed the POST body
//   * urlencoded body, no `_csrf`          → the form rendered without the field
//   * multipart body                       → the multipart AJAX path didn't run
// so the next failure in prod explains itself instead of needing a repro.

import CSRF
import Vapor

/// Header names the CSRF middleware accepts a token under (mirrors the library).
private let csrfHeaderKeys: Set<String> = [
    "_csrf", "csrf-token", "xsrf-token", "x-csrf-token", "x-xsrf-token", "x-csrftoken",
]

/// Retrieves the CSRF token from a request header or the `_csrf` body field,
/// logging a structured diagnostic when neither is present.
@Sendable
func chickadeeCSRFTokenRetrieval(_ request: Request) -> EventLoopFuture<String> {
    let headerNames = Set(request.headers.map { $0.name })
    if let key = csrfHeaderKeys.intersection(headerNames).first,
        let token = request.headers[key].first
    {
        return request.eventLoop.makeSucceededFuture(token)
    }

    // `content.get` returns "" for a present-but-empty field (which then fails
    // validation as "Invalid"), and throws only when the field is absent or the
    // body can't be decoded — exactly the cases we want to surface.
    if let token = try? request.content.get(String.self, at: "_csrf") {
        return request.eventLoop.makeSucceededFuture(token)
    }

    let contentType = request.headers.first(name: .contentType) ?? "none"
    let contentLength = request.headers.first(name: .contentLength) ?? "none"
    request.logger.warning(
        """
        csrf_token_missing method=\(request.method.rawValue) path=\(request.url.path) \
        content-type=\(contentType) content-length=\(contentLength)
        """
    )
    return request.eventLoop.makeFailedFuture(
        Abort(.forbidden, reason: "No CSRF token provided."))
}
