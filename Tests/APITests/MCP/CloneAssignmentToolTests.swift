// Tests for CloneAssignmentTool (duplicate an assignment + its test setup),
// backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct CloneAssignmentToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    /// Course + enrolled instructor "tester" + setup (real on-disk zip +
    /// notebook) + assignment.  Returns the source assignment.
    private func fixture(
        on app: Application, courseCode: String = "CS246"
    ) async throws
        -> APIAssignment
    {
        let course = try await makeTestCourse(on: app, code: courseCode, name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_src", courseID: courseID)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_src", courseID: courseID, title: "Lab 1", isOpen: true)
    }

    @Test func clonesWithinSameCourse() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let source = try await fixture(on: app)
            let output = try await CloneAssignmentTool().execute(
                CloneAssignmentTool.Input(
                    sourceAssignmentPublicID: source.publicID, newTitle: "  Lab 1 (Copy)  ",
                    targetCourseCode: nil),
                context(app))

            #expect(output.title == "Lab 1 (Copy)")
            #expect(output.courseCode == "CS246")
            #expect(output.isOpen == false)
            #expect(output.validationStatus == nil)
            #expect(output.publicID != source.publicID)

            // New assignment persisted in the same course, pointing at a NEW setup.
            let clone = try #require(try await assignmentByPublicID(output.publicID, on: app.db))
            #expect(clone.courseID == source.courseID)
            #expect(clone.testSetupID != source.testSetupID)

            // New setup exists with the manifest copied verbatim, and its zip
            // file was physically copied to disk.
            let srcSetup = try #require(try await APITestSetup.find(source.testSetupID, on: app.db))
            let cloneSetup = try #require(try await APITestSetup.find(clone.testSetupID, on: app.db))
            #expect(cloneSetup.manifest == srcSetup.manifest)
            #expect(FileManager.default.fileExists(atPath: cloneSetup.zipPath))
            #expect(cloneSetup.zipPath != srcSetup.zipPath)

            // Source is untouched.
            let reloadedSource = try #require(
                try await assignmentByPublicID(source.publicID, on: app.db))
            #expect(reloadedSource.isOpen == true)
        }
    }

    @Test func copiesNotebook() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let source = try await fixture(on: app)
            let output = try await CloneAssignmentTool().execute(
                CloneAssignmentTool.Input(
                    sourceAssignmentPublicID: source.publicID, newTitle: "Lab 1 v2",
                    targetCourseCode: nil),
                context(app))
            let clone = try #require(try await assignmentByPublicID(output.publicID, on: app.db))
            let cloneSetup = try #require(try await APITestSetup.find(clone.testSetupID, on: app.db))
            let notebookPath = try #require(cloneSetup.notebookPath)
            #expect(FileManager.default.fileExists(atPath: notebookPath))
        }
    }

    /// The reference solution must travel with the clone. It lives in a
    /// `validation`-kind submission rather than the setup zip, so a clone that
    /// copies only the setup lands an assignment that can never be
    /// re-validated — the defect that left a copied term with no answer keys.
    @Test func carriesTheReferenceSolution() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let source = try await fixture(on: app)
            let tester = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "tester").first())
            let solution = try await makeTestSubmission(
                on: app, id: "sub_solution", setupID: source.testSetupID,
                userID: try tester.requireID(), kind: APISubmission.Kind.validation,
                filename: "solution.ipynb")
            source.validationSubmissionID = try solution.requireID()
            try await source.save(on: app.db)

            let output = try await CloneAssignmentTool().execute(
                CloneAssignmentTool.Input(
                    sourceAssignmentPublicID: source.publicID, newTitle: "Lab 1 (Copy)",
                    targetCourseCode: nil),
                context(app))

            let clone = try #require(try await assignmentByPublicID(output.publicID, on: app.db))

            // The clone owns its own solution, bound to its own setup.
            let clonedID = try #require(clone.validationSubmissionID)
            #expect(clonedID != solution.id)
            let clonedSolution = try #require(try await APISubmission.find(clonedID, on: app.db))
            #expect(clonedSolution.kind == APISubmission.Kind.validation)
            #expect(clonedSolution.testSetupID == clone.testSetupID)
            #expect(clonedSolution.filename == "solution.ipynb")

            // Its bytes are a real copy at a distinct path, not a shared file.
            #expect(clonedSolution.zipPath != solution.zipPath)
            #expect(FileManager.default.fileExists(atPath: clonedSolution.zipPath))
            let original = try Data(contentsOf: URL(fileURLWithPath: solution.zipPath))
            let copied = try Data(contentsOf: URL(fileURLWithPath: clonedSolution.zipPath))
            #expect(original == copied)

            // Resolution finds it — this is what get_solution reads.
            let resolved = try #require(
                try await MCPStudentDataBoundary.validationSubmission(for: clone, on: app.db))
            #expect(resolved.id == clonedID)

            // The clone is still unvalidated: carrying a solution is not
            // evidence that it passes against this suite.
            #expect(clone.validationStatus == nil)
            #expect(output.validationStatus == nil)
        }
    }

    /// An assignment authored without a solution is a legitimate state, so
    /// cloning one must still succeed rather than refusing for a missing file.
    @Test func clonesAnAssignmentThatHasNoSolution() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let source = try await fixture(on: app)
            let output = try await CloneAssignmentTool().execute(
                CloneAssignmentTool.Input(
                    sourceAssignmentPublicID: source.publicID, newTitle: "Lab 1 (Copy)",
                    targetCourseCode: nil),
                context(app))
            let clone = try #require(try await assignmentByPublicID(output.publicID, on: app.db))
            #expect(clone.validationSubmissionID == nil)
            let resolved = try await MCPStudentDataBoundary.validationSubmission(
                for: clone, on: app.db)
            #expect(resolved == nil)
        }
    }

    @Test func clonesIntoAnotherEnrolledCourse() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let source = try await fixture(on: app)
            // A second course the same instructor is enrolled in.
            let other = try await makeTestCourse(on: app, code: "CS200", name: "Intro")
            let otherID = try other.requireID()
            let tester = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "tester").first())
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: otherID)

            let output = try await CloneAssignmentTool().execute(
                CloneAssignmentTool.Input(
                    sourceAssignmentPublicID: source.publicID, newTitle: "Lab 1 (Intro)",
                    targetCourseCode: "CS200"),
                context(app))
            #expect(output.courseCode == "CS200")
            let clone = try #require(try await assignmentByPublicID(output.publicID, on: app.db))
            #expect(clone.courseID == otherID)
        }
    }

    @Test func unknownSourceThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CloneAssignmentTool().execute(
                    CloneAssignmentTool.Input(
                        sourceAssignmentPublicID: "zzzzzz", newTitle: "X", targetCourseCode: nil),
                    context(app))
            }
        }
    }

    @Test func emptyTitleThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let source = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CloneAssignmentTool().execute(
                    CloneAssignmentTool.Input(
                        sourceAssignmentPublicID: source.publicID, newTitle: "   ",
                        targetCourseCode: nil),
                    context(app))
            }
        }
    }

    @Test func unknownTargetCourseThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let source = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CloneAssignmentTool().execute(
                    CloneAssignmentTool.Input(
                        sourceAssignmentPublicID: source.publicID, newTitle: "X",
                        targetCourseCode: "NOPE99"),
                    context(app))
            }
        }
    }

    @Test func deniesWhenNotEnrolledInSource() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestSetup(on: app, id: "setup_src", courseID: courseID)
            let source = try await makeTestAssignment(
                on: app, testSetupID: "setup_src", courseID: courseID, title: "Lab 1")
            await #expect(throws: MCPToolError.self) {
                _ = try await CloneAssignmentTool().execute(
                    CloneAssignmentTool.Input(
                        sourceAssignmentPublicID: source.publicID, newTitle: "Copy",
                        targetCourseCode: nil),
                    context(app))
            }
        }
    }

    @Test func deniesWhenNotEnrolledInTargetCourse() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let source = try await fixture(on: app)
            // Target course the instructor is NOT enrolled in.
            _ = try await makeTestCourse(on: app, code: "CS200", name: "Intro")
            await #expect(throws: MCPToolError.self) {
                _ = try await CloneAssignmentTool().execute(
                    CloneAssignmentTool.Input(
                        sourceAssignmentPublicID: source.publicID, newTitle: "Copy",
                        targetCourseCode: "CS200"),
                    context(app))
            }
        }
    }
}
