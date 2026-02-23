import Vapor

/// Guards static user-scoped notebook files under `/.../files/users/<uuid>/...`.
/// Students may only access their own namespace; instructors/admins may access any.
struct UserFileNamespaceMiddleware: AsyncMiddleware {
    private static let guardedPrefixes = [
        "/files/users/",
        "/jupyterlite/files/users/",
        "/jupyterlite/lab/files/users/",
        "/jupyterlite/notebooks/files/users/"
    ]

    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let requestedUser = Self.requestedUserNamespace(from: req.url.path) else {
            return try await next.respond(to: req)
        }

        guard let caller = req.auth.get(APIUser.self) else {
            throw Abort(.unauthorized)
        }
        if caller.isInstructor {
            return try await next.respond(to: req)
        }
        guard let callerID = caller.id?.uuidString.lowercased(), callerID == requestedUser else {
            throw Abort(.forbidden)
        }

        return try await next.respond(to: req)
    }

    private static func requestedUserNamespace(from path: String) -> String? {
        for prefix in guardedPrefixes where path.hasPrefix(prefix) {
            let remainder = String(path.dropFirst(prefix.count))
            guard !remainder.isEmpty else { return nil }
            let namespace = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first
            let value = namespace.map(String.init)?.lowercased()
            if let value, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
