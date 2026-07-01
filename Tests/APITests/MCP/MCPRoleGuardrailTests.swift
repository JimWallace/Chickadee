// Guardrail tests for the `mcp` role: it must never be auto-assigned at first
// login (local registration or SSO), only by an admin. See APIUser
// autoAssignableRoles / sanitizedAutoAssignedRole and SSOAuthRoutes.

import Testing

@testable import APIServer

@Suite struct MCPRoleGuardrailTests {
    @Test func mcpIsNotAutoAssignable() {
        // Roles collapsed to user|admin (#417 Slice G2); the retired
        // student/instructor roles are no longer auto-assignable.
        #expect(APIUser.autoAssignableRoles == ["user", "admin"])
        #expect(APIUser.autoAssignableRoles.contains("mcp") == false)
    }

    @Test func sanitizeDropsMCPAndUnknownRoles() {
        #expect(APIUser.sanitizedAutoAssignedRole("mcp") == nil)
        #expect(APIUser.sanitizedAutoAssignedRole("superuser") == nil)
        #expect(APIUser.sanitizedAutoAssignedRole(nil) == nil)
        // The retired student/instructor roles are dropped (#417 Slice G2).
        #expect(APIUser.sanitizedAutoAssignedRole("student") == nil)
        #expect(APIUser.sanitizedAutoAssignedRole("instructor") == nil)
        #expect(APIUser.sanitizedAutoAssignedRole("user") == "user")
        #expect(APIUser.sanitizedAutoAssignedRole("admin") == "admin")
    }

    @Test func mcpRoleDoesNotImplyInstructorOrAdmin() {
        let agent = APIUser(username: "claude-agent", passwordHash: "x", role: "mcp")
        #expect(agent.isMCPAgent)
        #expect(agent.isInstructor == false)
        #expect(agent.isAdmin == false)
    }
}
