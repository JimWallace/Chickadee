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

    /// The database the MCP tool surface runs on. When a dedicated
    /// least-privilege pool is configured (`MCP_DATABASE_USER`/`PASSWORD`), every
    /// MCP query goes through it (`DatabaseID.mcp`) so the student-data wall is
    /// enforced by the DB role, not only the in-process boundary. Otherwise it
    /// falls back to the shared default pool.
    var db: any Database {
        request.application.usesDedicatedMCPDatabase ? request.db(.mcp) : request.db
    }

    /// The privileged (owner) database pool — always the shared default pool,
    /// never the least-privilege `.mcp` pool. Use this for acting-user
    /// bookkeeping that is a *side effect* of an MCP call but is NOT
    /// agent-facing content access — e.g. ensuring the acting account's own
    /// per-assignment personalization seed (`assignment_personalization_seeds`,
    /// a table the `chickadee_mcp` role is deliberately denied). This mirrors
    /// the content-edit re-grade in `ContentEditClose.swift`, which likewise
    /// runs its student-row regrade on `request.db`. All *content* reads and
    /// writes stay on `db` (the `.mcp` pool when configured) so the
    /// student-data wall holds. With no dedicated MCP pool configured this is
    /// the same connection as `db`, so behaviour is unchanged.
    var mainDB: any Database { request.db }

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
        // MCP eligibility is coarse: course staff (TA+ in any course) or an
        // `mcp` service account — never a plain student. Per-course access is
        // enforced separately (and per-course) by `authorizeCourseAccess`, so
        // this gate never widens what a caller can actually touch.
        //
        // Post-collapse (#417 Slice G2) staff is `isStaffAnywhere`. The
        // `user.isInstructor` term is a transition-only shim: after the
        // CollapseUserRoles migration no human holds the global instructor role,
        // so in production this reduces to `isStaffAnywhere`; it stays only so the
        // test corpus that still writes `role: "instructor"` (without a per-course
        // staff enrollment) keeps resolving as staff. Removable once those tests
        // are migrated.
        let eligible =
            user.isMCPAgent || user.isInstructor
            || (try await isStaffAnywhere(user, db: db))
        guard eligible else {
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

    /// Authorizes a *write* to `courseID`: the acting subject must pass
    /// `authorizeCourseAccess` (MCP-eligible + enrolled, admin included) AND the
    /// course must not be archived (admins exempt). The MCP analogue of the web
    /// `requireCourseWriteAccess` — archived courses are read-only for
    /// instructors and TAs, so a content-mutating tool can't drive a write into
    /// one. The single chokepoint every MCP write resolver funnels through; the
    /// *read* resolvers stay on `authorizeCourseAccess` so archived courses
    /// remain readable (#417 Slice D-MCP).
    func authorizeCourseWriteAccess(_ courseID: UUID, tool: String) async throws {
        try await authorizeCourseAccess(courseID, tool: tool)
        let user = try await requireEligibleSubject(tool: tool)
        guard !user.isAdmin else { return }
        guard let course = try await APICourse.find(courseID, on: db) else {
            throw MCPToolError.invalidArguments(
                tool: tool, detail: "The target course could not be found.")
        }
        guard !course.isArchived else {
            throw MCPToolError.notAuthorized(
                tool: tool, detail: "This course is archived and is read-only.")
        }
    }

    /// Like `authorizedAssignment`, but authorizes a *write* to the assignment's
    /// own course (`authorizeCourseWriteAccess`: per-course access + archived
    /// block, admin-exempt). Archived courses are already hidden from the MCP
    /// listing/resource surface, so this closes the by-public-ID write path an
    /// agent could still reach with a remembered id (#417 Slice C/D-MCP).
    func authorizedAssignmentForWrite(publicID: String, tool: String) async throws -> APIAssignment {
        let assignment = try await requireAssignment(publicID: publicID, tool: tool)
        try await authorizeCourseWriteAccess(assignment.courseID, tool: tool)
        return assignment
    }

    /// Resolves and authorizes the assignment, then loads its test setup,
    /// throwing the standard `invalidArguments` error if the setup is missing.
    /// READ entry point — the archived block is NOT applied, so the read tools
    /// (`get_suite`, `get_notebook`, `get_achievements`, `get_global_inputs`,
    /// `get_support_files`, `preview_personalization`) that route through it keep
    /// working on archived courses. Mutating tools use
    /// `authorizedAssignmentAndSetupForWrite`.
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

    /// Write variant of `authorizedAssignmentAndSetup`: authorizes a write to the
    /// assignment's own course (archived block) before loading the setup. Every
    /// content-mutating suite/manifest/notebook tool resolves through this so an
    /// agent can't edit an archived course's content by id (#417 Slice D-MCP).
    func authorizedAssignmentAndSetupForWrite(
        publicID: String, tool: String
    ) async throws
        -> (assignment: APIAssignment, setup: APITestSetup)
    {
        let assignment = try await authorizedAssignmentForWrite(publicID: publicID, tool: tool)
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: db) else {
            throw MCPToolError.invalidArguments(
                tool: tool, detail: "The assignment's test setup could not be found.")
        }
        return (assignment, setup)
    }
}
