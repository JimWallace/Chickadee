// Tests/APITests/InstructorAIAgentsTabTests.swift
//
// The access half of the instructor AI agents tab (docs/ai-assisted-feedback.md
// §"The AI agents tab"): the tab label, what the page says an agent can reach,
// the opted-in assignments with their drafts, and the account attestation that
// course staff record and withdraw. The authoring-voice half is covered by
// InstructorMCPPanelTests.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct InstructorAIAgentsTabTests {

    private func course(on app: Application, feedbackOn: Bool) async throws -> APICourse {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let course = try #require(try await APICourse.find(courseID, on: app.db))
        course.aiFeedbackEnabled = feedbackOn
        try await course.save(on: app.db)
        return course
    }

    private func page(_ cookie: String, on app: Application) async throws -> String {
        try await getHTML("/instructor/mcp", cookie: cookie, on: app)
    }

    private func postAttestation(
        _ action: String, cookie: String, on app: Application
    ) async throws -> String? {
        let (csrf, session) = try await csrfFields(for: "/instructor/mcp", cookie: cookie, on: app)
        var location: String?
        try await app.asyncTest(
            .POST, "/instructor/mcp/attestation",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: session)
                try req.content.encode(["action": action, "_csrf": csrf], as: .urlEncodedForm)
            },
            afterResponse: { res in location = res.headers.first(name: .location) })
        return location
    }

    private func enrollment(_ username: String, on app: Application) async throws -> APICourseEnrollment {
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        return try #require(
            try await APICourseEnrollment.query(on: app.db).filter(\.$userID == user.requireID()).first())
    }

    @Test func theTabIsCalledAIAgents() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let html = try await page(cookie, on: app)
            #expect(html.contains(">AI agents</a>"))
            #expect(!html.contains(">MCP</a>"))
        }
    }

    @Test func withTheCourseGateOffFeedbackReadsOffAndThereIsNoAttestation() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            _ = try await course(on: app, feedbackOn: false)
            let html = try await page(cookie, on: app)
            #expect(html.contains("Feedback on written answers"))
            #expect(!html.contains("/instructor/mcp/attestation"))
            #expect(html.contains("href=\"/agents\""))
        }
    }

    @Test func withTheCourseGateOnTheOptedInAssignmentAndItsDraftsAreListed() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let course = try await course(on: app, feedbackOn: true)
            let courseID = try course.requireID()
            try await makeTestSetup(on: app, id: "setup_tab_on", courseID: courseID)
            let gated = try await makeTestAssignment(
                on: app, testSetupID: "setup_tab_on", courseID: courseID, title: "Reflect Lab")
            gated.aiFeedbackEnabled = true
            try await gated.save(on: app.db)
            try await makeTestSetup(on: app, id: "setup_tab_off", courseID: courseID)
            try await makeTestAssignment(
                on: app, testSetupID: "setup_tab_off", courseID: courseID, title: "Plain Lab")

            let student = try await makeTestStudent(on: app, username: "tabstudent")
            let row = APIReflectionFeedback(
                assignmentID: try gated.requireID(), userID: try student.requireID(), handle: "R-7Q2M4K")
            row.state = .draft
            row.draftText = "Draft."
            try await row.save(on: app.db)

            let html = try await page(cookie, on: app)
            #expect(html.contains("/instructor/\(gated.publicID)/feedback"))
            #expect(html.contains("Reflect Lab"))
            #expect(!html.contains("Plain Lab"))
            #expect(html.contains("<td>1</td>"))
            #expect(html.contains("/instructor/mcp/attestation"))
        }
    }

    @Test func staffRecordAndWithdrawTheAttestationWithAnAuditRow() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await loginAsCourseTA("tabta", on: app)
            _ = try await course(on: app, feedbackOn: true)

            #expect(try await postAttestation("record", cookie: cookie, on: app) == "/instructor/mcp?saved=attested")
            #expect(try await enrollment("tabta", on: app).aiFeedbackAttestedAt != nil)
            #expect(try await page(cookie, on: app).contains(">Withdraw<"))
            let audits = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.aiFeedbackAttestationChanged.rawValue)
                .count()
            #expect(audits == 1)

            #expect(try await postAttestation("withdraw", cookie: cookie, on: app) == "/instructor/mcp?saved=withdrawn")
            #expect(try await enrollment("tabta", on: app).aiFeedbackAttestedAt == nil)
        }
    }

    @Test func theAttestationIsRefusedWhileTheCourseGateIsOff() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            _ = try await course(on: app, feedbackOn: false)
            #expect(try await postAttestation("record", cookie: cookie, on: app) == "/instructor/mcp?error=course")
            #expect(try await enrollment("testinstructor", on: app).aiFeedbackAttestedAt == nil)
        }
    }
}
