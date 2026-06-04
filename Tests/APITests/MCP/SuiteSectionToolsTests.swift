// Tests for the test-suite section MCP tools — create_section / rename_section
// / delete_section (lightweight manifest mutations) and move_suite_item (which
// reorders the suite through the validated applySuiteEdit path). Backed by a
// real test database + on-disk setup zip, mirroring UpdateSuiteToolTests.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct SuiteSectionToolsTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private let manifest = """
        {"schemaVersion":1,"testSuites":[\
        {"tier":"public","script":"test_a.sh","points":1},\
        {"tier":"public","script":"test_b.sh","points":1}\
        ],"timeLimitSeconds":10}
        """

    /// Course + enrolled instructor + setup (with a real zip holding the two
    /// scripts so applySuiteEdit can rebuild it) + assignment.
    private func fixture(on app: Application) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_ss", courseID: courseID, manifest: manifest)
        try writeZip(
            at: app.testSetupsDirectory + "setup_ss.zip",
            entries: [(".placeholder", "x"), ("test_a.sh", "exit 0\n"), ("test_b.sh", "exit 0\n")])
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_ss", courseID: courseID, title: "Lab")
    }

    private func writeZip(at zipPath: String, entries: [(String, String)]) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ss-zip-\(UUID().uuidString)")
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
    }

    private func sections(
        of assignment: APIAssignment, on app: Application
    ) async throws
        -> [TestSuiteSectionDTO]
    {
        let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
        return buildSuitePayload(fromManifest: reloaded.manifest).sections
    }

    private func items(of assignment: APIAssignment, on app: Application) async throws -> [SuiteItemDTO] {
        let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
        return buildSuitePayload(fromManifest: reloaded.manifest).items
    }

    // MARK: - create / rename / delete

    @Test func createSectionAddsNamedSection() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let out = try await CreateSectionTool().execute(
                .init(assignmentPublicID: assignment.publicID, name: "Question 1"), context(app))
            #expect(!out.sectionID.isEmpty)
            #expect(out.name == "Question 1")

            let secs = try await sections(of: assignment, on: app)
            #expect(secs.contains { $0.id == out.sectionID && $0.name == "Question 1" })
            // Creating a section does not close the assignment (display-only).
            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.isOpen)
        }
    }

    @Test func createSectionRejectsEmptyName() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreateSectionTool().execute(
                    .init(assignmentPublicID: assignment.publicID, name: "   "), context(app))
            }
        }
    }

    @Test func renameSectionChangesName() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let created = try await CreateSectionTool().execute(
                .init(assignmentPublicID: assignment.publicID, name: "Old"), context(app))
            _ = try await RenameSectionTool().execute(
                .init(assignmentPublicID: assignment.publicID, sectionID: created.sectionID, name: "New"),
                context(app))
            let secs = try await sections(of: assignment, on: app)
            #expect(secs.first { $0.id == created.sectionID }?.name == "New")
        }
    }

    @Test func renameUnknownSectionThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await RenameSectionTool().execute(
                    .init(assignmentPublicID: assignment.publicID, sectionID: "no-such-id", name: "X"),
                    context(app))
            }
        }
    }

    @Test func deleteSectionUngroupsItsItems() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let created = try await CreateSectionTool().execute(
                .init(assignmentPublicID: assignment.publicID, name: "Q1"), context(app))
            _ = try await MoveSuiteItemTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID, script: "test_a.sh", familyID: nil,
                    check: nil, sectionID: created.sectionID), context(app))

            let out = try await DeleteSectionTool().execute(
                .init(assignmentPublicID: assignment.publicID, sectionID: created.sectionID), context(app))
            #expect(out.removed)
            #expect(out.ungroupedItemCount == 1)

            let secs = try await sections(of: assignment, on: app)
            #expect(!secs.contains { $0.id == created.sectionID })
            // The item survives, now ungrouped.
            let a = try #require(try await items(of: assignment, on: app).first { $0.script?.script == "test_a.sh" })
            #expect(a.sectionID == nil)
        }
    }

    @Test func deleteUnknownSectionIsIdempotentNoOp() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let out = try await DeleteSectionTool().execute(
                .init(assignmentPublicID: assignment.publicID, sectionID: "no-such-id"), context(app))
            #expect(!out.removed)
            #expect(out.ungroupedItemCount == 0)
        }
    }

    // MARK: - move_suite_item

    @Test func moveScriptIntoSection() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let created = try await CreateSectionTool().execute(
                .init(assignmentPublicID: assignment.publicID, name: "Q1"), context(app))
            let out = try await MoveSuiteItemTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID, script: "test_b.sh", familyID: nil,
                    check: nil, sectionID: created.sectionID), context(app))
            #expect(out.kind == "script")
            #expect(out.item == "test_b.sh")
            #expect(out.sectionID == created.sectionID)

            let b = try #require(try await items(of: assignment, on: app).first { $0.script?.script == "test_b.sh" })
            #expect(b.sectionID == created.sectionID)
        }
    }

    @Test func moveToUnknownSectionThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await MoveSuiteItemTool().execute(
                    .init(
                        assignmentPublicID: assignment.publicID, script: "test_a.sh", familyID: nil,
                        check: nil, sectionID: "no-such-id"), context(app))
            }
        }
    }

    @Test func moveRequiresExactlyOneIdentifier() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let created = try await CreateSectionTool().execute(
                .init(assignmentPublicID: assignment.publicID, name: "Q1"), context(app))
            // Zero identifiers.
            await #expect(throws: MCPToolError.self) {
                _ = try await MoveSuiteItemTool().execute(
                    .init(
                        assignmentPublicID: assignment.publicID, script: nil, familyID: nil,
                        check: nil, sectionID: created.sectionID), context(app))
            }
            // Two identifiers.
            await #expect(throws: MCPToolError.self) {
                _ = try await MoveSuiteItemTool().execute(
                    .init(
                        assignmentPublicID: assignment.publicID, script: "test_a.sh", familyID: "x",
                        check: nil, sectionID: created.sectionID), context(app))
            }
        }
    }

    @Test func moveUngroupsWithEmptySection() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let created = try await CreateSectionTool().execute(
                .init(assignmentPublicID: assignment.publicID, name: "Q1"), context(app))
            _ = try await MoveSuiteItemTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID, script: "test_a.sh", familyID: nil,
                    check: nil, sectionID: created.sectionID), context(app))
            // Now ungroup it.
            let out = try await MoveSuiteItemTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID, script: "test_a.sh", familyID: nil,
                    check: nil, sectionID: ""), context(app))
            #expect(out.sectionID.isEmpty)
            let a = try #require(try await items(of: assignment, on: app).first { $0.script?.script == "test_a.sh" })
            #expect(a.sectionID == nil)
        }
    }

    @Test func movePatternFamilyIntoSection() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            // Create a pattern family (update_suite cannot move these — this is
            // the gap move_suite_item fills). Decode the Input from JSON, the
            // same shape the dispatcher feeds the tool.
            let famJSON = """
                {"assignmentPublicID":"\(assignment.publicID)","id":"fam1","name":"fam1 cases",\
                "kind":"boundary_equality","function":"foo","paramNames":["x"],\
                "defaultTier":"public","defaultPoints":1,\
                "cases":[{"key":"01","label":"c1","args":[1],"expected":1}]}
                """
            let famInput = try JSONDecoder().decode(
                CreatePatternFamilyTool.Input.self, from: Data(famJSON.utf8))
            _ = try await CreatePatternFamilyTool().execute(famInput, context(app))
            let created = try await CreateSectionTool().execute(
                .init(assignmentPublicID: assignment.publicID, name: "Q2"), context(app))

            let out = try await MoveSuiteItemTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID, script: nil, familyID: "fam1",
                    check: nil, sectionID: created.sectionID), context(app))
            #expect(out.kind == "family")
            #expect(out.item == "fam1")
            #expect(out.sectionID == created.sectionID)

            let fam = try #require(try await items(of: assignment, on: app).first { $0.family?.id == "fam1" })
            #expect(fam.sectionID == created.sectionID)
        }
    }
}
