// Tests for DeleteSupportFileTool (removing a non-graded support/data file from
// a test setup), backed by a real test database.
//
// The tool is deliberately narrow — it must delete support files and refuse
// everything else — so most of these assert the refusals, which are what keep a
// caller from corrupting a setup through the wrong door.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct DeleteSupportFileToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private let emptyManifest = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#

    /// Course + enrolled instructor + setup + assignment, with `support` written
    /// into the zip as non-graded files and `seedScript` (if given) as a graded
    /// hand-written test.
    private func fixture(
        on app: Application, support: [String: String] = [:], seedScript: String? = nil,
        manifest: String? = nil
    ) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        let setup = try await makeTestSetup(
            on: app, id: "setup_sup", courseID: courseID, manifest: manifest ?? emptyManifest)
        let zipPath = app.testSetupsDirectory + "setup_sup.zip"
        try pfWriteEmptyZip(at: zipPath)
        for (name, body) in support.sorted(by: { $0.key < $1.key }) {
            try updateScriptInZip(zipPath: zipPath, filename: name, content: body)
        }
        if let name = seedScript {
            try await applyPatternFamilies(
                to: setup, nextFamilies: [],
                authoredItems: [
                    .script(
                        AuthoredRawScript(
                            script: name, tier: .pub, points: 1, displayName: nil,
                            dependsOn: [], sectionID: nil,
                            content: "#!/usr/bin/env python3\nprint('ok')", hint: nil))
                ], on: app.db)
        }
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_sup", courseID: courseID, title: "Lab")
    }

    private func entries(_ app: Application) -> [String] {
        listZipEntries(zipPath: app.testSetupsDirectory + "setup_sup.zip")
    }

    private func run(
        _ app: Application, _ assignment: APIAssignment, _ filename: String
    ) async throws
        -> DeleteSupportFileTool.Output
    {
        try await DeleteSupportFileTool().execute(
            DeleteSupportFileTool.Input(
                assignmentPublicID: assignment.publicID, filename: filename),
            context(app))
    }

    @Test func removesASupportFileFromTheZip() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(
                on: app, support: ["helpers.R": "f <- function() 1\n", "keep.R": "g <- function() 2\n"])
            #expect(entries(app).contains("helpers.R"))

            let output = try await run(app, assignment, "helpers.R")
            #expect(output.removed == "helpers.R")
            #expect(!output.clearedManifestMarks)

            #expect(!entries(app).contains("helpers.R"))
            #expect(entries(app).contains("keep.R"), "an unrelated support file must survive")
        }
    }

    /// A graded test is owned by delete_suite_item; tearing the file out from
    /// under its manifest entry would leave a suite row pointing at nothing.
    @Test func refusesAGradedTest() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, seedScript: "publictest_thing.py")
            await #expect(throws: MCPToolError.self) {
                try await run(app, assignment, "publictest_thing.py")
            }
            #expect(entries(app).contains("publictest_thing.py"), "the graded test must survive")
        }
    }

    @Test func refusesReservedSetupMembers() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(
                on: app,
                support: [
                    "test.properties.json": "{}", "assignment.ipynb": "{}", "solution.ipynb": "{}",
                ])
            for reserved in ["test.properties.json", "assignment.ipynb", "solution.ipynb"] {
                await #expect(throws: MCPToolError.self) {
                    try await run(app, assignment, reserved)
                }
                #expect(entries(app).contains(reserved))
            }
        }
    }

    @Test func refusesAnUnknownFilename() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, support: ["helpers.R": "x <- 1\n"])
            await #expect(throws: MCPToolError.self) {
                try await run(app, assignment, "nope.R")
            }
        }
    }

    @Test func refusesAPathSeparator() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, support: ["helpers.R": "x <- 1\n"])
            await #expect(throws: MCPToolError.self) {
                try await run(app, assignment, "../helpers.R")
            }
            #expect(entries(app).contains("helpers.R"))
        }
    }

    /// A graderOnly mark naming the deleted file must go with it, so a later
    /// file reusing the name doesn't silently inherit "withhold from students".
    @Test func clearsAGraderOnlyMark() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let manifest = #"""
                {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,\#
                "graderOnlyFiles":["answers.R","other.R"]}
                """#
            let assignment = try await fixture(
                on: app, support: ["answers.R": "key <- 1\n"], manifest: manifest)

            let output = try await run(app, assignment, "answers.R")
            #expect(output.clearedManifestMarks)

            let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            let props = try #require(reloaded.decodedManifest())
            #expect(!props.graderOnlyFileSet.contains("answers.R"))
            #expect(props.graderOnlyFileSet.contains("other.R"), "unrelated marks must survive")
        }
    }

    /// Removing a support file closes a currently-open assignment so students
    /// can't submit against the not-yet-revalidated setup, and reports it.
    @Test func closesAnOpenAssignmentAndReportsIt() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, support: ["helpers.R": "x <- 1\n"])
            #expect(assignment.visibility == .open)  // makeTestAssignment defaults isOpen: true

            let output = try await run(app, assignment, "helpers.R")
            #expect(output.assignmentClosed)

            let reloaded = try #require(
                try await APIAssignment.find(assignment.requireID(), on: app.db))
            #expect(reloaded.visibility != .open)
        }
    }

    /// The reported count uses get_support_files' own predicate, so it matches
    /// the list a caller reads next. The fixture zip also carries a
    /// `.placeholder` entry (an empty zip is invalid), which is a support file
    /// by that predicate — hence b.R, c.R, .placeholder.
    @Test func reportsTheRemainingSupportFileCount() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(
                on: app, support: ["a.R": "1\n", "b.R": "2\n", "c.R": "3\n"])
            let output = try await run(app, assignment, "a.R")

            let listed = entries(app).filter { !GetSupportFilesTool.reservedNames.contains($0) }
            #expect(output.remainingSupportFileCount == listed.count)
            #expect(listed.sorted() == [".placeholder", "b.R", "c.R"])
        }
    }
}
