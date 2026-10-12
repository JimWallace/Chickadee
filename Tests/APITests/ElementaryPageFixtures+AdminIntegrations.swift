// Tests/APITests/ElementaryPageFixtures+AdminIntegrations.swift
//
// The admin Integrations pages (LEARN, GitHub, LTI and MCP), for
// ElementaryPageGuardTests.

import Foundation

@testable import APIServer

extension ElementaryPageFixtures {
    static var adminIntegrationPages: [ElementaryPageFixture] {
        [adminBrightspacePage, adminGitHubPage, adminLTIPage, adminMCPPage]
    }

    static var adminBrightspacePage: ElementaryPageFixture {
        func render(configured: Bool, authorized: Bool, keySource: String, identity: String?) -> String {
            AdminBrightspacePage(
                page: page(currentUser: signedInAdmin),
                flash: FlashMessages(success: authorized ? "Connection works." : nil),
                configured: configured, authorized: authorized,
                baseURL: configured ? "https://learn.example.edu" : nil, identityName: identity,
                keySource: keySource, capturedAt: identity == nil ? nil : "Jan 1, 2026 9:00 AM"
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AdminBrightspacePage",
            archetype: .adminTabbed,
            renders: [
                render(configured: false, authorized: false, keySource: "none", identity: nil),
                render(configured: true, authorized: false, keySource: "none", identity: nil),
                render(configured: true, authorized: true, keySource: "env", identity: nil),
                render(configured: true, authorized: true, keySource: "authorized", identity: "Grade Bot"),
            ]
        )
    }

    static var adminGitHubPage: ElementaryPageFixture {
        let app = APIGitHubApp()
        app.name = "Chickadee Fixture"
        app.slug = "chickadee-fixture"
        app.appID = 42
        app.clientID = "Iv1.fixture"
        app.htmlURL = "https://github.com/apps/chickadee-fixture"
        app.ownerLogin = "uwaterloo-cs"
        let details = AdminGitHubAppDetails(app: app)
        let capabilities = [
            GitHubCapabilityRow(label: "Course repositories", granted: true),
            GitHubCapabilityRow(label: "Push events", granted: false),
        ]
        let creation = GitHubAppCreationContext(
            actionURL: "https://github.com/settings/apps/new?state=s", manifestJSON: #"{"name":"Chickadee"}"#,
            ownerLabel: "your GitHub account")
        func render(
            baseURL: Bool = true, app: AdminGitHubAppDetails? = nil, unavailable: Bool = false,
            capabilities: [GitHubCapabilityRow] = [], unknown: Bool = false,
            creation: GitHubAppCreationContext? = nil, open: Bool = false
        ) -> String {
            AdminGitHubPage(
                page: page(currentUser: signedInAdmin), baseURLConfigured: baseURL, app: app,
                secretsUnavailable: unavailable, secretsMissing: unavailable, secretsPath: "/data/github-app.json",
                capabilities: capabilities, capabilitiesIncomplete: capabilities.contains { !$0.granted },
                capabilitiesUnknown: unknown, creation: creation, organization: open ? "uwaterloo-cs" : "",
                organizationOpen: open, courseRepositories: open, pushEvents: false, commitStatuses: open
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AdminGitHubPage",
            archetype: .adminTabbed,
            renders: [
                render(baseURL: false),
                render(creation: creation),
                render(creation: creation, open: true),
                render(app: details, capabilities: capabilities),
                render(app: details, unknown: true),
                render(app: details, unavailable: true),
            ]
        )
    }

    static var adminLTIPage: ElementaryPageFixture {
        let form = LTIPlatformForm(
            displayName: "UW LEARN", issuer: "https://learn.example.edu", clientID: "client-1",
            deploymentIDs: "d1\nd2", authLoginURL: "https://learn.example.edu/auth",
            accessTokenURL: "https://learn.example.edu/token", jwksURL: "https://learn.example.edu/jwks",
            tokenAudience: nil, trustUsername: true)
        let platforms = [
            AdminLTIPlatformRow(
                id: "p1", displayName: "UW LEARN", issuer: form.issuer, clientID: form.clientID, deploymentCount: 2,
                enabled: true, editOpen: false, fields: LTIPlatformFields(idPrefix: "lti-p1", form: form)),
            AdminLTIPlatformRow(
                id: "p2", displayName: "Sandbox", issuer: "https://sandbox.example.edu", clientID: "client-2",
                deploymentCount: 1, enabled: false, editOpen: true,
                fields: LTIPlatformFields(idPrefix: "lti-p2", form: form, error: "That issuer is already registered.")),
        ]
        func render(baseURL: Bool, platforms: [AdminLTIPlatformRow], newError: String?) -> String {
            AdminLTIPage(
                page: page(currentUser: signedInAdmin), baseURLConfigured: baseURL,
                loginURL: baseURL ? "https://chickadee.example.edu/lti/login" : "/lti/login",
                launchURL: baseURL ? "https://chickadee.example.edu/lti/launch" : "/lti/launch",
                jwksURL: baseURL ? "https://chickadee.example.edu/lti/jwks" : "/lti/jwks", platforms: platforms,
                enabledPlatformCount: platforms.filter(\.enabled).count,
                newPlatformOpen: newError != nil || platforms.isEmpty,
                newFields: LTIPlatformFields(idPrefix: "lti-new", form: .empty, error: newError)
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AdminLTIPage",
            archetype: .adminTabbed,
            renders: [
                render(baseURL: false, platforms: [], newError: nil),
                render(baseURL: true, platforms: platforms, newError: "The issuer must be an https URL."),
            ]
        )
    }

    static var adminMCPPage: ElementaryPageFixture {
        let courses = [
            AdminCourseRef(id: "c1", code: "CS135", name: "Design", termLabel: "Fall 2026"),
            AdminCourseRef(id: "c2", code: "CS136", name: "Algorithms", termLabel: nil),
        ]
        let accounts = [
            AdminMCPAccountRow(
                id: "u1", username: "course-bot", createdAt: "2026-01-01T00:00:00Z",
                enrolledCourses: [courses[0]], coursesText: "CS135 Fall 2026", enrollableCourses: [courses[1]]),
            AdminMCPAccountRow(
                id: "u2", username: "idle-bot", createdAt: "2026-01-02T00:00:00Z", enrolledCourses: [],
                coursesText: "", enrollableCourses: courses),
        ]
        let grants = [
            AgentGrantRow(
                id: "g1", agentName: "Fixture Agent", scope: "content:read content:write", owner: "ada",
                createdAt: "2026-01-01T00:00:00Z", lastUsedAt: "2026-02-01T00:00:00Z",
                expiresAt: "2026-03-01T00:00:00Z", revoked: false),
            AgentGrantRow(
                id: "g2", agentName: "Old Agent", scope: "content:read", owner: "bob",
                createdAt: "2026-01-01T00:00:00Z", lastUsedAt: nil, expiresAt: "2026-03-01T00:00:00Z",
                revoked: true),
            AgentGrantRow(
                id: "g3", agentName: "Lapsed Agent", scope: "content:read", owner: "cy",
                createdAt: "2026-01-01T00:00:00Z", lastUsedAt: nil, expiresAt: "2026-01-02T00:00:00Z",
                revoked: false, isExpired: true),
        ]
        func render(enabled: Bool, write: Bool, local: Bool, rows: Bool, minted: Bool, error: String?) -> String {
            AdminMCPPage(
                page: page(currentUser: signedInAdmin), enabled: enabled, writeAllowed: write,
                issuer: enabled ? "https://chickadee.example.edu" : nil,
                resource: enabled ? "https://chickadee.example.edu/mcp" : nil, tokenTTLSeconds: 3600,
                showServiceAccounts: local, accounts: rows ? accounts : [], grants: rows ? grants : [],
                mintedToken: minted ? "fixture.token.value" : nil, mintedFor: minted ? "course-bot" : nil,
                mintedScopes: minted ? "content:read content:write" : nil, error: error,
                modeLabel: enabled ? (write ? "Read/write" : "Read-only") : "Inactive", tokenLifetimeText: "1 hour"
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AdminMCPPage",
            archetype: .adminTabbed,
            renders: [
                render(enabled: false, write: false, local: true, rows: false, minted: false, error: "mcp_disabled"),
                render(enabled: true, write: false, local: true, rows: true, minted: false, error: "username_taken"),
                render(enabled: true, write: true, local: true, rows: true, minted: true, error: nil),
                render(enabled: true, write: true, local: false, rows: true, minted: false, error: nil),
            ]
        )
    }
}
