import Fluent
import Vapor

/// Guards static user-scoped notebook files under `/.../files/users/<uuid>/...`.
/// The policy is `mayReadUserFile`: the owner, an admin, or course staff in
/// the course of the setup the file sits in (#2895).
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
        guard
            try await mayReadUserFile(
                caller, owner: requestedUser, setupID: Self.requestedSetupID(from: req.url.path), db: req.db)
        else {
            throw AppError.forbidden(action: "open another user's files")
        }
        return try await next.respond(to: req)
    }

    /// The segments after a guarded prefix (`<owner>`, then the rest), or nil
    /// when the path is outside the namespace.
    ///
    /// Matches on the path the way `FileMiddleware` resolves it, not on the
    /// raw URL: it percent-decodes the path and lets the filesystem collapse
    /// `//` and `.` segments, so `/jupyterlite//files/users/…`,
    /// `/jupyterlite/files/./users/…` and `/jupyterlite/files/%75sers/…` all
    /// reach the same file and must hit the same check. The prefix is matched
    /// without case, because a case-insensitive filesystem (macOS default)
    /// also serves `/FILES/USERS/`. The returned segments keep their case: a
    /// setup ID is looked up as written, so a wrong-case one fails closed.
    private static func segmentsInNamespace(from rawPath: String) -> [Substring]? {
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        let segments = decoded.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        for prefix in guardedPrefixes {
            let prefixSegments = prefix.split(separator: "/")
            guard segments.count > prefixSegments.count,
                zip(segments, prefixSegments).allSatisfy({ $0.lowercased() == $1 })
            else { continue }
            return Array(segments.dropFirst(prefixSegments.count))
        }
        return nil
    }

    /// The owner segment, lowercased (user folders are lowercased UUIDs).
    static func requestedUserNamespace(from rawPath: String) -> String? {
        segmentsInNamespace(from: rawPath)?.first.map { $0.lowercased() }
    }

    /// The setup segment of `users/<owner>/<setupID>/<file>`, or nil when the
    /// path stops above a setup folder.
    static func requestedSetupID(from rawPath: String) -> String? {
        guard let rest = segmentsInNamespace(from: rawPath), rest.count >= 3 else { return nil }
        return String(rest[1])
    }
}
