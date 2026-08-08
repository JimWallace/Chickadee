// Tests for GetAssignmentTool, backed by a real test database.

import Fluent
import Testing
import Vapor

@testable import APIServer

@Suite struct GetAssignmentToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read, .write]
        )
    }

    @Test func returnsDetailForEnrolledSubject() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_g", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_g", courseID: courseID, title: "Tasks", isOpen: false)

            let output = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), context(app))
            #expect(output.publicID == assignment.publicID)
            #expect(output.title == "Tasks")
            #expect(output.courseCode == "CS246")
            #expect(output.isOpen == false)
            // The default fixture manifest is browser-graded.
            #expect(output.gradingMode == "browser")
            #expect(output.secretRevealEnabled == false, "off by default")
        }
    }

    @Test func reportsSecretRevealEnabled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_sr", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_sr", courseID: courseID, title: "Tasks")
            assignment.secretRevealEnabled = true
            try await assignment.save(on: app.db)

            let output = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), context(app))
            #expect(output.secretRevealEnabled)
        }
    }

    @Test func reportsWorkerGradingMode() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            try await makeTestSetup(
                on: app, id: "setup_w", courseID: courseID,
                manifest:
                    #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#
            )
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_w", courseID: courseID, title: "Tasks")

            let output = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), context(app))
            #expect(output.gradingMode == "worker")
        }
    }

    /// `set_submission_mode` tells its caller to read the current mode from
    /// this tool, which for a long time did not return it at all.
    @Test func reportsSubmissionModeAndLanguage() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            try await makeTestSetup(
                on: app, id: "setup_sm", courseID: courseID,
                manifest:
                    #"{"schemaVersion":1,"gradingMode":"worker","submissionMode":"uploadOnly","language":"cpp","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#
            )
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_sm", courseID: courseID, title: "Tasks")

            let output = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), context(app))
            #expect(output.submissionMode == "uploadOnly")
            #expect(output.language == "cpp")
        }
    }

    /// A notebook assignment keeps the default, and a language-less shell suite
    /// reports no language rather than guessing Python.
    @Test func defaultsToNotebookSubmissionModeAndNoLanguage() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_nb", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_nb", courseID: courseID, title: "Tasks")

            let output = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), context(app))
            #expect(output.submissionMode == "notebook")
            #expect(output.language == nil)
        }
    }

    /// An upload-only assignment grades natively whatever the manifest stores,
    /// so reporting a raw "browser" here would name a path that cannot run.
    /// This pair is what `create_assignment` used to persist for C++.
    @Test func reportsEffectiveGradingModeForUploadOnly() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            try await makeTestSetup(
                on: app, id: "setup_eff", courseID: courseID,
                manifest:
                    #"{"schemaVersion":1,"gradingMode":"browser","submissionMode":"uploadOnly","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#
            )
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_eff", courseID: courseID, title: "Tasks")

            let output = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), context(app))
            #expect(output.gradingMode == "worker")
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestSetup(on: app, id: "setup_g", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_g", courseID: courseID, title: "Tasks")

            await #expect(throws: MCPToolError.self) {
                _ = try await GetAssignmentTool().execute(
                    GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), context(app))
            }
        }
    }

    @Test func unknownAssignmentThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            await #expect(throws: MCPToolError.self) {
                _ = try await GetAssignmentTool().execute(
                    GetAssignmentTool.Input(assignmentPublicID: "zzzzzz"), context(app))
            }
        }
    }
}
