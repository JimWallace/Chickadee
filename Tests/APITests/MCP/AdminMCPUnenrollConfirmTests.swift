// Tests/APITests/MCP/AdminMCPUnenrollConfirmTests.swift
//
// Removing an MCP service account from a course asks first, as removing a
// person from a course does on every other page (UI audit #3007).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct AdminMCPUnenrollConfirmTests {

    @Test func removingAnAgentFromACourseAsksFirst() async throws {
        try await withTestApp(appConfig: .testDefaults(authMode: .local, mcp: .default)) { app in
            let cookie = try await loginUser(
                username: "confirm_mcp_admin", password: "testpassword", role: "admin", on: app)
            let course = APICourse(
                code: "CS136", name: "Elementary Algorithm Design",
                term: AcademicTerm(year: 2026, season: .winter))
            try await course.save(on: app.db)
            let agent = try await makeTestUser(on: app, username: "confirm-bot", role: UserRole.mcp.rawValue)
            _ = try await makeTestEnrollment(on: app, userID: agent.requireID(), courseID: course.requireID())

            let body = try await getHTML("/admin/mcp", cookie: cookie, on: app)
            #expect(body.contains("data-confirm=\"Remove confirm-bot from CS136 Winter 2026?\""))
        }
    }
}
