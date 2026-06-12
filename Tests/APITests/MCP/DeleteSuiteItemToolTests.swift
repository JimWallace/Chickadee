// Tests for DeleteSuiteItemTool (removing a script / family / check from a
// suite), backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct DeleteSuiteItemToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private let emptyManifest = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#

    /// Course + enrolled instructor + setup + assignment.  When `seedFamily` is
    /// true the BMI family is applied; `seedScript` adds a hand-written script.
    private func fixture(
        on app: Application, seedFamily: Bool = false, seedScript: String? = nil
    ) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        let setup = try await makeTestSetup(
            on: app, id: "setup_del", courseID: courseID, manifest: emptyManifest)
        try pfWriteEmptyZip(at: app.testSetupsDirectory + "setup_del.zip")
        var families: [PatternFamily] = []
        var authored: [AuthoredSuiteItem] = []
        if seedFamily {
            families.append(pfBMIFamily())
            authored.append(.family(id: "bmi_category", sectionID: nil))
        }
        if let name = seedScript {
            authored.append(
                .script(
                    AuthoredRawScript(
                        script: name, tier: .pub, points: 1, displayName: nil,
                        dependsOn: [], sectionID: nil,
                        content: "#!/usr/bin/env python3\nprint('ok')", hint: nil)))
        }
        if !authored.isEmpty {
            try await applyPatternFamilies(
                to: setup, nextFamilies: families, authoredItems: authored, on: app.db)
        }
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_del", courseID: courseID, title: "Lab")
    }

    private func reloadItems(_ assignment: APIAssignment, on db: Database) async throws -> [SuiteItemDTO] {
        let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: db))
        return buildSuitePayload(fromManifest: reloaded.manifest).items
    }

    @Test func deletesAHandWrittenScript() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, seedScript: "extra_test.py")
            #expect(try await reloadItems(assignment, on: app.db).contains { $0.script?.script == "extra_test.py" })

            let output = try await DeleteSuiteItemTool().execute(
                DeleteSuiteItemTool.Input(
                    assignmentPublicID: assignment.publicID, script: "extra_test.py",
                    familyID: nil, check: nil),
                context(app))
            #expect(output.kind == "script")
            #expect(output.removed == "extra_test.py")

            let items = try await reloadItems(assignment, on: app.db)
            #expect(!items.contains { $0.script?.script == "extra_test.py" })
        }
    }

    @Test func deletesAFamily() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, seedFamily: true)
            let output = try await DeleteSuiteItemTool().execute(
                DeleteSuiteItemTool.Input(
                    assignmentPublicID: assignment.publicID, script: nil,
                    familyID: "bmi_category", check: nil),
                context(app))
            #expect(output.kind == "family")
            #expect(output.removed == "bmi_category")

            let items = try await reloadItems(assignment, on: app.db)
            #expect(!items.contains { $0.family?.id == "bmi_category" })
        }
    }

    /// Removing a graded item closes a currently-open assignment so students
    /// can't submit against the not-yet-revalidated suite, and reports it.
    @Test func closesAnOpenAssignmentAndReportsIt() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, seedScript: "extra_test.py")
            #expect(assignment.visibility == .open)  // makeTestAssignment defaults isOpen: true

            let output = try await DeleteSuiteItemTool().execute(
                DeleteSuiteItemTool.Input(
                    assignmentPublicID: assignment.publicID, script: "extra_test.py",
                    familyID: nil, check: nil),
                context(app))
            #expect(output.assignmentClosed)

            let reloaded = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(reloaded.visibility == .closed)
        }
    }

    /// A suite edit auto-re-grades existing student submissions against the new
    /// suite (the automatic equivalent of the "Retest all" button).
    @Test func reGradesExistingSubmissions() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, seedScript: "extra_test.py")
            let student = try await makeTestUser(on: app, username: "stu", role: "student")
            try await makeTestSubmission(
                on: app, id: "sub_del", setupID: assignment.testSetupID,
                userID: try student.requireID(), status: "complete")

            _ = try await DeleteSuiteItemTool().execute(
                DeleteSuiteItemTool.Input(
                    assignmentPublicID: assignment.publicID, script: "extra_test.py",
                    familyID: nil, check: nil),
                context(app))

            let reloaded = try #require(try await APISubmission.find("sub_del", on: app.db))
            #expect(reloaded.status == "pending")
            // The dedup hash is stamped so a follow-up cosmetic save won't re-fan-out.
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(setup.lastRetestedManifestHash == manifestHash(setup.manifest))
        }
    }

    @Test func unknownScriptThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await DeleteSuiteItemTool().execute(
                    DeleteSuiteItemTool.Input(
                        assignmentPublicID: assignment.publicID, script: "nope.py",
                        familyID: nil, check: nil),
                    context(app))
            }
        }
    }

    @Test func noTargetThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await DeleteSuiteItemTool().execute(
                    DeleteSuiteItemTool.Input(
                        assignmentPublicID: assignment.publicID, script: nil,
                        familyID: nil, check: nil),
                    context(app))
            }
        }
    }

    @Test func multipleTargetsThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, seedScript: "extra_test.py")
            await #expect(throws: MCPToolError.self) {
                _ = try await DeleteSuiteItemTool().execute(
                    DeleteSuiteItemTool.Input(
                        assignmentPublicID: assignment.publicID, script: "extra_test.py",
                        familyID: "bmi_category", check: nil),
                    context(app))
            }
        }
    }

    @Test func deniesWhenSubjectNotEnrolled() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            _ = try await makeTestUser(on: app, username: "tester", role: "instructor")
            _ = try await makeTestSetup(
                on: app, id: "setup_del", courseID: courseID, manifest: emptyManifest)
            try pfWriteEmptyZip(at: app.testSetupsDirectory + "setup_del.zip")
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_del", courseID: courseID, title: "Lab")
            await #expect(throws: MCPToolError.self) {
                _ = try await DeleteSuiteItemTool().execute(
                    DeleteSuiteItemTool.Input(
                        assignmentPublicID: assignment.publicID, script: "x.py",
                        familyID: nil, check: nil),
                    context(app))
            }
        }
    }
}
