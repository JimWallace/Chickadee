// Tests/APITests/Auth/ClientIPAddressForwardedForTests.swift
//
// The client address that keys the login and MCP OAuth rate limits, read
// from a forwarded-for header with more than one entry.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

/// `clientIPAddress` keys the login and MCP OAuth rate limits. nginx appends
/// the peer it saw after whatever the client sent, so only the last
/// `X-Forwarded-For` entry is trustworthy.
@Suite struct ClientIPAddressForwardedForTests {

    @Test(arguments: [
        ("203.0.113.9", "203.0.113.9"),
        ("198.51.100.1, 203.0.113.9", "203.0.113.9"),
        ("10.0.0.1,198.51.100.1 , 203.0.113.9", "203.0.113.9"),
    ])
    func keysOnTheLastForwardedEntry(header: String, expected: String) async throws {
        try await withTestApp { app in
            let request = makeTestRequest(on: app, headers: ["X-Forwarded-For": header])
            #expect(clientIPAddress(from: request, trustForwardedFor: true) == expected)
        }
    }
}
