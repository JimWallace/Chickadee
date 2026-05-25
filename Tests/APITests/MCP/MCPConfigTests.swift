// Tests for MCPConfig defaults and its wiring into AppConfig.

import Testing

@testable import APIServer

@Suite struct MCPConfigTests {
    @Test func defaultIsOffWithSensibleValues() {
        let config = MCPConfig.default
        #expect(config.mode == .off)
        #expect(config.allowedHosts.isEmpty)
        #expect(config.allowedOrigins.isEmpty)
        #expect(config.tokenTTLSeconds == 86_400)
        #expect(config.issuer == nil)
        #expect(config.resource == nil)
    }

    @Test func appConfigTestDefaultsIncludeOffMCP() {
        #expect(AppConfig.testDefaults().mcp.mode == .off)
    }

    @Test(arguments: [
        ("off", MCPMode.off),
        ("read_only", .readOnly),
        ("readonly", .readOnly),
        ("read-only", .readOnly),
        ("read", .readOnly),
        ("read_write", .readWrite),
        ("readwrite", .readWrite),
        ("on", .readWrite),
        ("true", .readWrite),
        ("RW", .readWrite),
        ("  read_only  ", .readOnly),
        ("garbage", .off),
        ("", .off),
    ])
    func parsesEnvValues(_ raw: String, _ expected: MCPMode) {
        #expect(MCPMode.parse(raw) == expected)
    }

    @Test func parseNilIsOff() {
        #expect(MCPMode.parse(nil) == .off)
    }

    @Test func scopeCeilingMatchesMode() {
        #expect(MCPMode.off.scopeCeiling.isEmpty)
        #expect(MCPMode.readOnly.scopeCeiling == [.read])
        #expect(MCPMode.readWrite.scopeCeiling == [.read, .write])
        #expect(MCPMode.off.isMounted == false)
        #expect(MCPMode.readOnly.isMounted)
        #expect(MCPMode.readWrite.isMounted)
    }
}
