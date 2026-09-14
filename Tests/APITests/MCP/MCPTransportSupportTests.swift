// Tests/APITests/MCP/MCPTransportSupportTests.swift
//
// The transport mechanics both MCP endpoints now share. The endpoint suites
// prove each surface end to end; these pin the pieces that used to be two
// copies: the bearer challenge header and the SSE frame.

import Testing
import Vapor

@testable import APIServer

@Suite struct MCPTransportSupportTests {
    private let verification = MCPBearerVerification(
        expectedIssuer: "https://chickadee.example",
        expectedAudience: "https://chickadee.example/mcp",
        resourceMetadataURL: "https://chickadee.example/.well-known/oauth-protected-resource")

    @Test func bareChallengeCarriesOnlyTheResourceMetadata() {
        let response = verification.challenge(status: .unauthorized, error: nil, scope: nil)
        #expect(response.status == .unauthorized)
        #expect(
            response.headers.first(name: .wwwAuthenticate)
                == "Bearer resource_metadata=\"https://chickadee.example/.well-known/oauth-protected-resource\"")
    }

    @Test func insufficientScopeChallengeSortsAndJoinsScopes() {
        let response = verification.insufficientScope(["content:write", "content:read"])
        #expect(response.status == .forbidden)
        #expect(
            response.headers.first(name: .wwwAuthenticate)
                == "Bearer resource_metadata=\"https://chickadee.example/.well-known/oauth-protected-resource\", "
                + "error=\"insufficient_scope\", scope=\"content:read content:write\"")
    }

    @Test func sseFrameIsOneMessageEventTerminatedByABlankLine() throws {
        #expect(MCPTransport.sseMessageFrame(jsonString: "{}") == "event: message\ndata: {}\n\n")
        let encoded = try MCPTransport.sseMessageFrame(encoding: ["a": 1])
        #expect(encoded == "event: message\ndata: {\"a\":1}\n\n")
        let headers = MCPTransport.sseHeaders()
        #expect(headers.first(name: .contentType) == "text/event-stream")
        #expect(headers.first(name: "X-Accel-Buffering") == "no")
    }
}
