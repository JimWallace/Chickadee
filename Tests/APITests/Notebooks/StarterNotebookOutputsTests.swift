// A starter notebook reaches students without the author's cell outputs: the
// editor's save route, the shared authoring write (MCP `update_notebook` and
// assignment creation), a starter read from the setup zip, and the one-time
// `StripStarterNotebookOutputs` migration all clear them. The author's own
// working copy and the solution keep theirs.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class StarterNotebookOutputsTests {

    private let tmpDir: String
    private let publicDir: String
    let app: Application

    /// A notebook whose one code cell has been run: an output, a count and a
    /// timing record.
    private static let ranNotebook = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[{"cell_type":"code","execution_count":7,\
        "metadata":{"execution":{"iopub.status.idle":"2026-11-01T00:00:00Z"}},\
        "outputs":[{"output_type":"stream","name":"stdout","text":["AUTHOR_RESULT\\n"]}],"source":["print(1)"]}]}
        """

    init() async throws {
        let tmpRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-starter-outputs-\(UUID().uuidString)")
            .path + "/"
        var publicDir = ""

        // A working directory of its own, as `NotebookWebRoutesTests` has,
        // because the editor save writes the author's working copy under
        // `Public/jupyterlite/files/`.
        self.app = try await makeTestingApplication { app in
            app.directory = DirectoryConfiguration(workingDirectory: tmpRoot)
            publicDir = app.directory.publicDirectory
            app.appConfig = AppConfig.testDefaults()
            try FileManager.default.createDirectory(atPath: tmpRoot, withIntermediateDirectories: true)
            app.testDataDirectory = tmpRoot
            try FileManager.default.createSymbolicLink(
                atPath: tmpRoot + "Resources",
                withDestinationPath: repositoryRoot.appendingPathComponent("Resources").path)
            try FileManager.default.createDirectory(atPath: publicDir, withIntermediateDirectories: true)
            let dirs = ["results/", "testsetups/", "submissions/"].map { tmpRoot + $0 }
            for dir in dirs {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            app.resultsDirectory = dirs[0]
            app.testSetupsDirectory = dirs[1]
            app.submissionsDirectory = dirs[2]
            app.sessions.use(.memory)
            app.middleware.use(app.sessions.middleware)
            try await configureTestDatabase(app)
            app.middleware.use(AssignmentVersionCaptureMiddleware())
            app.lifecycle.use(DataExportDrainLifecycleHandler())
            app.kernelEnvironments = KernelEnvironments.load(publicDirectory: app.directory.publicDirectory)
            try routes(app)
        }
        self.tmpDir = tmpRoot
        self.publicDir = publicDir
    }

    private func course() async throws -> APICourse {
        if let existing = try await APICourse.query(on: app.db).filter(\.$code == "OUT101").first() {
            return existing
        }
        return try await makeTestCourse(on: app, code: "OUT101", name: "Outputs")
    }

    /// A setup whose flat notebook and zip both hold `notebookJSON`, or only
    /// the zip when `flatFile` is false.
    @discardableResult
    private func insertSetup(id: String, notebookJSON: String, flatFile: Bool = true) async throws -> APITestSetup {
        let zipPath = tmpDir + "testsetups/\(id).zip"
        let notebookPath = tmpDir + "testsetups/\(id).ipynb"
        try await writeZipFixture(at: zipPath, entries: [("assignment.ipynb", notebookJSON)])
        if flatFile {
            try Data(notebookJSON.utf8).write(to: URL(fileURLWithPath: notebookPath))
        }
        let setup = APITestSetup(
            id: id,
            manifest:
                #"{"schemaVersion":1,"gradingMode":"browser","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,"makefile":null}"#,
            zipPath: zipPath,
            notebookPath: flatFile ? notebookPath : nil,
            courseID: try await course().requireID())
        try await setup.save(on: app.db)
        return setup
    }

    private func storedStarter(_ setupID: String) async throws -> String {
        let path = try #require(try await APITestSetup.find(setupID, on: app.db)?.notebookPath)
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func staffCookie(username: String) async throws -> (cookie: String, userID: UUID) {
        let cookie = try await loginUser(username: username, password: "testpassword", role: "instructor", on: app)
        let staff = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(
            userID: try staff.requireID(), courseID: try await course().requireID(), role: .instructor
        ).save(on: app.db)
        return (cookie, try staff.requireID())
    }

    @Test func editorSaveStoresTheStarterWithoutOutputsAndKeepsTheAuthorCopy() async throws {
        try await withApp(app) { _ in
            let (cookie, staffID) = try await staffCookie(username: "outputs_editor_save")
            let setupID = "setup_outputs_editor"
            try await insertSetup(
                id: setupID,
                notebookJSON:
                    #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#)
            _ = try await makeTestAssignment(
                on: app, testSetupID: setupID, courseID: try await course().requireID(), title: "Lab",
                isOpen: false)

            let (csrf, session) = try await csrfFields(for: "/account", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/testsetups/\(setupID)/notebook/save",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: session)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBufferAllocator().buffer(string: Self.ranNotebook)
                },
                afterResponse: { res in #expect(res.status == .ok) })

            let stored = try await storedStarter(setupID)
            #expect(stored.contains("AUTHOR_RESULT") == false)
            #expect(stored.contains("print(1)"))
            #expect(stored.contains("iopub.status.idle") == false)

            // The author keeps what they were looking at.
            let workingCopy = try String(
                contentsOfFile: publicDir + "jupyterlite/files/"
                    + userNotebookWorkingCopyRelativePath(setupID: setupID, userID: staffID),
                encoding: .utf8)
            #expect(workingCopy.contains("AUTHOR_RESULT"))
        }
    }

    @Test func theSharedAuthoringWriteClearsOutputs() async throws {
        // `writeAssignmentNotebook` is the write behind MCP `update_notebook`
        // and `create_assignment`, as well as the editor save.
        try await withApp(app) { _ in
            let setup = try await insertSetup(
                id: "setup_outputs_service",
                notebookJSON: #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#)
            try await AssignmentAuthoringService.writeAssignmentNotebook(
                setup: setup, notebookData: Data(Self.ranNotebook.utf8),
                setupsDirectory: app.testSetupsDirectory, on: app.db)
            #expect(try await storedStarter("setup_outputs_service").contains("AUTHOR_RESULT") == false)
        }
    }

    @Test func aStarterReadFromTheSetupZipIsServedWithoutOutputs() async throws {
        try await withApp(app) { _ in
            let setup = try await insertSetup(
                id: "setup_outputs_zip", notebookJSON: Self.ranNotebook, flatFile: false)
            let served = try await notebookData(for: setup)
            let text = try #require(String(bytes: served, encoding: .utf8))
            #expect(text.contains("AUTHOR_RESULT") == false)
        }
    }

    @Test func restoringAVersionTakenWithOutputsRestoresTheStarterWithout() async throws {
        try await withApp(app) { _ in
            let courseID = try await course().requireID()
            let user = try await makeTestUser(on: app, username: "outputs_restorer", role: "instructor")
            try await makeTestEnrollment(on: app, userID: user.requireID(), courseID: courseID)
            let setupID = "setup_outputs_restore"
            let setup = try await insertSetup(id: setupID, notebookJSON: Self.ranNotebook)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: setupID, courseID: courseID, title: "Restore Lab", isOpen: false)

            // A snapshot from before starters were cleared on save: it holds
            // the outputs. Then a later edit to restore away from.
            _ = try await AssignmentVersionStore.record(
                setup: setup, request: AssignmentVersionRequest(origin: AssignmentVersionOrigin.baseline),
                testSetupsDirectory: app.testSetupsDirectory, on: app.db)
            try Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.utf8)
                .write(to: URL(fileURLWithPath: try #require(setup.notebookPath)))
            _ = try await AssignmentVersionStore.record(
                setup: setup, request: AssignmentVersionRequest(origin: "mcp:update_notebook"),
                testSetupsDirectory: app.testSetupsDirectory, on: app.db)

            _ = try await RestoreAssignmentVersionTool().execute(
                RestoreAssignmentVersionTool.Input(assignmentPublicID: assignment.publicID, version: 1),
                mcpContext(app, subject: "outputs_restorer"))

            let restored = try await storedStarter(setupID)
            #expect(restored.contains("print(1)"))
            #expect(restored.contains("AUTHOR_RESULT") == false)
        }
    }

    @Test func theMigrationClearsStoredStartersAndLeavesCleanOnesUntouched() async throws {
        try await withApp(app) { _ in
            try await insertSetup(id: "setup_outputs_dirty", notebookJSON: Self.ranNotebook)
            let clean = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#
            try await insertSetup(id: "setup_outputs_clean", notebookJSON: clean)
            // A setup whose flat file is gone must not stop the migration.
            let missing = try await insertSetup(id: "setup_outputs_missing", notebookJSON: clean)
            try FileManager.default.removeItem(atPath: try #require(missing.notebookPath))

            try await StripStarterNotebookOutputs().prepare(on: app.db)

            let dirty = try await storedStarter("setup_outputs_dirty")
            #expect(dirty.contains("AUTHOR_RESULT") == false)
            #expect(dirty.contains("print(1)"))
            #expect(try await storedStarter("setup_outputs_clean") == clean)
        }
    }
}
