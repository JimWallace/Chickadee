// Verifies the dedicated least-privilege MCP database pool seam (P0-1 option 2):
// it is opt-in, so the default deployment (and the test suite) keeps the MCP
// path on the shared pool, and the postgres settings thread the MCP role
// credentials through when provided.

import Fluent
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPDatabasePoolTests {
    @Test func defaultsToSharedPool() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            // No MCP_DATABASE_USER/PASSWORD configured → no dedicated pool, so
            // ToolContext.db falls back to the shared default connection.
            #expect(app.usesDedicatedMCPDatabase == false)
        }
    }

    @Test func postgresSettingsThreadMCPRoleCredentials() {
        let withRole = DatabaseSettings.postgres(
            host: "h", port: 5432, database: "d", username: "u", password: "p",
            mcpUsername: "chickadee_mcp", mcpPassword: "secret")
        #expect(withRole.postgresMCPUsername == "chickadee_mcp")
        #expect(withRole.postgresMCPPassword == "secret")

        // The default factories carry no MCP role (opt-in only).
        #expect(
            DatabaseSettings.postgres(
                host: "h", port: 5432, database: "d", username: "u", password: "p"
            ).postgresMCPUsername == nil)
        #expect(DatabaseSettings.sqliteInMemory().postgresMCPUsername == nil)
    }
}
