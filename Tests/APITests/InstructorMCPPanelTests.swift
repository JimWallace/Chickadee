// Tests/APITests/InstructorMCPPanelTests.swift
//
// The instructor MCP tab (per-course authoring guidance for connected agents):
// staff-only visibility, TA read-only rendering, the instructor save/clear
// round-trip (with the length guard), and the TA save refusal.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct InstructorMCPPanelTests {

    /// Logs in a per-course TA in the shared TEST101 course: a plain user whose
    /// only staff standing is the `.ta` enrollment (upserted, since the `.auto`
    /// course auto-enrolls them as `.student` at login).
    private func loginAsTA(on app: Application) async throws -> String {
        let cookie = try await loginUser(
            username: "testta", password: "testpassword", role: "student", on: app)
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let user = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "testta").first())
        let userID = try user.requireID()
        if let existing = try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == userID).filter(\.$course.$id == courseID).first()
        {
            existing.role = .ta
            try await existing.save(on: app.db)
        } else {
            try await APICourseEnrollment(userID: userID, courseID: courseID, role: .ta)
                .save(on: app.db)
        }
        return cookie
    }

    private func activeCourse(on app: Application) async throws -> APICourse {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        return try #require(try await APICourse.find(courseID, on: app.db))
    }

    // MARK: - Access + rendering

    @Test func studentCannotAccessMCPTab() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            try await app.asyncTest(
                .GET, "/instructor/mcp",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(res.status == .forbidden) })
        }
    }

    @Test func instructorSeesEditablePanelWithHouseGuide() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await app.asyncTest(
                .GET, "/instructor/mcp",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Agent authoring guidance"))
                    #expect(html.contains("Save guidance"))
                    // The fixed house guide is shown for reference.
                    #expect(html.contains("House authoring-voice guide"))
                    #expect(html.contains("Authoring voice for Chickadee assignments"))
                })
        }
    }

    @Test func taSeesReadOnlyPanel() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await loginAsTA(on: app)
            try await app.asyncTest(
                .GET, "/instructor/mcp",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    // Leaf escapes the apostrophe in "course's", so match an
                    // apostrophe-free slice of the read-only note.
                    #expect(html.contains("instructors can edit its guidance"))
                    #expect(!html.contains("Save guidance"))
                })
        }
    }

    // MARK: - Save round-trip

    @Test func instructorSavesAndClearsGuidance() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(
                for: "/instructor/mcp", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/mcp",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["instructions": "  Use metric units throughout.  ", "_csrf": csrf],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor/mcp?saved=1")
                })
            var course = try await activeCourse(on: app)
            #expect(course.mcpInstructions == "Use metric units throughout.")

            // The saved text renders back into the panel's textarea.
            try await app.asyncTest(
                .GET, "/instructor/mcp",
                beforeRequest: { req in req.headers.add(name: .cookie, value: sessionCookie) },
                afterResponse: { res in
                    #expect(res.body.string.contains("Use metric units throughout."))
                })

            // A blank submit clears the guidance back to nil.
            try await app.asyncTest(
                .POST, "/instructor/mcp",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["instructions": "   ", "_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor/mcp?saved=1")
                })
            course = try await activeCourse(on: app)
            #expect(course.mcpInstructions == nil)
        }
    }

    @Test func oversizedGuidanceIsRejected() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(
                for: "/instructor/mcp", cookie: cookie, on: app)
            let oversized = String(
                repeating: "a", count: InstructorDashboardRoutes.mcpGuidanceMaxLength + 1)

            try await app.asyncTest(
                .POST, "/instructor/mcp",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["instructions": oversized, "_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor/mcp?error=length")
                })
            let course = try await activeCourse(on: app)
            #expect(course.mcpInstructions == nil)
        }
    }

    @Test func taCannotSaveGuidance() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await loginAsTA(on: app)
            let (csrf, sessionCookie) = try await csrfFields(
                for: "/instructor/mcp", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/mcp",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["instructions": "TA tone takeover", "_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .forbidden) })
            let course = try await activeCourse(on: app)
            #expect(course.mcpInstructions == nil)
        }
    }
}
