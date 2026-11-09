// Tests/APITests/MCP/AgentFeedbackDraftCountTests.swift
//
// The access section of the instructor AI agents tab counts each
// assignment's draft feedback in one read for every assignment. Each row
// must still carry its own assignment's count, and only drafts.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class AgentFeedbackDraftCountTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "agent-draft-counts")
    }

    private func feedback(
        _ assignmentID: UUID, _ username: String, state: APIReflectionFeedback.State
    ) async throws {
        let user = try await makeTestUser(on: app, username: username)
        let row = APIReflectionFeedback(assignmentID: assignmentID, userID: try user.requireID(), handle: username)
        row.state = state
        try await row.save(on: app.db)
    }

    @Test func eachAssignmentCountsOnlyItsOwnDrafts() async throws {
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS200")
            course.aiFeedbackEnabled = true
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            // An assignment's setup row must exist first (foreign key).
            for setupID in ["draft_alpha", "draft_beta", "draft_gamma"] {
                try await makeTestSetup(on: app, id: setupID, courseID: courseID)
            }

            let alpha = try await makeTestAssignment(
                on: app, testSetupID: "draft_alpha", courseID: courseID, title: "Alpha")
            let beta = try await makeTestAssignment(
                on: app, testSetupID: "draft_beta", courseID: courseID, title: "Beta")
            let gamma = try await makeTestAssignment(
                on: app, testSetupID: "draft_gamma", courseID: courseID, title: "Gamma")
            for assignment in [alpha, beta, gamma] {
                assignment.aiFeedbackEnabled = true
                try await assignment.save(on: app.db)
            }
            let alphaID = try alpha.requireID()
            let betaID = try beta.requireID()
            try await feedback(alphaID, "a1", state: .draft)
            try await feedback(alphaID, "a2", state: .draft)
            try await feedback(betaID, "b1", state: .draft)
            try await feedback(betaID, "b2", state: .none)

            let viewer = try await makeTestUser(on: app, username: "draft-prof")
            let facts = try await InstructorDashboardRoutes().agentAccessFacts(
                course: course, viewer: viewer, req: makeTestRequest(on: app))

            let counts = Dictionary(
                uniqueKeysWithValues: facts.feedbackAssignments.map { ($0.title, $0.draftCount) })
            #expect(counts == ["Alpha": 2, "Beta": 1, "Gamma": 0])
            #expect(facts.feedbackAssignments.map(\.title) == ["Alpha", "Beta", "Gamma"])
        }
    }
}
