// Tests/APITests/AdminCourseTermLabelTests.swift
//
// The admin user page and the admin MCP page list courses by code. Two
// offerings of one course share a code, so both lists show each course's term
// and sort newest term first, as every course list does (#1783).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct AdminCourseTermLabelTests {

    /// Three offerings of CS135. The fall one is the oldest.
    private func makeOfferings(on app: Application) async throws -> (fall: UUID, winter: UUID, spring: UUID) {
        func offering(_ season: TermSeason, _ year: Int) async throws -> UUID {
            let course = APICourse(
                code: "CS135", name: "Algorithm Design", term: AcademicTerm(year: year, season: season))
            try await course.save(on: app.db)
            return try course.requireID()
        }
        return (
            try await offering(.fall, 2025), try await offering(.winter, 2026), try await offering(.spring, 2026)
        )
    }

    @Test func theUserPageShowsEachOfferingsTermNewestFirst() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let cookie = try await loginUser(
                username: "term_admin", password: "testpassword", role: "admin", on: app)
            let offerings = try await makeOfferings(on: app)
            let subject = try await makeTestUser(on: app, username: "term_subject")
            _ = try await makeTestEnrollment(on: app, userID: subject.requireID(), courseID: offerings.fall)
            _ = try await makeTestEnrollment(on: app, userID: subject.requireID(), courseID: offerings.winter)

            let body = try await getHTML("/admin/users/\(try subject.requireID().uuidString)", cookie: cookie, on: app)
            let winter = try #require(body.range(of: "<strong>CS135</strong> Winter 2026"))
            let fall = try #require(body.range(of: "<strong>CS135</strong> Fall 2025"))
            #expect(winter.lowerBound < fall.lowerBound, "the newer term is listed first")
            #expect(body.contains(">CS135 Spring 2026 — Algorithm Design</option>"))
        }
    }

    @Test func theMCPPageShowsEachOfferingsTermNewestFirst() async throws {
        let app = try await makeTestApp(appConfig: .testDefaults(authMode: .local, mcp: .default))
        try await withApp(app) { app in
            let cookie = try await loginUser(
                username: "term_mcp_admin", password: "testpassword", role: "admin", on: app)
            let offerings = try await makeOfferings(on: app)
            let agent = try await makeTestUser(on: app, username: "term-bot", role: UserRole.mcp.rawValue)
            _ = try await makeTestEnrollment(on: app, userID: agent.requireID(), courseID: offerings.fall)
            _ = try await makeTestEnrollment(on: app, userID: agent.requireID(), courseID: offerings.winter)

            let body = try await getHTML("/admin/mcp", cookie: cookie, on: app)
            #expect(body.contains("CS135 Winter 2026 · CS135 Fall 2025</div>"))
            #expect(body.contains(">Remove from CS135 Winter 2026</button>"))
            #expect(body.contains(">Remove from CS135 Fall 2025</button>"))
            #expect(body.contains(">CS135 Spring 2026</option>"))
        }
    }
}
