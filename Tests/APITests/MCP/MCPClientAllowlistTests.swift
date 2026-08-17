// Unit tests for the operator-managed MCP client allowlist: origin
// normalization (the key both halves of the comparison go through), the
// allowlist file parser, the store's allow/deny decision, and the production
// refuse-to-mount fail-safe.
//
// The route-level enforcement at both /oauth/authorize verbs lives in
// MCPClientAllowlistAuthorizeTests.

import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPClientAllowlistOriginTests {
    @Test func keepsSchemeHostAndDropsPath() throws {
        // The path is dropped on purpose: a product varies its callback path
        // across versions and platforms while its origin stays put.
        #expect(MCPClientOrigin.normalized("https://claude.ai/api/mcp/callback") == "https://claude.ai")
        #expect(MCPClientOrigin.normalized("https://claude.ai") == "https://claude.ai")
        #expect(MCPClientOrigin.normalized("https://claude.ai/") == "https://claude.ai")
    }

    @Test func lowercasesSchemeAndHost() throws {
        // Both are case-insensitive per RFC 3986, and an operator will not write
        // them consistently.
        #expect(MCPClientOrigin.normalized("HTTPS://Claude.AI/Callback") == "https://claude.ai")
        #expect(MCPClientOrigin.normalized("HtTpS://EXAMPLE.org") == "https://example.org")
    }

    @Test func keepsNonDefaultPortAndDropsTheDefault() throws {
        #expect(MCPClientOrigin.normalized("https://example.org:8443/cb") == "https://example.org:8443")
        // https://example.org and https://example.org:443 are the same origin —
        // an operator writing either must match a client presenting either.
        #expect(MCPClientOrigin.normalized("https://example.org:443/cb") == "https://example.org")
        #expect(MCPClientOrigin.normalized("http://localhost:80/cb") == "http://localhost")
        #expect(MCPClientOrigin.normalized("http://localhost:3000/cb") == "http://localhost:3000")
    }

    @Test func permitsPlaintextHTTPOnlyForLoopback() throws {
        #expect(MCPClientOrigin.normalized("http://localhost:3000/cb") == "http://localhost:3000")
        #expect(MCPClientOrigin.normalized("http://127.0.0.1:3000/cb") == "http://127.0.0.1:3000")
        #expect(MCPClientOrigin.normalized("http://127.0.0.1/cb") == "http://127.0.0.1")
        // Plaintext to anywhere else is not a client identity worth trusting.
        #expect(MCPClientOrigin.normalized("http://example.org/cb") == nil)
    }

    @Test func rejectsMalformedInput() throws {
        // No scheme: a bare hostname is not an origin.
        #expect(MCPClientOrigin.normalized("claude.ai") == nil)
        #expect(MCPClientOrigin.normalized("") == nil)
        #expect(MCPClientOrigin.normalized("   ") == nil)
        // Schemes with no host cannot identify a client.
        #expect(MCPClientOrigin.normalized("mailto:someone@example.org") == nil)
        #expect(MCPClientOrigin.normalized("data:text/plain,hello") == nil)
        // A custom-scheme native callback is not an HTTPS origin.
        #expect(MCPClientOrigin.normalized("myapp://callback") == nil)
    }

    @Test func toleratesSurroundingWhitespace() throws {
        #expect(MCPClientOrigin.normalized("  https://claude.ai/cb  ") == "https://claude.ai")
    }
}

@Suite struct MCPClientAllowlistParsingTests {
    @Test func parsesOneOriginPerLine() throws {
        let parsed = parseMCPClientAllowlist(
            """
            https://claude.ai
            https://example.org:8443
            """)
        #expect(parsed.origins == ["https://claude.ai", "https://example.org:8443"])
        #expect(parsed.invalidEntries.isEmpty)
    }

    @Test func ignoresCommentsAndBlankLines() throws {
        let parsed = parseMCPClientAllowlist(
            """
            # Approved by the IRA-PIA submission
            https://claude.ai

               # indented comment
            \t
            """)
        #expect(parsed.origins == ["https://claude.ai"])
        #expect(parsed.invalidEntries.isEmpty)
    }

    @Test func normalizesAndDeduplicatesEntries() throws {
        // The same origin written three ways collapses to one entry.
        let parsed = parseMCPClientAllowlist(
            """
            https://claude.ai
            HTTPS://Claude.AI/callback
            https://claude.ai:443/other
            """)
        #expect(parsed.origins == ["https://claude.ai"])
    }

    @Test func reportsUnusableEntriesRatherThanDroppingThemSilently() throws {
        let parsed = parseMCPClientAllowlist(
            """
            https://claude.ai
            claude.ai
            http://example.org
            """)
        #expect(parsed.origins == ["https://claude.ai"])
        #expect(parsed.invalidEntries == ["claude.ai", "http://example.org"])
    }

    @Test func emptyTextIsAnEmptyAllowlist() throws {
        #expect(parseMCPClientAllowlist("").origins.isEmpty)
        #expect(parseMCPClientAllowlist("\n\n   \n").origins.isEmpty)
    }

    @Test func absentFileIsAnEmptyAllowlist() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-allowlist-\(UUID().uuidString)").path
        let read = readMCPClientAllowlistFromDisk(filePath: path)
        #expect(read.origins.isEmpty)
        #expect(read.invalidEntries.isEmpty)
    }

    @Test func readsAnActualFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("allowlist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try "# approved\nhttps://claude.ai\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(readMCPClientAllowlistFromDisk(filePath: url.path).origins == ["https://claude.ai"])
    }
}

@Suite struct MCPClientAllowlistStoreTests {
    @Test func emptyAllowlistPermitsAnyClient() async throws {
        // "Allow any" when empty is what keeps development and the existing test
        // corpus working; production fails closed at mount time instead.
        let store = MCPClientAllowlistStore()
        #expect(await store.permits(redirectURI: "https://anything.example/cb"))
        #expect(await store.permits(redirectURI: "myapp://callback"))
    }

    @Test func permitsAnAllowlistedOriginRegardlessOfPath() async throws {
        let store = MCPClientAllowlistStore(initialOrigins: ["https://claude.ai"])
        #expect(await store.permits(redirectURI: "https://claude.ai/api/mcp/callback"))
        #expect(await store.permits(redirectURI: "https://claude.ai/v2/other"))
        #expect(await store.permits(redirectURI: "HTTPS://CLAUDE.AI/cb"))
    }

    @Test func refusesAnOriginThatIsNotListed() async throws {
        let store = MCPClientAllowlistStore(initialOrigins: ["https://claude.ai"])
        #expect(await store.permits(redirectURI: "https://evil.example/cb") == false)
        // A subdomain is a different origin.
        #expect(await store.permits(redirectURI: "https://api.claude.ai/cb") == false)
        // So is the same host on another port.
        #expect(await store.permits(redirectURI: "https://claude.ai:8443/cb") == false)
    }

    @Test func refusesAnUnnormalizableRedirectWhenTheListIsInForce() async throws {
        // It could never equal an entry, which went through the same
        // normalization — deny rather than let it through by accident.
        let store = MCPClientAllowlistStore(initialOrigins: ["https://claude.ai"])
        #expect(await store.permits(redirectURI: "myapp://callback") == false)
        #expect(await store.permits(redirectURI: "http://claude.ai/cb") == false)
    }

    @Test func reflectsARuntimeEdit() async throws {
        let store = MCPClientAllowlistStore(initialOrigins: ["https://claude.ai"])
        #expect(await store.permits(redirectURI: "https://other.example/cb") == false)
        await store.setOrigins(["https://other.example"])
        #expect(await store.permits(redirectURI: "https://other.example/cb"))
        #expect(await store.permits(redirectURI: "https://claude.ai/cb") == false)
        #expect(await store.origins() == ["https://other.example"])
    }
}

@Suite struct MCPClientAllowlistRefusalTests {
    @Test func refusesInProductionWithAnEmptyAllowlist() throws {
        let reason = try #require(
            mcpClientAllowlistRefusal(environment: .production, allowedClientOrigins: []))
        #expect(reason.contains("Refusing to mount /mcp"))
        #expect(reason.contains(".mcp-client-allowlist"))
    }

    @Test func mountsInProductionOnceTheAllowlistIsStated() {
        #expect(
            mcpClientAllowlistRefusal(
                environment: .production, allowedClientOrigins: ["https://claude.ai"]) == nil)
    }

    @Test func neverRefusesOutsideProduction() {
        // An empty allowlist is the normal development and test default.
        for environment in [Environment.development, .testing] {
            #expect(mcpClientAllowlistRefusal(environment: environment, allowedClientOrigins: []) == nil)
        }
    }
}
