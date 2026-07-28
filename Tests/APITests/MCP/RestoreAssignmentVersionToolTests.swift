// Tests for restore_assignment_version — the recovery half of assignment
// content versioning (docs/assignment-versioning.md), backed by a real test
// database.
//
// `.serialized`: these repack zips, which spawn subprocesses and hit the
// Foundation posix_spawn EFAULT race under within-suite parallelism.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) final class RestoreAssignmentVersionToolTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-vrestore")
    }

    // MARK: - Fixtures

    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "vr_inst",
            grantedScopes: [.read, .write])
    }

    private func manifest(timeLimit: Int) -> String {
        """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"public","script":"test_a.sh","points":1}\
        ],"timeLimitSeconds":\(timeLimit)}
        """
    }

    private func fixture(
        on app: Application, scripts: [(String, String)] = [("test_a.sh", "exit 0\n")]
    ) async throws -> (assignment: APIAssignment, setup: APITestSetup) {
        let course = try await makeTestCourse(on: app, code: "VR", name: "Restore")
        let courseID = try course.requireID()
        let user = try await makeTestUser(on: app, username: "vr_inst", role: "instructor")
        try await makeTestEnrollment(on: app, userID: user.requireID(), courseID: courseID)

        let setupID = "vr_setup"
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: manifest(timeLimit: 10))
        try writeZip(
            at: app.testSetupsDirectory + setupID + ".zip",
            entries: [(".placeholder", "x")] + scripts)
        let notebookPath = app.testSetupsDirectory + setupID + ".ipynb"
        try Data("{\"cells\":[],\"nbformat\":4}".utf8).write(to: URL(fileURLWithPath: notebookPath))

        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "VR Lab")
        let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
        setup.notebookPath = notebookPath
        try await setup.save(on: app.db)
        return (assignment, setup)
    }

    private func writeZip(at zipPath: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vr-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, content) in entries {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.data(using: .utf8)?.write(to: url)
        }
        try? FileManager.default.removeItem(atPath: zipPath)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-r", zipPath, "."]
        zip.standardOutput = Pipe()
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
    }

    private func record(_ app: Application, _ setup: APITestSetup, origin: String) async throws {
        _ = try await AssignmentVersionStore.record(
            setup: setup,
            request: AssignmentVersionRequest(origin: origin),
            testSetupsDirectory: app.testSetupsDirectory,
            on: app.db)
    }

    private func entry(_ setup: APITestSetup, _ name: String) -> String {
        String(
            bytes: extractZipEntry(zipPath: setup.zipPath, entryName: name) ?? Data(),
            encoding: .utf8) ?? ""
    }

    private func restore(
        _ app: Application, _ assignment: APIAssignment, version: Int
    ) async throws -> RestoreAssignmentVersionTool.Output {
        try await RestoreAssignmentVersionTool().execute(
            RestoreAssignmentVersionTool.Input(
                assignmentPublicID: assignment.publicID, version: version),
            context(app))
    }

    // MARK: - The headline behaviour

    @Test func restoringPutsBackTheScriptAndTheManifest() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            // Break it.
            try writeZip(
                at: setup.zipPath,
                entries: [(".placeholder", "x"), ("test_a.sh", "exit 1  # broken\n")])
            setup.manifest = manifest(timeLimit: 999)
            try await setup.save(on: app.db)
            try await record(app, setup, origin: "mcp:author_script")

            let output = try await restore(app, assignment, version: 1)

            #expect(output.restoredFromVersion == 1)
            #expect(output.newVersion == 3)
            #expect(output.alreadyCurrent == false)
            #expect(output.filesRestored == 2)

            let live = try #require(try await APITestSetup.find(setup.id ?? "", on: app.db))
            #expect(entry(live, "test_a.sh") == "exit 0\n")
            #expect(live.manifest == manifest(timeLimit: 10))
        }
    }

    /// History is append-only: the restore adds a version rather than rewinding
    /// the counter, and the version it replaced is still there to go back to.
    @Test func restoringAppendsRatherThanRewinding() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)
            try writeZip(
                at: setup.zipPath, entries: [(".placeholder", "x"), ("test_a.sh", "exit 1\n")])
            try await record(app, setup, origin: "mcp:author_script")

            _ = try await restore(app, assignment, version: 1)

            let history = try await APIAssignmentVersion.query(on: app.db)
                .filter(\.$testSetupID == (setup.id ?? ""))
                .sort(\.$versionNumber)
                .all()
            #expect(history.map(\.versionNumber) == [1, 2, 3])
            let restored = try #require(history.last)
            #expect(restored.origin == "restore:1")
            #expect(restored.restoredFromVersion == 1)
            #expect(restored.actorUsername == "vr_inst")
            // The version that was replaced is intact and still restorable.
            #expect(history[1].origin == "mcp:author_script")
        }
    }

    /// A restore that deletes a file must actually delete it. `zip -r` ADDS to
    /// an existing archive, so a repack in place would leave the removed script
    /// in the suite and silently keep grading it.
    @Test func restoringRemovesFilesAddedAfterTheTargetVersion() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            try writeZip(
                at: setup.zipPath,
                entries: [
                    (".placeholder", "x"), ("test_a.sh", "exit 0\n"), ("test_extra.sh", "exit 0\n"),
                ])
            try await record(app, setup, origin: "mcp:author_script")

            _ = try await restore(app, assignment, version: 1)

            let live = try #require(try await APITestSetup.find(setup.id ?? "", on: app.db))
            let names = listZipEntries(zipPath: live.zipPath)
            #expect(!names.contains("test_extra.sh"))
            #expect(names.contains("test_a.sh"))
        }
    }

    @Test func restoringPutsBackTheStarterNotebook() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            let path = try #require(setup.notebookPath)
            try Data("{\"cells\":[{\"cell_type\":\"code\"}],\"nbformat\":4}".utf8)
                .write(to: URL(fileURLWithPath: path))
            try await record(app, setup, origin: "mcp:update_notebook")

            let output = try await restore(app, assignment, version: 1)
            #expect(output.notebookRestored == true)

            let restored = FileManager.default.contents(atPath: path)
            #expect(String(bytes: restored ?? Data(), encoding: .utf8) == "{\"cells\":[],\"nbformat\":4}")
        }
    }

    // MARK: - Content only

    /// A restore must never reopen an assignment or move a deadline: recovery
    /// is a content action, and metadata is what students have already seen.
    @Test func restoringLeavesMetadataAloneAndClosesTheAssignment() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            assignment.title = "Renamed after v1"
            let due = Date(timeIntervalSince1970: 1_700_000_000)
            assignment.dueAt = due
            assignment.visibility = .open
            try await assignment.save(on: app.db)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            try writeZip(
                at: setup.zipPath, entries: [(".placeholder", "x"), ("test_a.sh", "exit 1\n")])
            try await record(app, setup, origin: "mcp:author_script")

            let output = try await restore(app, assignment, version: 1)

            let live = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(live.title == "Renamed after v1")
            #expect(live.dueAt == due)
            // Closed, like any content edit — students must not submit against
            // a not-yet-revalidated suite.
            #expect(live.visibility == .closed)
            #expect(output.assignmentClosed == true)
        }
    }

    // MARK: - No-ops and errors

    /// Restoring the version that already matches live content changes nothing
    /// and says so, rather than appending a duplicate version and re-grading
    /// every submission for no reason.
    @Test func restoringTheCurrentVersionIsReportedAsANoOp() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            let output = try await restore(app, assignment, version: 1)

            #expect(output.alreadyCurrent == true)
            #expect(output.assignmentClosed == false)
            #expect(output.submissionsRequeued == 0)
            let count = try await APIAssignmentVersion.query(on: app.db)
                .filter(\.$testSetupID == (setup.id ?? ""))
                .count()
            #expect(count == 1)
        }
    }

    @Test func restoringAnUnknownVersionReportsTheAvailableRange() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            do {
                _ = try await restore(app, assignment, version: 42)
                Issue.record("expected a thrown error for an unknown version")
            } catch let error as MCPToolError {
                guard case .invalidArguments(let tool, let detail) = error else {
                    Issue.record("expected invalidArguments, got \(error)")
                    return
                }
                #expect(tool == RestoreAssignmentVersionTool.name)
                #expect(detail.contains("Versions 1-1 exist"))
            }
        }
    }

    // MARK: - Authorization

    /// Restore re-grades every submission on the setup, so it is an
    /// instructor-level action — a TA who may author content may not roll it
    /// back wholesale.
    @Test func aTAMayNotRestore() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            let ta = try await makeTestUser(on: app, username: "vr_ta", role: "user")
            // Enrolled at the TA rung directly: content authoring is TA+, but
            // restoring is not.
            let enrollment = APICourseEnrollment(
                userID: try ta.requireID(), courseID: assignment.courseID, role: .ta)
            try await enrollment.save(on: app.db)

            let taContext = ToolContext(
                request: Request(application: app, on: app.eventLoopGroup.any()),
                subject: "vr_ta",
                grantedScopes: [.read, .write])

            await #expect(throws: MCPToolError.self) {
                _ = try await RestoreAssignmentVersionTool().execute(
                    RestoreAssignmentVersionTool.Input(
                        assignmentPublicID: assignment.publicID, version: 1),
                    taContext)
            }
        }
    }
}

/// Catalog-shape checks. A struct suite: it owns no Vapor app.
@Suite struct RestoreAssignmentVersionCatalogTests {
    @Test func theToolIsRegisteredAsADestructiveWrite() {
        #expect(RestoreAssignmentVersionTool.requiredScopes == [.write])
        #expect(RestoreAssignmentVersionTool.annotations?.readOnlyHint == false)
        #expect(RestoreAssignmentVersionTool.annotations?.destructiveHint == true)
        let names = MCPToolCatalog.live.all.map(\.name)
        #expect(names.contains(RestoreAssignmentVersionTool.name))
    }

    /// The description has to state the two consequences a caller cannot see
    /// coming: the re-grade, and that metadata is deliberately not restored.
    @Test func theDescriptionStatesItsSideEffects() {
        let description = RestoreAssignmentVersionTool.description
        #expect(description.contains("RE-GRADES"))
        #expect(description.contains("CONTENT ONLY"))
        #expect(description.contains("append-only"))
    }
}
