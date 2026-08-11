// Tests for the assignment content-version read tools
// (list_assignment_versions / get_assignment_version), backed by a real test
// database. See docs/assignment-versioning.md.
//
// `.serialized`: these build snapshots, which spawn zip/unzip subprocesses and
// hit the Foundation posix_spawn EFAULT race under within-suite parallelism.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) final class AssignmentVersionToolsTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-vtools")
    }

    // MARK: - Fixtures

    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "vt_inst",
            grantedScopes: [.read, .write])
    }

    private func manifest(timeLimit: Int) -> String {
        """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"public","script":"test_a.sh","points":1}\
        ],"timeLimitSeconds":\(timeLimit)}
        """
    }

    /// A published assignment with a real zip, plus an enrolled instructor the
    /// tool context resolves to.
    private func fixture(
        on app: Application, scripts: [(String, String)] = [("test_a.sh", "exit 0\n")]
    ) async throws -> (assignment: APIAssignment, setup: APITestSetup) {
        let course = try await makeTestCourse(on: app, code: "VT", name: "Version Tools")
        let courseID = try course.requireID()
        let user = try await makeTestUser(on: app, username: "vt_inst", role: "instructor")
        try await makeTestEnrollment(on: app, userID: user.requireID(), courseID: courseID)

        let setupID = "vt_setup"
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: manifest(timeLimit: 10))
        try writeZip(
            at: app.testSetupsDirectory + setupID + ".zip",
            entries: [(".placeholder", "x")] + scripts)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "VT Lab")
        let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
        return (assignment, setup)
    }

    private func writeZip(at zipPath: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vt-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, content) in entries {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.data(using: .utf8)?.write(to: url)
        }
        try? FileManager.default.removeItem(atPath: zipPath)
        try writeZipFixture(of: root, to: zipPath)
    }

    private func record(
        _ app: Application, _ setup: APITestSetup, origin: String, summary: String? = nil
    ) async throws {
        _ = try await AssignmentVersionStore.record(
            setup: setup,
            request: AssignmentVersionRequest(origin: origin, summary: summary),
            testSetupsDirectory: app.testSetupsDirectory,
            on: app.db)
    }

    // MARK: - list_assignment_versions

    @Test func listReturnsHistoryNewestFirst() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            setup.manifest = manifest(timeLimit: 30)
            try await setup.save(on: app.db)
            try await record(
                app, setup, origin: "mcp:set_time_limit", summary: "time limit 10 -> 30")

            let output = try await ListAssignmentVersionsTool().execute(
                ListAssignmentVersionsTool.Input(
                    assignmentPublicID: assignment.publicID, limit: nil, beforeVersion: nil),
                context(app))

            #expect(output.totalVersions == 2)
            #expect(output.versions.map(\.version) == [2, 1])
            #expect(output.versions.first?.origin == "mcp:set_time_limit")
            #expect(output.versions.first?.summary == "time limit 10 -> 30")
            #expect(output.versions.last?.origin == AssignmentVersionOrigin.baseline)
            #expect(output.versions.first?.fileCount == 2)
            #expect(output.versions.first?.createdAt.isEmpty == false)
        }
    }

    /// `isCurrent` marks the version whose content matches the live assignment,
    /// so an agent can tell at a glance whether the newest snapshot is what
    /// students would actually get.
    @Test func theNewestMatchingVersionIsMarkedCurrent() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            let output = try await ListAssignmentVersionsTool().execute(
                ListAssignmentVersionsTool.Input(
                    assignmentPublicID: assignment.publicID, limit: nil, beforeVersion: nil),
                context(app))
            #expect(output.currentVersion == 1)
            #expect(output.versions.first?.isCurrent == true)
        }
    }

    /// Content edited outside a capture point leaves the newest version stale.
    /// Reporting that honestly beats assuming max() is current — an agent that
    /// trusted a stale "current" would restore over live content believing it
    /// was a no-op.
    @Test func aStaleNewestVersionIsNotMarkedCurrent() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            setup.manifest = manifest(timeLimit: 99)
            try await setup.save(on: app.db)

            let output = try await ListAssignmentVersionsTool().execute(
                ListAssignmentVersionsTool.Input(
                    assignmentPublicID: assignment.publicID, limit: nil, beforeVersion: nil),
                context(app))
            #expect(output.currentVersion == nil)
            #expect(output.versions.first?.isCurrent == false)
        }
    }

    @Test func listPagesWithLimitAndBeforeVersion() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            for step in 1...4 {
                setup.manifest = manifest(timeLimit: step * 10)
                try await setup.save(on: app.db)
                try await record(app, setup, origin: "mcp:set_time_limit")
            }

            let page = try await ListAssignmentVersionsTool().execute(
                ListAssignmentVersionsTool.Input(
                    assignmentPublicID: assignment.publicID, limit: 2, beforeVersion: nil),
                context(app))
            #expect(page.versions.map(\.version) == [4, 3])
            #expect(page.totalVersions == 4)

            let next = try await ListAssignmentVersionsTool().execute(
                ListAssignmentVersionsTool.Input(
                    assignmentPublicID: assignment.publicID, limit: 2, beforeVersion: 3),
                context(app))
            #expect(next.versions.map(\.version) == [2, 1])
        }
    }

    @Test func listOfAnAssignmentWithNoHistoryIsEmptyNotAnError() async throws {
        try await withApp(app) { app in
            let (assignment, _) = try await fixture(on: app)
            let output = try await ListAssignmentVersionsTool().execute(
                ListAssignmentVersionsTool.Input(
                    assignmentPublicID: assignment.publicID, limit: nil, beforeVersion: nil),
                context(app))
            #expect(output.versions.isEmpty)
            #expect(output.totalVersions == 0)
            #expect(output.currentVersion == nil)
        }
    }

    // MARK: - get_assignment_version

    @Test func getReturnsTheVersionsManifestAndFileList() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            let output = try await GetAssignmentVersionTool().execute(
                GetAssignmentVersionTool.Input(
                    assignmentPublicID: assignment.publicID, version: 1, path: nil, maxBytes: nil),
                context(app))

            #expect(output.version == 1)
            #expect(output.origin == AssignmentVersionOrigin.baseline)
            #expect(output.manifest == manifest(timeLimit: 10))
            #expect(output.files.map(\.path).sorted() == [".placeholder", "test_a.sh"])
            #expect(output.content == nil)
            #expect((output.files.first { $0.path == "test_a.sh" }?.sizeBytes ?? 0) > 0)
        }
    }

    /// The headline read: what a script used to say, without touching the live
    /// assignment.
    @Test func getReturnsAPastFilesBodyAndLeavesTheLiveSetupAlone() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            // Break the script, and record that too.
            try writeZip(
                at: setup.zipPath,
                entries: [(".placeholder", "x"), ("test_a.sh", "exit 1  # broken\n")])
            try await record(app, setup, origin: "mcp:author_script")

            let output = try await GetAssignmentVersionTool().execute(
                GetAssignmentVersionTool.Input(
                    assignmentPublicID: assignment.publicID, version: 1, path: "test_a.sh",
                    maxBytes: nil),
                context(app))

            #expect(output.content == "exit 0\n")
            #expect(output.truncated == false)
            // The live zip still holds the broken script — reading is not
            // restoring.
            let live = extractZipEntry(zipPath: setup.zipPath, entryName: "test_a.sh")
            #expect(String(bytes: live ?? Data(), encoding: .utf8)?.contains("broken") == true)
        }
    }

    /// `differsFromCurrent` is what makes a long file list readable: an agent
    /// hunting a bad edit needs to see which one file moved.
    @Test func filesAreMarkedAgainstCurrentContent() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(
                on: app, scripts: [("test_a.sh", "exit 0\n"), ("helper.py", "x = 1\n")])
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            try writeZip(
                at: setup.zipPath,
                entries: [
                    (".placeholder", "x"), ("test_a.sh", "exit 1\n"), ("helper.py", "x = 1\n"),
                ])

            let output = try await GetAssignmentVersionTool().execute(
                GetAssignmentVersionTool.Input(
                    assignmentPublicID: assignment.publicID, version: 1, path: nil, maxBytes: nil),
                context(app))

            let changed = output.files.first { $0.path == "test_a.sh" }
            let same = output.files.first { $0.path == "helper.py" }
            #expect(changed?.differsFromCurrent == true)
            #expect(same?.differsFromCurrent == false)
        }
    }

    @Test func getTruncatesALargeFileAtTheByteCap() async throws {
        try await withApp(app) { app in
            let body = String(repeating: "a", count: 5000) + "\n"
            let (assignment, setup) = try await fixture(
                on: app, scripts: [("big.py", body)])
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            let output = try await GetAssignmentVersionTool().execute(
                GetAssignmentVersionTool.Input(
                    assignmentPublicID: assignment.publicID, version: 1, path: "big.py",
                    maxBytes: 100),
                context(app))

            #expect(output.truncated == true)
            #expect(output.content?.count == 100)
        }
    }

    // MARK: - Errors

    /// An unknown version must say what IS available; an agent that guessed a
    /// number needs to correct itself without another round trip.
    @Test func anUnknownVersionReportsTheAvailableRange() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            await #expect(throws: MCPToolError.self) {
                _ = try await GetAssignmentVersionTool().execute(
                    GetAssignmentVersionTool.Input(
                        assignmentPublicID: assignment.publicID, version: 7, path: nil,
                        maxBytes: nil),
                    context(app))
            }

            do {
                _ = try await GetAssignmentVersionTool().execute(
                    GetAssignmentVersionTool.Input(
                        assignmentPublicID: assignment.publicID, version: 7, path: nil,
                        maxBytes: nil),
                    context(app))
            } catch let error as MCPToolError {
                guard case .invalidArguments(_, let detail) = error else {
                    Issue.record("expected invalidArguments, got \(error)")
                    return
                }
                #expect(detail.contains("Versions 1-1 exist"))
            }
        }
    }

    @Test func anUnknownPathListsWhatTheVersionHolds() async throws {
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app)
            try await record(app, setup, origin: AssignmentVersionOrigin.baseline)

            do {
                _ = try await GetAssignmentVersionTool().execute(
                    GetAssignmentVersionTool.Input(
                        assignmentPublicID: assignment.publicID, version: 1, path: "nope.py",
                        maxBytes: nil),
                    context(app))
                Issue.record("expected a thrown error for an unknown path")
            } catch let error as MCPToolError {
                guard case .invalidArguments(_, let detail) = error else {
                    Issue.record("expected invalidArguments, got \(error)")
                    return
                }
                #expect(detail.contains("test_a.sh"))
            }
        }
    }

}

/// Catalog-shape checks. A struct suite deliberately: it owns no Vapor app, so
/// it needs none of the class suite's `withApp` shutdown handling.
@Suite struct AssignmentVersionToolCatalogTests {
    @Test func bothToolsAreReadOnlyAndInTheCatalog() {
        #expect(ListAssignmentVersionsTool.requiredScopes == [.read])
        #expect(GetAssignmentVersionTool.requiredScopes == [.read])
        #expect(ListAssignmentVersionsTool.annotations?.readOnlyHint == true)
        #expect(GetAssignmentVersionTool.annotations?.readOnlyHint == true)
        let names = MCPToolCatalog.live.all.map(\.name)
        #expect(names.contains(ListAssignmentVersionsTool.name))
        #expect(names.contains(GetAssignmentVersionTool.name))
    }
}
