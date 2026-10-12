// Tests/APITests/ElementaryPageFixtures+McpLti.swift
//
// The MCP agent pages (consent, connected agents) and the LTI pages (course
// binding, the deep-linking picker and its return), for
// ElementaryPageGuardTests.

import Foundation

@testable import APIServer

extension ElementaryPageFixtures {
    static var mcpLtiPages: [ElementaryPageFixture] {
        [
            oauthConsentPage, connectedAgentsPage, ltiBindPage, ltiDeepLinkPage, ltiDeepLinkBindPage,
            ltiDeepLinkReturnPage,
        ]
    }

    private static var ltiCourses: [LTIBindCourseOption] {
        [
            LTIBindCourseOption(id: "c1", code: "CS135", name: "Design", termLabel: "Fall 2026"),
            LTIBindCourseOption(id: "c2", code: "CS136", name: "Algorithms", termLabel: nil),
        ]
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

    static var connectedAgentsPage: ElementaryPageFixture {
        let rows = [
            AgentGrantRow(
                id: "g1", agentName: "Fixture Agent", scope: "content:read content:write", owner: "ada",
                createdAt: "2026-01-01T00:00:00Z", lastUsedAt: "2026-02-01T00:00:00Z",
                expiresAt: "2026-03-01T00:00:00Z", revoked: false),
            AgentGrantRow(
                id: "g2", agentName: "Old Agent", scope: "content:read", owner: "bob",
                createdAt: "2026-01-01T00:00:00Z", lastUsedAt: nil, expiresAt: "2026-03-01T00:00:00Z",
                revoked: true),
        ]
        return ElementaryPageFixture(
            typeName: "ConnectedAgentsPage",
            archetype: .plainStudentPage,
            renders: [
                ConnectedAgentsPage(page: page(currentUser: signedInAdmin), isAdmin: false, rows: []).render(),
                ConnectedAgentsPage(page: page(currentUser: signedInAdmin), isAdmin: true, rows: rows).render(),
            ]
        )
    }

    static var ltiBindPage: ElementaryPageFixture {
        ElementaryPageFixture(
            typeName: "LTIBindPage",
            archetype: .plainStudentPage,
            renders: [
                LTIBindPage(page: page(currentUser: signedInAdmin), contextTitle: "LMS course", courses: [])
                    .render(),
                LTIBindPage(page: page(currentUser: signedInAdmin), contextTitle: "LMS course", courses: ltiCourses)
                    .render(),
            ]
        )
    }

    static var ltiDeepLinkPage: ElementaryPageFixture {
        let options = [
            LTIDeepLinkOption(publicID: "ABC123", title: "Lab 1"),
            LTIDeepLinkOption(publicID: "DEF456", title: "Lab 2"),
        ]
        func render(_ assignments: [LTIDeepLinkOption], multiple: Bool, error: String?) -> String {
            LTIDeepLinkPage(
                page: page(), ticket: "fixture-ticket", courseCode: "CS135", acceptMultiple: multiple,
                assignments: assignments, error: error
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "LTIDeepLinkPage",
            archetype: .plainStudentPage,
            renders: [
                render([], multiple: true, error: nil),
                render(options, multiple: true, error: nil),
                render(options, multiple: false, error: "Choose at least one assignment."),
            ]
        )
    }

    static var ltiDeepLinkBindPage: ElementaryPageFixture {
        ElementaryPageFixture(
            typeName: "LTIDeepLinkBindPage",
            archetype: .plainStudentPage,
            renders: [
                LTIDeepLinkBindPage(
                    page: page(), token: "fixture-token", contextTitle: "LMS course", courses: [], error: nil
                ).render(),
                LTIDeepLinkBindPage(
                    page: page(), token: "fixture-token", contextTitle: "LMS course", courses: ltiCourses,
                    error: "Choose a course you teach that is not linked yet."
                ).render(),
            ]
        )
    }

    static var ltiDeepLinkReturnPage: ElementaryPageFixture {
        ElementaryPageFixture(
            typeName: "LTIDeepLinkReturnPage",
            archetype: .plainStudentPage,
            renders: [
                LTIDeepLinkReturnPage(page: page(), returnURL: "https://lms.example.edu/return", jwt: "a.b.c")
                    .render()
            ]
        )
    }
}
