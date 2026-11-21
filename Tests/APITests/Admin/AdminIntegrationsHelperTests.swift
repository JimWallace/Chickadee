// Tests/APITests/Admin/AdminIntegrationsHelperTests.swift
//
// The helpers behind the admin Integrations pages: token lifetimes in
// words, and an agent grant's status label and revoke menu.

import Core
import Fluent
import Foundation
import JWT
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AdminIntegrationsHelperTests {
    @Test func tokenLifetimesReadInWords() {
        #expect(AdminRoutes.lifetimeText(seconds: 3600) == "1 hour")
        #expect(AdminRoutes.lifetimeText(seconds: 7200) == "2 hours")
        #expect(AdminRoutes.lifetimeText(seconds: 1800) == "30 minutes")
        #expect(AdminRoutes.lifetimeText(seconds: 60) == "1 minute")
        #expect(AdminRoutes.lifetimeText(seconds: 90) == "90 seconds")
    }

    @Test func aGrantIsActiveRevokedOrExpired() {
        func grant(revoked: Bool, expired: Bool) -> AgentGrantRow {
            AgentGrantRow(
                id: "1", agentName: "a", scope: "content:read", owner: "o", createdAt: "x",
                lastUsedAt: nil, expiresAt: "y", revoked: revoked, isExpired: expired)
        }
        #expect(grant(revoked: false, expired: false).statusLabel == "Active")
        #expect(grant(revoked: false, expired: false).canRevoke)
        #expect(grant(revoked: true, expired: false).statusLabel == "Revoked")
        #expect(grant(revoked: false, expired: true).statusLabel == "Expired")
        #expect(!grant(revoked: false, expired: true).canRevoke)
        #expect(!grant(revoked: true, expired: true).canRevoke)
    }
}
