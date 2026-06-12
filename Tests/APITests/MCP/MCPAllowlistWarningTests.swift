// Tests for the startup warning emitted when the MCP transport is mounted in
// production with its Host/Origin DNS-rebinding allowlists unset (an empty
// allowlist disables the corresponding check entirely).

import Testing
import Vapor

@testable import APIServer

@Suite struct MCPAllowlistWarningTests {
    @Test func warnsInProductionWhenBothUnset() throws {
        let warning = try #require(
            mcpAllowlistWarning(environment: .production, allowedHosts: [], allowedOrigins: []))
        #expect(warning.contains("MCP_ALLOWED_HOSTS"))
        #expect(warning.contains("MCP_ALLOWED_ORIGINS"))
        #expect(warning.contains("DNS-rebinding"))
    }

    @Test func warnsInProductionNamingOnlyTheUnsetGuard() throws {
        let warning = try #require(
            mcpAllowlistWarning(
                environment: .production,
                allowedHosts: ["chickadee.example.com"],
                allowedOrigins: []))
        #expect(!warning.contains("MCP_ALLOWED_HOSTS"))
        #expect(warning.contains("MCP_ALLOWED_ORIGINS"))
    }

    @Test func silentInProductionWhenBothConfigured() {
        #expect(
            mcpAllowlistWarning(
                environment: .production,
                allowedHosts: ["chickadee.example.com"],
                allowedOrigins: ["https://claude.ai"]) == nil)
    }

    @Test func silentOutsideProduction() {
        // Empty allowlists are the expected development/testing default; the
        // warning would be pure noise there.
        for environment in [Environment.development, .testing] {
            #expect(
                mcpAllowlistWarning(environment: environment, allowedHosts: [], allowedOrigins: [])
                    == nil)
        }
    }
}
