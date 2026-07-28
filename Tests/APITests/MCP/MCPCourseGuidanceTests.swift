// Tests/APITests/MCP/MCPCourseGuidanceTests.swift
//
// The authoring-voice guide embedded in the content server's initialize
// instructions, and the per-course guidance layered on top for the connecting
// account: which enrollments contribute (authoring authority only, admins via
// any enrollment), which never do (student role, archived, unset/blank text),
// and the composed shape an agent actually receives from `initialize`.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPCourseGuidanceTests {

    // MARK: - House authoring-voice block (pure)

    @Test func instructionsCarryTheAuthoringVoiceGuide() {
        let text = MCPServerInstructions.text
        // Appended to the operational guide, never replacing it.
        #expect(text.hasPrefix(MCPServerInstructions.operationalGuide))
        #expect(text.hasSuffix(MCPServerInstructions.authoringVoice))
        #expect(text.contains("Authoring voice for Chickadee assignments"))
        // Load-bearing rules survive verbatim.
        #expect(text.contains("Do not narrate the student's experience of the task, and do not cheerlead."))
        #expect(text.contains("Prohibited in instructional text:"))
        #expect(text.contains("- Exclamation marks."))
        #expect(text.contains("- Emoji."))
        // The warmth-in-difficulty nuance is intact — the guide must not be
        // reduced to "be formal".
        #expect(text.contains("Warmth belongs in how difficulty is"))
        #expect(text.contains("not stiff or joyless"))
    }

    @Test func courseGuidanceComposesLabelledBlocks() {
        let composed = MCPServerInstructions.text(withCourseGuidance: [
            MCPCourseGuidance(courseCode: "CS136", text: "Use metric units."),
            MCPCourseGuidance(courseCode: "HLTH204", text: "Prefer health-data examples."),
        ])
        #expect(composed.hasPrefix(MCPServerInstructions.text))
        #expect(composed.contains("Course-specific authoring guidance"))
        #expect(composed.contains("Course CS136:\nUse metric units."))
        #expect(composed.contains("Course HLTH204:\nPrefer health-data examples."))
    }

    @Test func emptyGuidanceLeavesInstructionsByteIdentical() {
        #expect(MCPServerInstructions.text(withCourseGuidance: []) == MCPServerInstructions.text)
    }

    // MARK: - Guidance resolution (DB)

    private func enroll(
        _ userID: UUID, in course: APICourse, as role: CourseRole, on app: Application
    ) async throws {
        try await APICourseEnrollment(userID: userID, courseID: try course.requireID(), role: role)
            .save(on: app.db)
    }

    @Test func staffCoursesWithTextContributeGuidanceInCodeOrder() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let user = try await makeTestUser(on: app, username: "guidance_user")
            let userID = try user.requireID()

            // Instructor course with text — later code, sorts second.
            let chem = try await makeTestCourse(on: app, code: "ZCHEM301")
            chem.mcpInstructions = "Cite lab-safety rules."
            try await chem.save(on: app.db)
            try await enroll(userID, in: chem, as: .instructor, on: app)

            // TA course with text — earlier code, sorts first; stored text is
            // trimmed on the way out.
            let cs = try await makeTestCourse(on: app, code: "ACS101")
            cs.mcpInstructions = "  Address students in the plural.  "
            try await cs.save(on: app.db)
            try await enroll(userID, in: cs, as: .ta, on: app)

            let guidance = try await mcpCourseGuidance(forSubject: "guidance_user", db: app.db)
            #expect(
                guidance == [
                    MCPCourseGuidance(courseCode: "ACS101", text: "Address students in the plural."),
                    MCPCourseGuidance(courseCode: "ZCHEM301", text: "Cite lab-safety rules."),
                ])
        }
    }

    @Test func studentRoleArchivedAndUnsetCoursesContributeNothing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let user = try await makeTestUser(on: app, username: "guidance_user")
            let userID = try user.requireID()

            // Enrolled as a student (no authoring authority) — excluded even
            // though the course carries text.
            let studentCourse = try await makeTestCourse(on: app, code: "STUD100")
            studentCourse.mcpInstructions = "Never shown."
            try await studentCourse.save(on: app.db)
            try await enroll(userID, in: studentCourse, as: .student, on: app)

            // Archived instructor course — excluded (writes are blocked there).
            let archived = try await makeTestCourse(on: app, code: "OLD200", archived: true)
            archived.mcpInstructions = "Stale guidance."
            try await archived.save(on: app.db)
            try await enroll(userID, in: archived, as: .instructor, on: app)

            // Instructor course with only whitespace text — excluded.
            let blank = try await makeTestCourse(on: app, code: "BLANK1")
            blank.mcpInstructions = "   \n  "
            try await blank.save(on: app.db)
            try await enroll(userID, in: blank, as: .instructor, on: app)

            // Instructor course with no text at all — excluded.
            let unset = try await makeTestCourse(on: app, code: "UNSET1")
            try await enroll(userID, in: unset, as: .instructor, on: app)

            let guidance = try await mcpCourseGuidance(forSubject: "guidance_user", db: app.db)
            #expect(guidance.isEmpty)
        }
    }

    @Test func adminQualifiesThroughAnyEnrollment() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            // Admins bypass the per-course role floor on writes
            // (evaluateCourseWrite), so a student-role enrollment still counts
            // for them — but enrollment is still required.
            let admin = try await makeTestUser(on: app, username: "guidance_admin", role: "admin")
            let adminID = try admin.requireID()

            let enrolledCourse = try await makeTestCourse(on: app, code: "ADM101")
            enrolledCourse.mcpInstructions = "Admin-visible guidance."
            try await enrolledCourse.save(on: app.db)
            try await enroll(adminID, in: enrolledCourse, as: .student, on: app)

            // Not enrolled → not included, admin or not (agent scope ⊆ human scope).
            let unenrolled = try await makeTestCourse(on: app, code: "FAR900")
            unenrolled.mcpInstructions = "Out of reach."
            try await unenrolled.save(on: app.db)

            let guidance = try await mcpCourseGuidance(forSubject: "guidance_admin", db: app.db)
            #expect(guidance == [MCPCourseGuidance(courseCode: "ADM101", text: "Admin-visible guidance.")])
        }
    }

    @Test func unknownSubjectResolvesToNoGuidance() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let guidance = try await mcpCourseGuidance(forSubject: "nobody_here", db: app.db)
            #expect(guidance.isEmpty)
        }
    }

    // MARK: - initialize integration

    private func toolContext(_ app: Application, subject: String) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: subject,
            grantedScopes: [.read, .write])
    }

    private func initializeInstructions(
        _ app: Application, subject: String
    ) async throws -> String {
        let dispatcher = MCPDispatcher(
            serverInfo: MCPServerInfo(name: "Chickadee MCP", version: "test"))
        let request = JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "initialize", params: nil)
        let response = try #require(
            await dispatcher.dispatch(request, context: toolContext(app, subject: subject)))
        guard case .object(let result)? = response.result,
            case .string(let instructions)? = result["instructions"]
        else {
            Issue.record("initialize result carried no instructions string")
            return ""
        }
        return instructions
    }

    @Test func initializeCarriesPerCourseGuidanceForTheSubject() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let user = try await makeTestUser(on: app, username: "guidance_user")
            let course = try await makeTestCourse(on: app, code: "CS136")
            course.mcpInstructions = "Refer to the textbook as CP4."
            try await course.save(on: app.db)
            try await enroll(try user.requireID(), in: course, as: .instructor, on: app)

            let instructions = try await initializeInstructions(app, subject: "guidance_user")
            #expect(instructions.hasPrefix(MCPServerInstructions.text))
            #expect(instructions.contains("Course-specific authoring guidance"))
            #expect(instructions.contains("Course CS136:\nRefer to the textbook as CP4."))
        }
    }

    @Test func initializeWithoutGuidanceServesTheHouseTextExactly() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await makeTestUser(on: app, username: "guidance_user")
            let instructions = try await initializeInstructions(app, subject: "guidance_user")
            #expect(instructions == MCPServerInstructions.text)
        }
    }
}
