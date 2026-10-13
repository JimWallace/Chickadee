// APIServer/Views/HTMLResponse.swift
//
// The Vapor glue for Elementary views (docs/elementary-spike.md). A route
// returns `HTMLResponse { SomePage(...) }` where it used to return
// `req.view.render(...)`.
//
// Owned here rather than taken from `vapor-community/vapor-elementary`: the
// wrapper is this one type, and owning it keeps the view layer independent of
// Vapor's major version.

import Elementary
import Vapor

struct HTMLResponse<Content: HTML>: AsyncResponseEncodable {
    let status: HTTPResponseStatus
    let content: Content

    init(status: HTTPResponseStatus = .ok, @HTMLBuilder content: () -> Content) {
        self.status = status
        self.content = content()
    }

    func encodeResponse(for request: Request) async throws -> Response {
        // `text/html; charset=utf-8`. SecurityHeadersMiddleware keys
        // its no-store and no-compression rules on the `text/html` prefix.
        var headers = HTTPHeaders()
        headers.contentType = .html
        return Response(status: status, headers: headers, body: .init(string: content.render()))
    }
}
