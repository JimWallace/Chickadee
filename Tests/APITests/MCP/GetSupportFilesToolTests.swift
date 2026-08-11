// Tests for GetSupportFilesTool: it lists/reads only the setup zip's support
// files (never graded scripts or the canonical notebooks), caps reads at
// maxBytes on a UTF-8 boundary, and rejects non-text files. Backed by a real
// test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct GetSupportFilesToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read]
        )
    }

    private let manifest = """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"public","script":"test_a.sh","points":1}\
        ],"timeLimitSeconds":10}
        """

    /// Course + enrolled instructor + setup whose zip holds one graded script,
    /// both canonical notebooks, and two support files (one nested).
    private func fixture(on app: Application) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_sf", courseID: courseID, manifest: manifest)
        try writeZip(
            at: app.testSetupsDirectory + "setup_sf.zip",
            entries: [
                ("test_a.sh", "exit 0\n"),
                ("assignment.ipynb", "{}"),
                ("solution.ipynb", "{}"),
                ("cases.csv", "caseid,age\n1,20\n2,30\n"),
                ("data/extra.txt", "nested support file\n"),
            ])
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_sf", courseID: courseID, title: "Lab")
    }

    private func writeZip(at zipPath: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-zip-\(UUID().uuidString)")
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

    private func run(
        _ app: Application, publicID: String, filename: String? = nil, maxBytes: Int? = nil
    ) async throws -> GetSupportFilesTool.Output {
        try await GetSupportFilesTool().execute(
            GetSupportFilesTool.Input(
                assignmentPublicID: publicID, filename: filename, maxBytes: maxBytes),
            context(app))
    }

    // MARK: - List mode

    @Test func listsOnlySupportFiles() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)

            let output = try await run(app, publicID: assignment.publicID)
            let files = try #require(output.files)
            let names = files.map(\.filename)
            #expect(names == ["cases.csv", "data/extra.txt"])  // sorted; scripts + notebooks excluded
            let csv = try #require(files.first { $0.filename == "cases.csv" })
            #expect(csv.sizeBytes == "caseid,age\n1,20\n2,30\n".utf8.count)
            #expect(output.content == nil)
        }
    }

    // MARK: - Read mode

    @Test func readsSupportFileContent() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)

            let output = try await run(app, publicID: assignment.publicID, filename: "cases.csv")
            #expect(output.content == "caseid,age\n1,20\n2,30\n")
            #expect(output.truncated == false)
            #expect(output.sizeBytes == "caseid,age\n1,20\n2,30\n".utf8.count)
            #expect(output.files == nil)
        }
    }

    @Test func readsNestedSupportFile() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)

            let output = try await run(
                app, publicID: assignment.publicID, filename: "data/extra.txt")
            #expect(output.content == "nested support file\n")
        }
    }

    @Test func capsContentAtMaxBytesOnUTF8Boundary() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            // "é" is 2 bytes in UTF-8; a 5-byte cap lands mid-character and
            // must back off to the previous boundary ("abcd", 4 bytes).
            try writeZip(
                at: app.testSetupsDirectory + "setup_sf.zip",
                entries: [("test_a.sh", "exit 0\n"), ("note.txt", "abcdé and more")])

            let output = try await run(
                app, publicID: assignment.publicID, filename: "note.txt", maxBytes: 5)
            #expect(output.content == "abcd")
            #expect(output.truncated == true)
            #expect(output.sizeBytes == "abcdé and more".utf8.count)
        }
    }

    // MARK: - Boundaries

    @Test func redirectsGradedScriptToGetSuite() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await self.run(app, publicID: assignment.publicID, filename: "test_a.sh")
            }
        }
    }

    @Test func redirectsNotebookToDedicatedTool() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await self.run(
                    app, publicID: assignment.publicID, filename: "solution.ipynb")
            }
        }
    }

    @Test func unknownFilenameThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await self.run(app, publicID: assignment.publicID, filename: "missing.csv")
            }
            // A traversal-shaped name is just "not in the entry list".
            await #expect(throws: MCPToolError.self) {
                _ = try await self.run(
                    app, publicID: assignment.publicID, filename: "../../etc/passwd")
            }
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestSetup(on: app, id: "setup_sf", courseID: courseID, manifest: manifest)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_sf", courseID: courseID, title: "Lab")

            await #expect(throws: MCPToolError.self) {
                _ = try await self.run(app, publicID: assignment.publicID)
            }
        }
    }
}
