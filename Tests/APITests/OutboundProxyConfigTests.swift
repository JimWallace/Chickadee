import Testing

@testable import APIServer

@Suite(.serialized) struct OutboundProxyConfigTests {

    // MARK: - parse

    @Test func parsesSchemeHostPort() {
        let proxy = OutboundProxyConfig.parse("http://172.16.136.36:3128")
        #expect(proxy?.host == "172.16.136.36")
        #expect(proxy?.port == 3128)
    }

    @Test func parsesHostPortWithoutScheme() {
        let proxy = OutboundProxyConfig.parse("172.16.136.36:3128")
        #expect(proxy?.host == "172.16.136.36")
        #expect(proxy?.port == 3128)
    }

    @Test func toleratesTrailingSlashAndWhitespace() {
        #expect(OutboundProxyConfig.parse("  http://proxy.example:8080/  ")?.port == 8080)
        #expect(OutboundProxyConfig.parse("  http://proxy.example:8080/  ")?.host == "proxy.example")
    }

    @Test func rejectsMissingPort() {
        #expect(OutboundProxyConfig.parse("http://proxy.example") == nil)
    }

    @Test func rejectsEmpty() {
        #expect(OutboundProxyConfig.parse("") == nil)
        #expect(OutboundProxyConfig.parse("   ") == nil)
    }

    // MARK: - default behaviour (env)

    /// The whole point of the safety contract: with `OUTBOUND_HTTP_PROXY` unset
    /// (i.e. prod), there is no proxy config — `applyOutboundProxy` then no-ops
    /// and the HTTP client keeps Vapor's default direct egress.
    @Test func unsetEnvMeansNoProxy() async throws {
        try await withTestEnvironment(["OUTBOUND_HTTP_PROXY": nil]) {
            #expect(OutboundProxyConfig.fromEnvironment() == nil)
        }
    }

    @Test func setEnvIsParsedFromEnvironment() async throws {
        try await withTestEnvironment(["OUTBOUND_HTTP_PROXY": "http://172.16.136.36:3128"]) {
            let proxy = OutboundProxyConfig.fromEnvironment()
            #expect(proxy?.host == "172.16.136.36")
            #expect(proxy?.port == 3128)
        }
    }
}
