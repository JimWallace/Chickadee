// Tests for the two tools that let a C++ assignment be authored through MCP:
// SetSubmissionModeTool (notebook vs uploadOnly) and SetAssignmentLanguageTool
// (the declared language). Backed by a real test database.
//
// The pair carries an invariant neither half owns alone: cpp ⟺ uploadOnly. Each
// tool refuses the incoherent combination from its own side, so the suite walks
// BOTH directions — a C++ assignment cannot be flipped back to the notebook
// workflow it has no kernel for, and C++ cannot be declared on an assignment
// still in notebook mode.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct SetSubmissionModeAndLanguageToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private let workerManifest =
        #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[],"timeLimitSeconds":10}"#
    private let browserManifest =
        #"{"schemaVersion":1,"gradingMode":"browser","testSuites":[],"timeLimitSeconds":10}"#

    private func fixture(
        on app: Application, manifest: String, enroll: Bool = true
    ) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS247", name: "Software Design")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        if enroll {
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        }
        try await makeTestSetup(on: app, id: "setup_sm", courseID: courseID, manifest: manifest)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_sm", courseID: courseID, title: "Lab")
    }

    private func manifest(
        of assignment: APIAssignment, on app: Application
    ) async throws
        -> TestProperties?
    {
        let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
        return setup.decodedManifest()
    }

    // ── set_submission_mode ────────────────────────────────────────────────

    @Test func setsUploadOnlyAndReportsWorkerGrading() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: workerManifest)

            let out = try await SetSubmissionModeTool().execute(
                .init(assignmentPublicID: assignment.publicID, submissionMode: "uploadOnly"),
                context(app))
            #expect(out.submissionMode == "uploadOnly")
            // Upload-only pins grading to the native worker; the tool reports
            // the effective path rather than leaving the caller to infer it.
            #expect(out.gradingMode == "worker")
            #expect(try await manifest(of: assignment, on: app)?.submissionMode == .uploadOnly)
        }
    }

    @Test func refusesUploadOnlyWhileBrowserGraded() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: browserManifest)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetSubmissionModeTool().execute(
                    .init(assignmentPublicID: assignment.publicID, submissionMode: "uploadOnly"),
                    context(app))
            }
            // Refusing must leave the assignment untouched, not half-saved.
            #expect(try await manifest(of: assignment, on: app)?.submissionMode == .notebook)
        }
    }

    @Test func rejectsUnknownSubmissionMode() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: workerManifest)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetSubmissionModeTool().execute(
                    .init(assignmentPublicID: assignment.publicID, submissionMode: "upload"),
                    context(app))
            }
        }
    }

    @Test func deniesSubmissionModeWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(
                on: app, manifest: workerManifest, enroll: false)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetSubmissionModeTool().execute(
                    .init(assignmentPublicID: assignment.publicID, submissionMode: "uploadOnly"),
                    context(app))
            }
        }
    }

    // ── set_assignment_language ────────────────────────────────────────────

    @Test func declaresCppOnAnUploadOnlyAssignment() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: workerManifest)
            _ = try await SetSubmissionModeTool().execute(
                .init(assignmentPublicID: assignment.publicID, submissionMode: "uploadOnly"),
                context(app))

            let out = try await SetAssignmentLanguageTool().execute(
                .init(assignmentPublicID: assignment.publicID, language: "cpp"), context(app))
            #expect(out.language == "cpp")
            #expect(out.submissionMode == "uploadOnly")

            // The declaration is what resolution reads — the whole point of the
            // tool, since nothing about a C++ assignment implies its language.
            let props = try #require(try await manifest(of: assignment, on: app))
            #expect(props.language == .cpp)
            #expect(AssignmentLanguage.derivedDeclaration(manifest: props, notebookData: nil) == .cpp)
        }
    }

    @Test func refusesCppWhileStillNotebookMode() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: workerManifest)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetAssignmentLanguageTool().execute(
                    .init(assignmentPublicID: assignment.publicID, language: "cpp"), context(app))
            }
            #expect(try await manifest(of: assignment, on: app)?.language == nil)
        }
    }

    /// The invariant from the other side: once an assignment IS C++, it cannot
    /// be flipped back to a notebook workflow it has no kernel for.
    @Test func refusesNotebookModeOnACppAssignment() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: workerManifest)
            _ = try await SetSubmissionModeTool().execute(
                .init(assignmentPublicID: assignment.publicID, submissionMode: "uploadOnly"),
                context(app))
            _ = try await SetAssignmentLanguageTool().execute(
                .init(assignmentPublicID: assignment.publicID, language: "cpp"), context(app))

            await #expect(throws: MCPToolError.self) {
                _ = try await SetSubmissionModeTool().execute(
                    .init(assignmentPublicID: assignment.publicID, submissionMode: "notebook"),
                    context(app))
            }
            #expect(try await manifest(of: assignment, on: app)?.submissionMode == .uploadOnly)
        }
    }

    @Test func refusesALanguageChangeOnceGeneratedTestsExist() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let generated = #"""
                {"schemaVersion":1,"gradingMode":"worker","timeLimitSeconds":10,\
                "testSuites":[{"tier":"public","script":"publictest_bmi_01.py","generatedBy":"bmi"}]}
                """#
                .replacingOccurrences(of: "\\\n", with: "")
            let assignment = try await fixture(on: app, manifest: generated)

            // A change would rewrite every generated filename's extension, which
            // only the family-application path knows how to do.
            await #expect(throws: MCPToolError.self) {
                _ = try await SetAssignmentLanguageTool().execute(
                    .init(assignmentPublicID: assignment.publicID, language: "r"), context(app))
            }
            #expect(try await manifest(of: assignment, on: app)?.language == nil)
        }
    }

    /// Declaring the language an assignment already has must stay a no-op
    /// rather than tripping the generated-scripts guard — otherwise a retry, or
    /// an agent re-asserting known state, fails on an assignment it cannot fix.
    @Test func redeclaringTheSameLanguageIsANoOp() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let generated = #"""
                {"schemaVersion":1,"gradingMode":"worker","timeLimitSeconds":10,"language":"r",\
                "testSuites":[{"tier":"public","script":"publictest_bmi_01.R","generatedBy":"bmi"}]}
                """#
                .replacingOccurrences(of: "\\\n", with: "")
            let assignment = try await fixture(on: app, manifest: generated)

            let out = try await SetAssignmentLanguageTool().execute(
                .init(assignmentPublicID: assignment.publicID, language: "r"), context(app))
            #expect(out.language == "r")
        }
    }

    @Test func rejectsUnknownLanguage() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, manifest: workerManifest)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetAssignmentLanguageTool().execute(
                    .init(assignmentPublicID: assignment.publicID, language: "java"), context(app))
            }
        }
    }

    @Test func deniesLanguageWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(
                on: app, manifest: workerManifest, enroll: false)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetAssignmentLanguageTool().execute(
                    .init(assignmentPublicID: assignment.publicID, language: "lua"), context(app))
            }
        }
    }
}
