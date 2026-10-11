// Tests/APITests/ElementaryPageFixtures+McpLti.swift
//
// The MCP agent consent page, for ElementaryPageGuardTests.

import Foundation

@testable import APIServer

extension ElementaryPageFixtures {
    static var mcpLtiPages: [ElementaryPageFixture] {
        [oauthConsentPage]
    }

    static var oauthConsentPage: ElementaryPageFixture {
        func render(notPermitted: Bool, firstTime: Bool, readsAnswers: Bool) -> String {
            OAuthConsentPage(
                page: page(currentUser: signedInAdmin), clientName: "Fixture Agent",
                scopeLabels: ["Read course content (assignments, etc.)", "Create and edit course content"],
                redirectHost: "agent.example.com", firstTimeApproval: firstTime, notPermitted: notPermitted,
                permittedRoleLabel: "instructors and admins", purposeLabel: "author course content",
                requestToken: notPermitted ? nil : "fixture-request", readsStudentAnswers: readsAnswers
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "OAuthConsentPage",
            archetype: .authBox,
            renders: [
                render(notPermitted: false, firstTime: true, readsAnswers: false),
                render(notPermitted: false, firstTime: false, readsAnswers: true),
                render(notPermitted: true, firstTime: false, readsAnswers: false),
            ]
        )
    }
}
