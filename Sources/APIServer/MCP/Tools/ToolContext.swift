// APIServer/MCP/Tools/ToolContext.swift
//
// Execution context handed to a tool's `execute`.  Wraps the Vapor request so
// tools reach Fluent and the existing service layer through the running app,
// and carries the authenticated subject + granted scopes (populated by the
// bearer middleware in PR B; ungated PR-A callers receive the full content
// scope set).

import Fluent
import Vapor

struct ToolContext {
    let request: Request
    let subject: String
    let grantedScopes: Set<ContentScope>
    /// The OAuth client (agent) acting on the subject's behalf (browser flow);
    /// nil for Phase-1 service tokens.  Carried for audit attribution.
    let actingClientID: String?
    let actingClientName: String?

    init(
        request: Request,
        subject: String,
        grantedScopes: Set<ContentScope>,
        actingClientID: String? = nil,
        actingClientName: String? = nil
    ) {
        self.request = request
        self.subject = subject
        self.grantedScopes = grantedScopes
        self.actingClientID = actingClientID
        self.actingClientName = actingClientName
    }

    var db: any Database { request.db }
    var logger: Logger { request.logger }

    /// Authorizes the token subject for an action scoped to `courseID`.
    ///
    /// Admins act globally; every other subject (instructor browser-flow tokens
    /// and `mcp` service accounts alike) must be enrolled in the target course.
    /// Throws `MCPToolError.notAuthorized` otherwise, so a tool confines itself
    /// to the courses its account is enrolled in. Resolving the subject by
    /// username keeps the bearer middleware DB-free.
    func authorizeCourseAccess(_ courseID: UUID, tool: String) async throws {
        guard
            let user = try await APIUser.query(on: db)
                .filter(\.$username == subject)
                .first()
        else {
            throw MCPToolError.notAuthorized(tool: tool, detail: "Unknown token subject.")
        }
        if user.isAdmin { return }
        guard let userID = user.id else {
            throw MCPToolError.notAuthorized(tool: tool, detail: "Token subject is not a valid user.")
        }
        let enrolled =
            try await APICourseEnrollment.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .count() > 0
        guard enrolled else {
            throw MCPToolError.notAuthorized(
                tool: tool,
                detail: "The MCP account is not enrolled in the target course.")
        }
    }
}
