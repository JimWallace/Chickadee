// APIServer/MCP/Admin/AdminToolContext.swift
//
// Execution context handed to an admin diagnostic tool's `execute`.  Parallel to
// `ToolContext` (the content surface) but with a fundamentally different
// authorization model: there is NO course scoping.  The admin surface is
// deployment-wide, so the only gate is "the token subject is an admin"
// (`requireAdminSubject`) — enforced at the OAuth consent + bearer layer and,
// for DB-touching tools, re-checked here as defense in depth.

import Fluent
import Vapor

struct AdminToolContext {
    let request: Request
    let subject: String
    let grantedScopes: Set<DiagnosticScope>
    /// The OAuth client (agent) acting on the subject's behalf; carried for
    /// audit attribution.  nil for non-browser callers / tests.
    let actingClientID: String?
    let actingClientName: String?

    init(
        request: Request,
        subject: String,
        grantedScopes: Set<DiagnosticScope>,
        actingClientID: String? = nil,
        actingClientName: String? = nil
    ) {
        self.request = request
        self.subject = subject
        self.grantedScopes = grantedScopes
        self.actingClientID = actingClientID
        self.actingClientName = actingClientName
    }

    /// The database admin diagnostic tools run on.  For now the shared default
    /// pool; the dedicated least-privilege admin role (SELECT on PII-free
    /// diagnostic views only) lands with the read-tool slice (docs/admin-mcp.md
    /// §4).
    var db: any Database { request.db }
    var logger: Logger { request.logger }

    /// Resolves the token subject and confirms it is an admin.  Students and
    /// instructors are refused even if they somehow obtained a token — the
    /// guarantee doesn't rest solely on token issuance.  DB-free liveness tools
    /// (e.g. get_deployment_info) deliberately skip this so they stay useful
    /// when the database is down; the bearer/OAuth layer is the primary admin
    /// gate.
    @discardableResult
    func requireAdminSubject(tool: String) async throws -> APIUser {
        guard
            let user = try await APIUser.query(on: db)
                .filter(\.$username == subject)
                .first()
        else {
            throw MCPToolError.notAuthorized(tool: tool, detail: "Unknown token subject.")
        }
        guard user.isAdmin else {
            throw MCPToolError.notAuthorized(
                tool: tool, detail: "The admin diagnostic interface requires an admin account.")
        }
        return user
    }
}
