// Tests for MCPConfig defaults and its wiring into AppConfig.

import Testing

@testable import APIServer

@Suite struct MCPConfigTests {
    @Test func defaultIsDisabledWithSensibleValues() {
        let config = MCPConfig.default
        #expect(config.enabled == false)
        #expect(config.allowedHosts.isEmpty)
        #expect(config.allowedOrigins.isEmpty)
        #expect(config.tokenTTLSeconds == 86_400)
        #expect(config.issuer == nil)
        #expect(config.resource == nil)
    }

    @Test func appConfigTestDefaultsIncludeDisabledMCP() {
        #expect(AppConfig.testDefaults().mcp.enabled == false)
    }
}
