import Fluent
import Vapor

/// Guards static user-scoped notebook files under `/.../files/users/<uuid>/...`.
/// Students may only access their own namespace; instructors/admins may access any.
struct UserFileNamespaceMiddleware: AsyncMiddleware {
    private static let guardedPrefixes = [
        "/files/users/",
        "/jupyterlite/files/users/",
        "/jupyterlite/lab/files/users/",
        "/jupyterlite/notebooks/files/users/",
    ]

    func respond(to req: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let requestedUser = Self.requestedUserNamespace(from: req.url.path) else {
            return try await next.respond(to: req)
        }

        guard let caller = req.auth.get(APIUser.self) else {
            throw AppError.unauthenticated
        }
        // The user-file namespace is deployment-wide: staff (TA+ in a course
        // that is not archived) or admin may reach any user's folder; everyone
        // else only their own (#417 Slice G — was the global
        // `caller.isInstructor`). A past-term TA is a student here (#2663).
        if try await isStaffAnywhere(caller, includingArchived: false, db: req.db) {
            return try await next.respond(to: req)
        }
        guard let callerID = caller.id?.uuidString.lowercased(), callerID == requestedUser else {
            throw AppError.forbidden(action: "open another user's files")
        }

        return try await next.respond(to: req)
    }

    /// Matches on the path the way `FileMiddleware` resolves it, not on the
    /// raw URL: it percent-decodes the path and lets the filesystem collapse
    /// `//` and `.` segments, so `/jupyterlite//files/users/…`,
    /// `/jupyterlite/files/./users/…` and `/jupyterlite/files/%75sers/…` all
    /// reach the same file and must hit the same check. Lowercased because a
    /// case-insensitive filesystem (macOS default) also serves `/FILES/USERS/`.
    static func requestedUserNamespace(from rawPath: String) -> String? {
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        let segments = decoded.lowercased()
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
        let path = "/" + segments.joined(separator: "/")
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
