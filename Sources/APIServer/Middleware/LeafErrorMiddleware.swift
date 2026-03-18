// APIServer/Middleware/LeafErrorMiddleware.swift
//
// Catches all errors thrown by route handlers or downstream middleware and
// renders a branded HTML error page for browser requests.  API and worker
// endpoints (/api/…, /worker/…) still receive a plain JSON error response so
// machine clients are not broken.

import Vapor

struct LeafErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch {
            let status: HTTPStatus
            let reason: String

            switch error {
            case let abort as AbortError:
                status = abort.status
                reason  = abort.reason
            default:
                status = .internalServerError
                reason  = "Something went wrong."
                request.logger.report(error: error)
            }

            // Machine clients (API / runner) get a compact JSON error.
            let path = request.url.path
            if path.hasPrefix("/api/") || path.hasPrefix("/worker/") {
                let escaped = reason
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json; charset=utf-8")
                return Response(
                    status: status,
                    headers: headers,
                    body: .init(string: #"{"error":true,"reason":"\#(escaped)"}"#)
                )
            }

            // Browser routes get a Leaf-rendered error page.
            let ctx = ErrorPageContext(
                currentUser: request.currentUserContext,
                status:      Int(status.code),
                title:       status.reasonPhrase,
                message:     reason,
                isNotFound:  status == .notFound
            )

            do {
                let view = try await request.view.render("error", ctx).get()
                var headers = HTTPHeaders()
                headers.contentType = .html
                return Response(status: status, headers: headers, body: .init(buffer: view.data))
            } catch {
                // Fallback if the template itself fails to render.
                return Response(status: status, body: .init(string: "\(status.code) \(reason)"))
            }
        }
    }
}

// MARK: - View context

private struct ErrorPageContext: Encodable {
    let currentUser: CurrentUserContext?
    let status:      Int
    let title:       String
    let message:     String
    let isNotFound:  Bool
}
