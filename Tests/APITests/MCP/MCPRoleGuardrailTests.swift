// Guardrail tests for the `mcp` role: it must never be auto-assigned at first
// login (local registration or SSO), only by an admin. See APIUser
// autoAssignableRoles / sanitizedAutoAssignedRole and SSOAuthRoutes.

import Testing

@testable import APIServer

@Suite struct MCPRoleGuardrailTests {
    @Test func mcpIsNotAutoAssignable() {
        #expect(APIUser.autoAssignableRoles == ["student", "instructor", "admin"])
        #expect(APIUser.autoAssignableRoles.contains("mcp") == false)
    }

    @Test func sanitizeDropsMCPAndUnknownRoles() {
        #expect(APIUser.sanitizedAutoAssignedRole("mcp") == nil)
        #expect(APIUser.sanitizedAutoAssignedRole("superuser") == nil)
        #expect(APIUser.sanitizedAutoAssignedRole(nil) == nil)
        #expect(APIUser.sanitizedAutoAssignedRole("student") == "student")
        #expect(APIUser.sanitizedAutoAssignedRole("instructor") == "instructor")
        #expect(APIUser.sanitizedAutoAssignedRole("admin") == "admin")
    }

    @Test func mcpRoleDoesNotImplyInstructorOrAdmin() {
        let agent = APIUser(username: "claude-agent", passwordHash: "x", role: "mcp")
        #expect(agent.isMCPAgent)
        #expect(agent.isInstructor == false)
        #expect(agent.isAdmin == false)
    }
}
