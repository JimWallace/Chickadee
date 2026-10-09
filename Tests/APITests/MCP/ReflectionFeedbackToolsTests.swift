// Tests for the AI-assisted feedback tools (docs/ai-assisted-feedback.md):
// list_reflections, get_reflections and draft_feedback, backed by a real test
// database. They pin the two gates, the TA+ floor, that the agent sees a
// pseudonymous handle and never an identity, that a draft is never shown as
// released, and that released feedback cannot be overwritten by an agent.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct ReflectionFeedbackToolsTests {
    private static let starter = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
        {"cell_type":"markdown","id":"q1","metadata":{},"source":["Why did you drop the outliers?"]},
        {"cell_type":"markdown","id":"a1","metadata":{"tags":["reflection"]},"source":["Your answer"]},
        {"cell_type":"code","id":"c1","metadata":{},"source":["x = 1"],"outputs":[],"execution_count":null},
        {"cell_type":"markdown","id":"q2","metadata":{},"source":["Is the median a better summary here?"]},
        {"cell_type":"markdown","id":"a2","metadata":{"tags":["reflection"]},"source":["Your answer"]}
        ]}
        """

    private static let aliceNotebook = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[
        {"cell_type":"markdown","id":"q1","metadata":{},"source":["Why did you drop the outliers?"]},
        {"cell_type":"markdown","id":"a1","metadata":{"tags":["reflection"]},"source":["They were data-entry errors."]},
        {"cell_type":"code","id":"c1","metadata":{},"source":["secret_code = 42"],"outputs":[],"execution_count":1},
        {"cell_type":"markdown","id":"q2","metadata":{},"source":["Is the median a better summary here?"]},
        {"cell_type":"markdown","id":"a2","metadata":{"tags":["reflection"]},"source":["Yes, the data are skewed."]}
        ]}
        """

    private struct Fixture {
        let assignment: APIAssignment
        let course: APICourse
    }

    private func context(
        _ app: Application, subject: String = "tester",
        scopes: Set<ContentScope> = [.feedbackRead, .feedbackWrite]
    ) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: subject,
            grantedScopes: scopes,
            actingClientName: "Claude")
    }

    /// A course and assignment with both gates as given, an instructor
    /// "tester", and one student "alice" with a submission.
    private func fixture(
        on app: Application, courseGate: Bool = true, assignmentGate: Bool = true
    ) async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "HLTH101", name: "Health Data")
        course.aiFeedbackEnabled = courseGate
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        let setup = try await makeTestSetup(on: app, id: "setup_fb", courseID: courseID)
        let starterPath = try #require(setup.notebookPath)
        try Self.starter.write(toFile: starterPath, atomically: true, encoding: .utf8)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "setup_fb", courseID: courseID, title: "Lab 3")
        assignment.aiFeedbackEnabled = assignmentGate
        try await assignment.save(on: app.db)

        let alice = try await makeTestStudent(on: app, username: "alice")
        try await makeTestEnrollment(on: app, userID: alice.requireID(), courseID: courseID)
        let submission = try await makeTestSubmission(
            on: app, id: "sub_alice_1", setupID: "setup_fb", userID: alice.requireID())
        try Self.aliceNotebook.write(toFile: submission.zipPath, atomically: true, encoding: .utf8)
        return Fixture(assignment: assignment, course: course)
    }

    private func list(_ app: Application, _ publicID: String) async throws -> ListReflectionsTool.Output {
        try await ListReflectionsTool().execute(.init(assignmentPublicID: publicID), context(app))
    }

    // MARK: - Gates

    @Test(arguments: [(false, true), (true, false), (false, false)])
    func everyToolRefusesUnlessBothGatesAreOn(courseGate: Bool, assignmentGate: Bool) async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app, courseGate: courseGate, assignmentGate: assignmentGate)
            let id = fx.assignment.publicID
            await #expect(throws: MCPToolError.self) { try await list(app, id) }
            await #expect(throws: MCPToolError.self) {
                try await GetReflectionsTool().execute(
                    .init(assignmentPublicID: id, handle: "R-222222"), context(app))
            }
            await #expect(throws: MCPToolError.self) {
                try await DraftFeedbackTool().execute(
                    .init(assignmentPublicID: id, handle: "R-222222", feedback: "Good."), context(app))
            }
            // A refused call makes no handle rows.
            #expect(try await APIReflectionFeedback.query(on: app.db).count() == 0)
        }
    }

    @Test func aStudentAccountIsRefused() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                try await ListReflectionsTool().execute(
                    .init(assignmentPublicID: fx.assignment.publicID), context(app, subject: "alice"))
            }
        }
    }

    // MARK: - Reading

    @Test func listReturnsHandlesAndNoIdentity() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app)
            let out = try await list(app, fx.assignment.publicID)
            #expect(out.reflectionPromptCount == 2)
            let entry = try #require(out.students.first)
            #expect(out.students.count == 1)
            #expect(FeedbackHandle.isWellFormed(entry.handle))
            #expect(entry.feedbackState == "none")

            let json = try #require(String(bytes: try JSONEncoder().encode(out), encoding: .utf8))
            #expect(!json.contains("alice"))
            let aliceID = try #require(try await APIUser.query(on: app.db).filter(\.$username == "alice").first()?.id)
            #expect(!json.contains(aliceID.uuidString))

            // The handle is stable across calls.
            let again = try await list(app, fx.assignment.publicID)
            #expect(again.students.map(\.handle) == out.students.map(\.handle))
        }
    }

    @Test func getReturnsPromptsFromTheStarterAndOnlyTheTaggedAnswers() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app)
            let handle = try #require(try await list(app, fx.assignment.publicID).students.first?.handle)
            let out = try await GetReflectionsTool().execute(
                .init(assignmentPublicID: fx.assignment.publicID, handle: handle), context(app))
            #expect(
                out.reflections == [
                    ReflectionPair(
                        index: 1, prompt: "Why did you drop the outliers?",
                        response: "They were data-entry errors."),
                    ReflectionPair(
                        index: 2, prompt: "Is the median a better summary here?",
                        response: "Yes, the data are skewed."),
                ])
            let json = try #require(String(bytes: try JSONEncoder().encode(out), encoding: .utf8))
            #expect(!json.contains("secret_code"))
            #expect(!json.contains("alice"))
        }
    }

    @Test func anUnknownHandleIsRefused() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                try await GetReflectionsTool().execute(
                    .init(assignmentPublicID: fx.assignment.publicID, handle: "R-222222"), context(app))
            }
            await #expect(throws: MCPToolError.self) {
                try await GetReflectionsTool().execute(
                    .init(assignmentPublicID: fx.assignment.publicID, handle: "alice"), context(app))
            }
        }
    }

    // MARK: - Drafting

    @Test func aDraftIsSavedButNotReleased() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app)
            let handle = try #require(try await list(app, fx.assignment.publicID).students.first?.handle)
            let out = try await DraftFeedbackTool().execute(
                .init(assignmentPublicID: fx.assignment.publicID, handle: handle, feedback: "  Clear reasoning.  "),
                context(app))
            #expect(out.feedbackState == "draft")

            let row = try #require(try await APIReflectionFeedback.query(on: app.db).first())
            #expect(row.draftText == "Clear reasoning.")
            #expect(row.state == .draft)
            #expect(row.draftedByClient == "Claude")
            #expect(row.submissionID == "sub_alice_1")
            #expect(row.releasedAt == nil)
        }
    }

    @Test func releasedFeedbackCannotBeReplacedByAnAgent() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app)
            let handle = try #require(try await list(app, fx.assignment.publicID).students.first?.handle)
            let row = try #require(try await APIReflectionFeedback.query(on: app.db).first())
            row.state = .released
            row.draftText = "Reviewed text."
            row.submissionID = "sub_alice_1"
            try await row.save(on: app.db)

            await #expect(throws: MCPToolError.self) {
                try await DraftFeedbackTool().execute(
                    .init(assignmentPublicID: fx.assignment.publicID, handle: handle, feedback: "New."),
                    context(app))
            }
            let reloaded = try #require(try await APIReflectionFeedback.find(row.id, on: app.db))
            #expect(reloaded.draftText == "Reviewed text.")
        }
    }

    @Test func aResubmissionMakesTheFeedbackStale() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app)
            let handle = try #require(try await list(app, fx.assignment.publicID).students.first?.handle)
            _ = try await DraftFeedbackTool().execute(
                .init(assignmentPublicID: fx.assignment.publicID, handle: handle, feedback: "Good."),
                context(app))

            let alice = try #require(try await APIUser.query(on: app.db).filter(\.$username == "alice").first())
            let second = try await makeTestSubmission(
                on: app, id: "sub_alice_2", setupID: "setup_fb", userID: alice.requireID())
            second.submittedAt = Date().addingTimeInterval(60)
            try await second.save(on: app.db)

            let out = try await list(app, fx.assignment.publicID)
            #expect(out.students.first?.feedbackState == "stale")
        }
    }

    @Test(arguments: ["", "   ", String(repeating: "x", count: ReflectionFeedbackService.maxDraftLength + 1)])
    func emptyOrOverlongFeedbackIsRefused(feedback: String) async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let fx = try await fixture(on: app)
            let handle = try #require(try await list(app, fx.assignment.publicID).students.first?.handle)
            await #expect(throws: MCPToolError.self) {
                try await DraftFeedbackTool().execute(
                    .init(assignmentPublicID: fx.assignment.publicID, handle: handle, feedback: feedback),
                    context(app))
            }
        }
    }

    // MARK: - Scopes

    @Test func theToolsRequireTheFeedbackScopesOnly() {
        #expect(ListReflectionsTool.requiredScopes == [.feedbackRead])
        #expect(GetReflectionsTool.requiredScopes == [.feedbackRead])
        #expect(DraftFeedbackTool.requiredScopes == [.feedbackWrite])
        #expect(ContentScope.feedbackWrite.isWrite)
        #expect(!ContentScope.feedbackRead.isWrite)
        #expect(MCPMode.readOnly.scopeCeiling.contains(.feedbackRead))
        #expect(!MCPMode.readOnly.scopeCeiling.contains(.feedbackWrite))
    }
}
