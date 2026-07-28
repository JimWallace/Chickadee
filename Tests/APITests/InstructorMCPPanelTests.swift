// Tests/APITests/InstructorMCPPanelTests.swift
//
// The instructor MCP tab (the course's authoring voice for connected agents):
// staff-only visibility, the default seeded into the editor, TA read-only
// rendering, the instructor save / reset round-trip (with the length guard and
// the unedited-default shortcut), and the TA save refusal.

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

    @Test func instructorSeesEditorSeededWithTheDefault() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await app.asyncTest(
                .GET, "/instructor/mcp",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Authoring voice"))
                    #expect(html.contains(">Save<"))
                    // An uncustomized course starts on the Chickadee default,
                    // seeded into the one editable box.
                    #expect(html.contains("Authoring voice for Chickadee assignments"))
                    #expect(html.contains("uses the Chickadee default"))
                    // Nothing to reset while the course is still inheriting.
                    #expect(!html.contains("Reset to Chickadee default"))
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
                    #expect(html.contains("instructors can edit its authoring voice"))
                    // No save/reset controls at all for a TA; the box renders
                    // with the disabled attribute.
                    #expect(!html.contains(">Save<"))
                    #expect(!html.contains("Reset to Chickadee default"))
                    #expect(html.contains(" disabled>"))
                })
        }
    }

    // MARK: - Save round-trip

    @Test func instructorCustomizesThenResetsTheVoice() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(
                for: "/instructor/mcp", cookie: cookie, on: app)
            // An edited copy of the default: the realistic shape of the edit,
            // and it exercises the CRLF normalization browsers submit with.
            let edited = MCPServerInstructions.authoringVoice + "\n\nUse metric units throughout."
            let asBrowserSubmits = edited.replacingOccurrences(of: "\n", with: "\r\n")

            try await app.asyncTest(
                .POST, "/instructor/mcp",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["instructions": asBrowserSubmits, "_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor/mcp?saved=1")
                })
            var course = try await activeCourse(on: app)
            // Stored with \n line endings, and now the course's own voice.
            #expect(course.mcpInstructions == edited)
            #expect(courseHasCustomAuthoringVoice(course))

            // The saved text renders back into the box, now offering a reset.
            try await app.asyncTest(
                .GET, "/instructor/mcp",
                beforeRequest: { req in req.headers.add(name: .cookie, value: sessionCookie) },
                afterResponse: { res in
                    let html = res.body.string
                    #expect(html.contains("Use metric units throughout."))
                    #expect(html.contains("uses its own authoring voice"))
                    #expect(html.contains("Reset to Chickadee default"))
                })

            // Reset drops back to inheriting the default.
            try await app.asyncTest(
                .POST, "/instructor/mcp",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        ["instructions": asBrowserSubmits, "action": "reset", "_csrf": csrf],
                        as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/instructor/mcp?saved=reset")
                })
            course = try await activeCourse(on: app)
            #expect(course.mcpInstructions == nil)
            #expect(courseAuthoringVoice(course) == MCPServerInstructions.authoringVoice)
        }
    }

    @Test func savingTheUneditedDefaultKeepsTheCourseInheriting() async throws {
        // Opening the panel and pressing Save without editing must not freeze a
        // verbatim copy of the default onto the course — it stays on the
        // default so later changes to the house guide still flow through.
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(
                for: "/instructor/mcp", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/mcp",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(
                        [
                            "instructions": MCPServerInstructions.authoringVoice
                                .replacingOccurrences(of: "\n", with: "\r\n"),
                            "_csrf": csrf,
                        ], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.headers.first(name: .location) == "/instructor/mcp?saved=reset")
                })
            let course = try await activeCourse(on: app)
            #expect(course.mcpInstructions == nil)
        }
    }

    @Test func emptyingTheBoxRestoresTheDefault() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let course = try await activeCourse(on: app)
            course.mcpInstructions = "Terse and technical."
            try await course.save(on: app.db)
            let (csrf, sessionCookie) = try await csrfFields(
                for: "/instructor/mcp", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/mcp",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    try req.content.encode(["instructions": "   ", "_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.headers.first(name: .location) == "/instructor/mcp?saved=reset")
                })
            let reloaded = try await activeCourse(on: app)
            #expect(reloaded.mcpInstructions == nil)
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
