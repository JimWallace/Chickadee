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

    /// Resolves the token subject and confirms it may use the MCP interface at
    /// all: only instructors, admins, and `mcp` service accounts — never
    /// students. Students can't obtain a token today (consent requires
    /// instructor), but this enforces "students may not use MCP" at the tool
    /// layer too, so the guarantee doesn't rest solely on token issuance.
    @discardableResult
    func requireEligibleSubject(tool: String) async throws -> APIUser {
        guard
            let user = try await APIUser.query(on: db)
                .filter(\.$username == subject)
                .first()
        else {
            throw MCPToolError.notAuthorized(tool: tool, detail: "Unknown token subject.")
        }
        guard user.isInstructor || user.isMCPAgent else {
            throw MCPToolError.notAuthorized(
                tool: tool, detail: "Students may not use the MCP interface.")
        }
        return user
    }

    /// Authorizes the token subject for an action scoped to `courseID`.
    ///
    /// The subject must be MCP-eligible (`requireEligibleSubject`), then: admins
    /// act globally; every other subject (instructor browser-flow tokens and
    /// `mcp` service accounts alike) must be enrolled in the target course.
    /// Throws `MCPToolError.notAuthorized` otherwise, so a tool confines itself
    /// to the courses its account is enrolled in.
    func authorizeCourseAccess(_ courseID: UUID, tool: String) async throws {
        let user = try await requireEligibleSubject(tool: tool)
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
