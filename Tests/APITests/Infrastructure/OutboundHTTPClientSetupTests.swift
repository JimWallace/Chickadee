import AsyncHTTPClient
import ChickadeeTestSupport
import Foundation
import NIOCore
import Testing
import Vapor

@testable import APIServer

/// Every outbound call from the server has a read timeout (#2765). The calls
/// go through Vapor's shared client, so the timeout is set once on that
/// client's configuration. These tests pin the values, and they fail when a
/// server source builds a second client that would not get the timeout.
@Suite struct OutboundHTTPClientSetupTests {

    @Test func applySetsConnectAndReadTimeoutWithoutProxy() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            OutboundHTTPClientSetup.apply(to: app, proxy: nil)
            let configuration = app.http.client.configuration
            #expect(configuration.timeout.read == OutboundHTTPClientSetup.readTimeout)
            #expect(configuration.timeout.connect == OutboundHTTPClientSetup.connectTimeout)
            #expect(configuration.proxy == nil)
        }
    }

    @Test func applySetsTimeoutAndProxyTogether() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            let proxy = try #require(OutboundProxyConfig.parse("http://proxy.example:3128"))
            OutboundHTTPClientSetup.apply(to: app, proxy: proxy)
            let configuration = app.http.client.configuration
            #expect(configuration.timeout.read == OutboundHTTPClientSetup.readTimeout)
            #expect(configuration.proxy == .server(host: "proxy.example", port: 3128))
        }
    }

    /// The limits are bounded and short enough that a stalled peer releases an
    /// SSO callback or a shutdown drain well before a container is killed.
    @Test func timeoutsAreBounded() {
        #expect(OutboundHTTPClientSetup.readTimeout > .zero)
        #expect(OutboundHTTPClientSetup.readTimeout <= .seconds(60))
        #expect(OutboundHTTPClientSetup.connectTimeout > .zero)
        #expect(OutboundHTTPClientSetup.connectTimeout <= .seconds(30))
    }

    /// A server source that builds its own AsyncHTTPClient, or uses the
    /// library singleton, does not get the shared timeout. Such a site must set
    /// its own read timeout and be named here. A source that replaces the
    /// shared configuration outside the setup type would drop the timeout.
    @Test func noServerSourceBypassesTheSharedTimeout() throws {
        let allowedOwnClients: Set<String> = ["SupportFileURLFetcher.swift"]
        let setupFile = "OutboundHTTPClientSetup.swift"
        let ownClientMarkers = ["HTTPClient(configuration", "HTTPClient(eventLoopGroup", "HTTPClient.shared"]
        let configurationMarker = "http.client.configuration"

        var offenders: [String] = []
        for file in try serverSourceFiles() {
            let name = file.lastPathComponent
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if ownClientMarkers.contains(where: code.contains) {
                if allowedOwnClients.contains(name) {
                    #expect(code.contains("read:"), "\(name) builds its own client without a read timeout")
                } else {
                    offenders.append("\(name): builds its own HTTP client")
                }
            }
            if name != setupFile, code.contains(configurationMarker) {
                offenders.append("\(name): changes the shared client configuration")
            }
        }
        #expect(offenders.isEmpty, "Outbound calls without the shared timeout: \(offenders)")
    }

    /// `configure` applies the setup. The test apps do not run `configure`,
    /// so this reads the call from its source.
    @Test func configureAppliesTheSetup() throws {
        let file = repositoryRoot.appendingPathComponent("Sources/APIServer/APIServerApp.swift")
        let code = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(code.contains("OutboundHTTPClientSetup.apply(to: app, proxy: appConfig.outboundProxy)"))
    }

    private func serverSourceFiles() throws -> [URL] {
        let files = try swiftFiles(under: repositoryRoot.appendingPathComponent("Sources/APIServer"))
        guard files.count > 100 else {
            throw IssueRecorded("found only \(files.count) server sources under Sources/APIServer")
        }
        return files
    }
}
