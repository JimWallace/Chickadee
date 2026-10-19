// Runs the MCP tools that touch a table the `chickadee_mcp` role cannot use,
// with the dedicated MCP pool configured (`MCPRoleDatabase`). Each such access
// must run on the owner pool (`ToolContext.mainDB`). On the test databases a
// query on the wrong pool succeeds, so without the stand-in these paths pass
// every test and fail only in production.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPOwnerPoolRoutingTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(request: makeTestRequest(on: app), subject: "tester", grantedScopes: [.read, .write])
    }

    /// Course + enrolled instructor "tester". Returns the course id.
    private func course(on app: Application, code: String = "CS246") async throws -> UUID {
        let courseID = try await makeTestCourse(on: app, code: code, name: code).requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        return courseID
    }

    private func versionCount(of setupID: String, on app: Application) async throws -> Int {
        try await APIAssignmentVersion.query(on: app.db).filter(\.$testSetupID == setupID).count()
    }

    /// The stand-in must refuse what the role refuses, or every test below
    /// passes for the wrong reason.
    @Test func theStandInRefusesWhatTheRoleRefuses() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try app.useMCPRoleDatabase()
            let courseID = try await course(on: app)
            try await makeTestSetup(on: app, id: "setup_role", courseID: courseID)
            let tester = try #require(try await APIUser.query(on: app.db).first()?.id)
            _ = try await makeTestSubmission(
                on: app, id: "sub_student", setupID: "setup_role", userID: tester, kind: APISubmission.Kind.student)
            _ = try await makeTestSubmission(
                on: app, id: "sub_valid", setupID: "setup_role", userID: tester, kind: APISubmission.Kind.validation)
            let db = context(app).db

            #expect(try await APICourse.query(on: db).count() == 1)
            await #expect(throws: MCPRoleDatabase.PermissionDenied.self) {
                _ = try await APIAssignmentVersion.query(on: db).count()
            }
            await #expect(throws: MCPRoleDatabase.PermissionDenied.self) {
                try await APISubmission(
                    id: "sub_new", testSetupID: "setup_role", zipPath: "/dev/null", attemptNumber: 1,
                    status: SubmissionStatus.complete.rawValue, filename: nil, userID: tester,
                    kind: APISubmission.Kind.validation
                ).save(on: db)
            }
            #expect(try await APISubmission.query(on: db).all().compactMap(\.id) == ["sub_valid"])
        }
    }

    /// Gap 3: the first version was saved on `context.db`, where
    /// `assignment_versions` is not granted, and `try?` hid the failure. It
    /// must also carry the declared language, or a restore to v1 drops it.
    @Test func createAssignmentRecordsVersionOneWithTheLanguage() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try app.useMCPRoleDatabase()
            _ = try await course(on: app)
            let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#
            let output = try await CreateAssignmentTool().execute(
                CreateAssignmentTool.Input(
                    courseCode: "CS246", title: "New Lab",
                    notebook: try JSONDecoder().decode(JSONValue.self, from: Data(notebook.utf8)),
                    language: "java"),
                context(app))

            let created = try #require(try await assignmentByPublicID(output.publicID, on: app.db))
            let versions = try await APIAssignmentVersion.query(on: app.db)
                .filter(\.$testSetupID == created.testSetupID).all()
            let versionOne = try #require(versions.first)
            #expect(versions.count == 1)
            let manifest = try #require(decodeManifest(fromJSON: versionOne.manifest))
            #expect(manifest.languageDeclaration == .language(.java))
            #expect(manifest.submissionMode == .uploadOnly)
        }
    }

    /// Gaps 1 and 3: the copied reference solution is a new `submissions`
    /// row, which the role may only read, and the first version goes to
    /// `assignment_versions`.
    @Test func cloneAssignmentCopiesTheSolutionAndRecordsVersionOne() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try app.useMCPRoleDatabase()
            let courseID = try await course(on: app)
            try await makeTestSetup(on: app, id: "setup_src", courseID: courseID)
            let source = try await makeTestAssignment(
                on: app, testSetupID: "setup_src", courseID: courseID, title: "Lab 1")
            let tester = try #require(try await APIUser.query(on: app.db).first()?.id)
            let solution = try await makeTestSubmission(
                on: app, id: "sub_solution", setupID: "setup_src", userID: tester,
                kind: APISubmission.Kind.validation, filename: "solution.ipynb")
            try Data("{}".utf8).write(to: URL(fileURLWithPath: solution.zipPath))
            source.validationSubmissionID = "sub_solution"
            try await source.save(on: app.db)

            let output = try await CloneAssignmentTool().execute(
                CloneAssignmentTool.Input(
                    sourceAssignmentPublicID: source.publicID, newTitle: "Lab 1 (Copy)", targetCourseCode: nil),
                context(app))

            let clone = try #require(try await assignmentByPublicID(output.publicID, on: app.db))
            let copiedID = try #require(clone.validationSubmissionID)
            #expect(copiedID != "sub_solution")
            #expect(try await APISubmission.find(copiedID, on: app.db)?.testSetupID == clone.testSetupID)
            #expect(try await versionCount(of: clone.testSetupID, on: app) == 1)
        }
    }

    /// A library dataset makes the clone read `course_datasets` on the MCP
    /// pool. The role was granted that table with the dataset library tools,
    /// so this read needs no owner pool; the test keeps it that way.
    @Test func cloneAssignmentKeepsALibraryDataset() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try app.useMCPRoleDatabase()
            let courseID = try await course(on: app)
            let directory = app.testSetupsDirectory
            try await writeZipFixture(at: directory + "setup_lib.zip", entries: [("test_a.sh", "exit 0\n")])
            let setup = try await makeTestSetup(
                on: app, id: "setup_lib", courseID: courseID, withNotebook: false, withZip: false)
            let blobs = AssignmentVersionBlobStore(testSetupsDirectory: directory)
            let dataset = try await CourseDatasetService.create(
                courseID: courseID,
                dataset: .init(name: "Cases", slug: "cases", description: nil, provenance: nil, licence: nil),
                upload: .init(filename: "cases.csv", bytes: Data("id,value\n1,2\n2,3\n".utf8), note: nil),
                blobs: blobs, on: app.db
            ).dataset
            let spec = try await CourseDatasetService.attach(
                dataset, to: setup,
                request: .init(version: 1, filename: nil, sampleSize: nil, stratumColumn: nil, scope: .assignment),
                testSetupsDirectory: directory, on: app.db)
            let source = try await makeTestAssignment(
                on: app, testSetupID: "setup_lib", courseID: courseID, title: "Cohort lab")

            let output = try await CloneAssignmentTool().execute(
                CloneAssignmentTool.Input(
                    sourceAssignmentPublicID: source.publicID, newTitle: "Cohort lab copy", targetCourseCode: nil),
                context(app))

            let clone = try #require(try await assignmentByPublicID(output.publicID, on: app.db))
            let cloneSetup = try #require(try await APITestSetup.find(clone.testSetupID, on: app.db))
            #expect(cloneSetup.decodedManifest()?.datasets == [spec])
        }
    }

    /// Gap 5: the row-level security policy shows the role only validation
    /// submissions, so the starter run was never found.
    @Test func getSuiteReportsTheStarterRun() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try app.useMCPRoleDatabase()
            let courseID = try await course(on: app)
            try await makeTestSetup(on: app, id: "setup_starter", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_starter", courseID: courseID, title: "Lab")
            let tester = try #require(try await APIUser.query(on: app.db).first()?.id)
            _ = try await makeTestSubmission(
                on: app, id: "sub_starter", setupID: "setup_starter", userID: tester,
                kind: APISubmission.Kind.starterValidation)
            _ = try await makeTestResult(
                on: app, submissionID: "sub_starter", collectionJSON: try starterCollectionJSON())

            let suite = try await GetSuiteTool().execute(
                GetSuiteTool.Input(assignmentPublicID: assignment.publicID), context(app))

            let starter = try #require(suite.starterRun)
            #expect(starter.outcomes.map(\.testName) == ["test_a"])
        }
    }

    /// The starter run is read on the owner pool, where no row-level security
    /// applies, so only the kind filter keeps other submissions out of it.
    @Test func getSuiteNeverReportsAStudentOrSolutionRunAsTheStarterRun() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            try app.useMCPRoleDatabase()
            let courseID = try await course(on: app)
            try await makeTestSetup(on: app, id: "setup_starter", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_starter", courseID: courseID, title: "Lab")
            let tester = try #require(try await APIUser.query(on: app.db).first()?.id)
            for (id, kind) in [
                ("sub_student", APISubmission.Kind.student), ("sub_solution", APISubmission.Kind.validation),
            ] {
                _ = try await makeTestSubmission(on: app, id: id, setupID: "setup_starter", userID: tester, kind: kind)
                _ = try await makeTestResult(on: app, submissionID: id, collectionJSON: try starterCollectionJSON())
            }

            let suite = try await GetSuiteTool().execute(
                GetSuiteTool.Input(assignmentPublicID: assignment.publicID), context(app))

            #expect(suite.starterRun == nil)
        }
    }

    private func starterCollectionJSON() throws -> String {
        let outcome = TestOutcome(
            testName: "test_a", testClass: nil, tier: .pub, status: .fail, shortResult: "not done",
            longResult: nil, executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1,
            isFirstPassSuccess: false)
        let collection = TestOutcomeCollection(
            submissionID: "sub_starter", testSetupID: "setup_starter", attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: [outcome], totalTests: 1, passCount: 0, failCount: 1, errorCount: 0,
            timeoutCount: 0, executionTimeMs: 5, runnerVersion: "shell-runner/1.0", timestamp: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try #require(String(data: encoder.encode(collection), encoding: .utf8))
    }
}
