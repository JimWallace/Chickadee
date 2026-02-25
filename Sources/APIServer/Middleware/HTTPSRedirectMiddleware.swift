import Vapor

/// Enforces HTTPS at the application layer when enabled.
///
/// In production, this is commonly used behind a reverse proxy / load balancer
/// that terminates TLS and forwards `X-Forwarded-Proto: https`.
struct HTTPSRedirectMiddleware: AsyncMiddleware {
    let configuration: AppSecurityConfiguration

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard configuration.enforceHTTPS else {
            return try await next.respond(to: request)
        }
        guard !request.isHTTPSRequest(trustForwardedProto: configuration.trustForwardedProto) else {
            return try await next.respond(to: request)
        }

        // Safe redirect for idempotent requests. Non-idempotent requests should be retried over HTTPS.
        if request.method == .GET || request.method == .HEAD {
            return request.redirect(
                to: redirectURL(for: request, configuration: configuration),
                redirectType: .temporary
            )
        }

        throw Abort(.upgradeRequired, reason: "HTTPS is required for this endpoint.")
    }
}

private extension Request {
    func isHTTPSRequest(trustForwardedProto: Bool) -> Bool {
        if trustForwardedProto,
           let forwarded = firstForwardedValue(for: .init("X-Forwarded-Proto"))?.lowercased(),
           !forwarded.isEmpty {
            return forwarded == "https"
        }

        if let scheme = url.scheme?.lowercased() {
            return scheme == "https"
        }
        return false
    }

    func firstForwardedValue(for name: HTTPHeaders.Name) -> String? {
        guard let raw = headers.first(name: name) else { return nil }
        let first = raw.split(separator: ",").first.map(String.init) ?? raw
        let cleaned = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

private func redirectURL(for request: Request, configuration: AppSecurityConfiguration) -> String {
    let path = request.url.path
    let query = request.url.query

    if let baseURL = configuration.publicBaseURL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = "https"
        components.path = path
        components.percentEncodedQuery = query
        return components.string ?? "https://\(fallbackHost(for: request))\(path)"
    }

    var url = "https://\(fallbackHost(for: request))\(path)"
    if let query, !query.isEmpty {
        url += "?\(query)"
    }
    return url
}

private func fallbackHost(for request: Request) -> String {
    if let forwardedHost = request.headers.first(name: .init("X-Forwarded-Host"))?
        .split(separator: ",")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !forwardedHost.isEmpty {
        return forwardedHost
    }
    if let host = request.headers.first(name: .host)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !host.isEmpty {
        return host
    }
    return "localhost"
}
