// APIServer/Middleware/UserSessionAuthenticator.swift
//
// Resolves the session cookie back to an `APIUser` on every request.

import Fluent
import Vapor

/// Resolves a session ID back to a User on every authenticated request.
struct UserSessionAuthenticator: AsyncSessionAuthenticator {
    typealias User = APIUser

    func authenticate(sessionID: String, for request: Request) async throws {
        guard let uuid = UUID(uuidString: sessionID),
            let user = try await APIUser.find(uuid, on: request.db)
        else { return }  // Not found → stay unauthenticated; middleware handles it.
        request.auth.login(user)
    }
}
