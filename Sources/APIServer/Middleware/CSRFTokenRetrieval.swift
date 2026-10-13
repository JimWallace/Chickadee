// APIServer/Middleware/CSRFTokenRetrieval.swift
//
// The CSRF token retrieval that `CSRFMiddleware` uses.
//
// It accepts the same header keys and `_csrf` body field as the default
// retrieval of the `vapor-community/CSRF` package, which Chickadee used before
// it had its own middleware, and it gives the same `403 "No CSRF token
// provided."` on a miss. It differs in two ways:
//
// 1. **It collects the request body before reading `_csrf`.** Vapor only
//    dispatches a request with a pre-collected body when the entire body
//    arrives in the same channel read as the head (`HTTPServerRequestDecoder`
//    requires the first body chunk to exactly equal Content-Length; anything
//    else — a body split across TCP reads, or chunked transfer-encoding —
//    is dispatched immediately as a *streaming* body). Middleware runs before
//    the route's `.collect` step, so a synchronous `request.content.get` sees
//    `body.data == nil` for every such request and the library's default
//    retrieval 403s it with "No CSRF token provided." even though the form
//    field is on the wire. That split is routine on real networks/proxies and
//    never happens under XCTVapor (in-memory bodies are always collected),
//    which is why this only ever surfaced in production (#868's TA report:
//    extension save → 403). Collecting first makes the read reliable, and the
//    route's own `.collect` then short-circuits on the already-collected body.
//
// 2. When no token is found, it emits a structured `csrf_token_missing` log
//    line. A "No CSRF token provided." 403 means the token never reached the
//    server in the request — distinct from "Invalid CSRF token." (token
//    present, wrong session). The two are diagnosed completely differently,
//    but the bare library throws with no context, so production failures were
//    invisible. The log line records enough to tell the sub-cases apart:
//      * no body / GET-shaped body            → a redirect swallowed the POST body
//      * urlencoded body, no `_csrf`          → the form rendered without the field
//      * multipart body                       → the multipart AJAX path didn't run
//    so the next failure in prod explains itself instead of needing a repro.

import Vapor

/// Header names the CSRF middleware accepts a token under.
private let csrfHeaderKeys: Set<String> = [
    "_csrf", "csrf-token", "xsrf-token", "x-csrf-token", "x-xsrf-token", "x-csrftoken",
]

/// Retrieves the CSRF token from a request header or the `_csrf` body field,
/// logging a structured diagnostic when neither is present.
func chickadeeCSRFTokenRetrieval(_ request: Request) async throws -> String {
    let headerNames = Set(request.headers.map { $0.name })
    if let key = csrfHeaderKeys.intersection(headerNames).first,
        let token = request.headers[key].first
    {
        return token
    }

    // The body may still be streaming at middleware time (see header comment);
    // collect it before reading. Same size cap as the route's own `.collect`
    // step, and an oversized body fails here exactly as it would there.
    _ = try await request.body.collect(max: request.application.routes.defaultMaxBodySize.value).get()

    // `content.get` returns "" for a present-but-empty field (which then
    // fails validation as "Invalid"), and throws only when the field is
    // absent or the body can't be decoded — exactly the cases we want to
    // surface.
    if let token = try? request.content.get(String.self, at: "_csrf") {
        return token
    }

    let contentType = request.headers.first(name: .contentType) ?? "none"
    let contentLength = request.headers.first(name: .contentLength) ?? "none"
    request.logger.warning(
        """
        csrf_token_missing method=\(request.method.rawValue) path=\(request.url.path) \
        content-type=\(contentType) content-length=\(contentLength)
        """
    )
    throw Abort(.forbidden, reason: "No CSRF token provided.")
}
