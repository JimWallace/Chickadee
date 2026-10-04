// Tests/APITests/InstructorMCPPageTests.swift
//
// The MCP page's title-bar controls sit outside the guide form, so they
// name it with `form="mcp-guide"`. These tests pin that wiring: a control
// that loses the attribute would submit nothing and fail silently.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct InstructorMCPPageTests {

    private func page(on app: Application, customized: Bool) async throws -> String {
        let cookie = try await arLoginAsInstructor(on: app)
        if customized {
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let course = try #require(try await APICourse.find(courseID, on: app.db))
            course.mcpInstructions = "Terse and technical."
            try await course.save(on: app.db)
        }
        return try await getHTML("/instructor/mcp", cookie: cookie, on: app)
    }

    @Test func saveSitsOutsideTheFormAndNamesIt() async throws {
        try await withAssignmentRoutesApp { app in
            let html = try await page(on: app, customized: false)
            #expect(html.contains("<form method=\"post\" action=\"/instructor/mcp\" id=\"mcp-guide\""))
            #expect(html.contains("type=\"submit\" form=\"mcp-guide\">Save<"))
            #expect(html.contains("tier-closed\">Default<"))
            #expect(!html.contains("Reset to Chickadee default"))
            #expect(html.contains("tier-open\">Enabled<") || html.contains("tier-closed\">Disabled<"))
        }
    }

    @Test func resetMenuItemSubmitsTheResetActionFromOutsideTheForm() async throws {
        try await withAssignmentRoutesApp { app in
            let html = try await page(on: app, customized: true)
            #expect(html.contains("tier-open\">Customized<"))
            #expect(
                html.contains(
                    "form=\"mcp-guide\" name=\"action\" value=\"reset\" role=\"menuitem\">Reset to Chickadee default<"
                ))
        }
    }

    @Test func lengthIsShownAgainstTheLimit() async throws {
        try await withAssignmentRoutesApp { app in
            let html = try await page(on: app, customized: true)
            let limit = InstructorDashboardRoutes.mcpGuidanceMaxLength
            #expect(html.contains("\(String("Terse and technical.".count)) / \(limit)"))
        }
    }
}
