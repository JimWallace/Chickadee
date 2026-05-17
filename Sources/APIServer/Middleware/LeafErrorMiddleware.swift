// APIServer/Middleware/LeafErrorMiddleware.swift
//
// Catches all errors thrown by route handlers or downstream middleware and
// renders a branded HTML error page for browser requests.  API and worker
// endpoints (/api/…, /worker/…) still receive a plain JSON error response so
// machine clients are not broken.
//
// Both typed errors (`WebAssignmentError`, etc.) and bare `Abort(...)` flow
// through here via the `AbortError` protocol.  When a bare `Abort` provides
// no `reason:`, the protocol default returns the HTTP reason phrase (e.g.,
// "Not Found"), which renders as a terse, unfriendly page.  `friendlyReason`
// below substitutes a more humane default in that case, so the user-facing
// output is consistent regardless of which error style the handler used.

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
                reason = friendlyReason(status: abort.status, reason: abort.reason)
            default:
                status = .internalServerError
                reason = friendlyReason(status: .internalServerError, reason: "")
                request.logger.report(error: error)
            }

            // Machine clients (API / runner) get a compact JSON error.
            let path = request.url.path
            if path.hasPrefix("/api/") || path.hasPrefix("/worker/") {
                let escaped =
                    reason
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                var headers = HTTPHeaders()
                headers.add(name: .contentType, value: "application/json; charset=utf-8")
                return Response(
                    status: status,
                    headers: headers,
                    body: .init(
                        string: #"{"error":true,"status":\#(status.code),"reason":"\#(escaped)"}"#
                    )
                )
            }

            // Browser routes get a Leaf-rendered error page.
            let ctx = ErrorPageContext(
                currentUser: request.currentUserContext,
                status: Int(status.code),
                title: status.reasonPhrase,
                message: reason
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

/// Returns a humane user-facing message for an HTTP error.  When the caller
/// supplied an explicit `reason:` (i.e., not the HTTP status reason phrase),
/// the reason is returned verbatim — typed errors like
/// `WebAssignmentError.forbidden(action:)` already produce friendly text and
/// we don't want to clobber them.  When the reason is empty or matches the
/// generic reason phrase (i.e., a bare `Abort(.notFound)` with no message),
/// substitute a status-appropriate friendly default.
func friendlyReason(status: HTTPStatus, reason: String) -> String {
    let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty && trimmed != status.reasonPhrase {
        return trimmed
    }
    switch status {
    case .badRequest:
        return "We couldn't understand that request."
    case .unauthorized:
        return "Please sign in to continue."
    case .forbidden:
        return "You don't have permission to view this page."
    case .notFound:
        return "We couldn't find that page."
    case .methodNotAllowed:
        return "That action isn't allowed here."
    case .conflict:
        return "That action conflicts with the current state of the resource."
    case .gone:
        return "That page is no longer available."
    case .payloadTooLarge:
        return "The upload was too large."
    case .unprocessableEntity:
        return "We couldn't process that request."
    case .tooManyRequests:
        return "Too many requests — please slow down and try again in a moment."
    case .internalServerError:
        return "Something went wrong on our end."
    case .badGateway, .serviceUnavailable, .gatewayTimeout:
        return "The service is temporarily unavailable — please try again shortly."
    default:
        return trimmed.isEmpty ? "Something went wrong." : trimmed
    }
}

// MARK: - View context

private struct ErrorPageContext: Encodable {
    let currentUser: CurrentUserContext?
    let status: Int
    let title: String
    let message: String
}
