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
    /// The subject must be MCP-eligible (`requireEligibleSubject`) and enrolled
    /// in the target course — admins included. An agent token never reaches
    /// further than the courses its human is enrolled in (the dashboard tab
    /// strip): enrolling widens an agent's reach, and unenrolling revokes it on
    /// the next call, since the enrollment row is re-checked per request.
    /// Throws `MCPToolError.notAuthorized` otherwise.
    func authorizeCourseAccess(_ courseID: UUID, tool: String) async throws {
        let user = try await requireEligibleSubject(tool: tool)
        guard let userID = user.id else {
            throw MCPToolError.notAuthorized(tool: tool, detail: "Token subject is not a valid user.")
        }
        guard try await userIsEnrolled(userID: userID, inCourse: courseID, db: db) else {
            throw MCPToolError.notAuthorized(
                tool: tool,
                detail: "The MCP account is not enrolled in the target course.")
        }
    }

    // MARK: - Assignment resolution

    /// Resolves the assignment referenced by a tool's `assignmentPublicID`,
    /// throwing the standard `invalidArguments` error if none matches. Does
    /// not check authorization — prefer `authorizedAssignment` unless the
    /// caller authorizes by other means.
    func requireAssignment(publicID: String, tool: String) async throws -> APIAssignment {
        guard let assignment = try await assignmentByPublicID(publicID, on: db) else {
            throw MCPToolError.invalidArguments(
                tool: tool, detail: "No assignment found with public ID \"\(publicID)\".")
        }
        return assignment
    }

    /// Resolves the assignment and authorizes the acting subject for its course
    /// (`authorizeCourseAccess`). The standard entry point for a tool acting on
    /// a single assignment.
    func authorizedAssignment(publicID: String, tool: String) async throws -> APIAssignment {
        let assignment = try await requireAssignment(publicID: publicID, tool: tool)
        try await authorizeCourseAccess(assignment.courseID, tool: tool)
        return assignment
    }

    /// Resolves and authorizes the assignment, then loads its test setup,
    /// throwing the standard `invalidArguments` error if the setup is missing.
    func authorizedAssignmentAndSetup(
        publicID: String, tool: String
    ) async throws
        -> (assignment: APIAssignment, setup: APITestSetup)
    {
        let assignment = try await authorizedAssignment(publicID: publicID, tool: tool)
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: db) else {
            throw MCPToolError.invalidArguments(
                tool: tool, detail: "The assignment's test setup could not be found.")
        }
        return (assignment, setup)
    }
}
