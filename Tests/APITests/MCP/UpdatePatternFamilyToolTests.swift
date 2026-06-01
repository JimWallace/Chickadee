// Tests for UpdatePatternFamilyTool (pattern-family metadata edits: defaults +
// case enable/disable), backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct UpdatePatternFamilyToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private let emptyManifest = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#

    /// Course + enrolled instructor + setup seeded with the BMI pattern family
    /// (three cases, all enabled) + assignment.  Returns the assignment.
    private func fixture(
        on app: Application, family: PatternFamily = pfBMIFamily()
    ) async throws
        -> APIAssignment
    {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        let setup = try await makeTestSetup(
            on: app, id: "setup_pf", courseID: courseID, manifest: emptyManifest)
        // The fixture's empty-bytes zip can't be rebuilt; replace it with a
        // valid (placeholder-only) archive so applyPatternFamilies can re-save.
        try pfWriteEmptyZip(at: app.testSetupsDirectory + "setup_pf.zip")
        try await applyPatternFamilies(
            to: setup, nextFamilies: [family],
            authoredItems: [.family(id: family.id, sectionID: nil)], on: app.db)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_pf", courseID: courseID, title: "Lab")
    }

    private func reloadFamily(
        _ assignment: APIAssignment, on db: Database
    ) async throws
        -> PatternFamily
    {
        let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: db))
        let items = buildSuitePayload(fromManifest: reloaded.manifest).items
        return try #require(items.compactMap(\.family).first { $0.id == "bmi_category" })
    }

    @Test func disablesACase() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await UpdatePatternFamilyTool().execute(
                UpdatePatternFamilyTool.Input(
                    assignmentPublicID: assignment.publicID, familyID: "bmi_category",
                    defaultTier: nil, defaultPoints: nil, enableCases: nil, disableCases: ["02"]),
                context(app))
            #expect(output.enabledCaseKeys == ["01", "03"])

            let family = try await reloadFamily(assignment, on: app.db)
            #expect(family.cases.first { $0.key == "02" }?.enabled == false)
            #expect(family.cases.first { $0.key == "01" }?.enabled == true)
        }
    }

    @Test func setsDefaultsTierAndPoints() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await UpdatePatternFamilyTool().execute(
                UpdatePatternFamilyTool.Input(
                    assignmentPublicID: assignment.publicID, familyID: "bmi_category",
                    defaultTier: "secret", defaultPoints: 4, enableCases: nil, disableCases: nil),
                context(app))
            #expect(output.defaultTier == "secret")
            #expect(output.defaultPoints == 4)

            let family = try await reloadFamily(assignment, on: app.db)
            #expect(family.defaults.tier == .secret)
            #expect(family.defaults.points == 4)
            // Cases (args/expected) are untouched.
            #expect(family.cases.count == 3)
            #expect(family.cases.first { $0.key == "01" }?.expected == .string("underweight"))
        }
    }

    @Test func editsCaseArgsAndExpected() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            // Use a non-integral double: an integral value (16.0) would round-trip
            // through the manifest JSON as the integer 16, an inherent JSON
            // normalization, not a faithfulness bug.
            let output = try await UpdatePatternFamilyTool().execute(
                UpdatePatternFamilyTool.Input(
                    assignmentPublicID: assignment.publicID, familyID: "bmi_category",
                    cases: [
                        UpdatePatternFamilyTool.CaseEdit(
                            key: "01", args: [.double(16.5)], expected: .string("severely underweight"))
                    ]),
                context(app))
            #expect(output.editedCaseKeys == ["01"])

            let family = try await reloadFamily(assignment, on: app.db)
            let edited = try #require(family.cases.first { $0.key == "01" })
            #expect(edited.args == [.double(16.5)])
            #expect(edited.expected == .string("severely underweight"))
            // Other cases untouched.
            #expect(family.cases.first { $0.key == "02" }?.expected == .string("normal"))
        }
    }

    @Test func wrongArgCountThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            // BMI family declares one parameter; two args must be rejected by
            // the kind validation that runs on save (mapped from Vapor Abort).
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdatePatternFamilyTool().execute(
                    UpdatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, familyID: "bmi_category",
                        cases: [
                            UpdatePatternFamilyTool.CaseEdit(
                                key: "01", args: [.double(1.0), .double(2.0)])
                        ]),
                    context(app))
            }
        }
    }

    @Test func unknownCaseKeyInCasesThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdatePatternFamilyTool().execute(
                    UpdatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, familyID: "bmi_category",
                        cases: [UpdatePatternFamilyTool.CaseEdit(key: "99", expected: .string("x"))]),
                    context(app))
            }
        }
    }

    @Test func argVarRefsLengthMismatchThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdatePatternFamilyTool().execute(
                    UpdatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, familyID: "bmi_category",
                        cases: [
                            UpdatePatternFamilyTool.CaseEdit(
                                key: "01", args: [.double(16.0)], argVarRefs: [nil, nil])
                        ]),
                    context(app))
            }
        }
    }

    @Test func duplicateCaseEditThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdatePatternFamilyTool().execute(
                    UpdatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, familyID: "bmi_category",
                        cases: [
                            UpdatePatternFamilyTool.CaseEdit(key: "01", expected: .string("a")),
                            UpdatePatternFamilyTool.CaseEdit(key: "01", expected: .string("b")),
                        ]),
                    context(app))
            }
        }
    }

    @Test func unknownFamilyThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdatePatternFamilyTool().execute(
                    UpdatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, familyID: "nope",
                        defaultTier: nil, defaultPoints: 2, enableCases: nil, disableCases: nil),
                    context(app))
            }
        }
    }

    @Test func unknownCaseKeyThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdatePatternFamilyTool().execute(
                    UpdatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, familyID: "bmi_category",
                        defaultTier: nil, defaultPoints: nil, enableCases: nil,
                        disableCases: ["99"]),
                    context(app))
            }
        }
    }

    @Test func invalidTierThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdatePatternFamilyTool().execute(
                    UpdatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, familyID: "bmi_category",
                        defaultTier: "bogus", defaultPoints: nil, enableCases: nil,
                        disableCases: nil),
                    context(app))
            }
        }
    }

    @Test func emptyChangeSetThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdatePatternFamilyTool().execute(
                    UpdatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, familyID: "bmi_category",
                        defaultTier: nil, defaultPoints: nil, enableCases: nil, disableCases: nil),
                    context(app))
            }
        }
    }

    @Test func overlappingEnableDisableThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdatePatternFamilyTool().execute(
                    UpdatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, familyID: "bmi_category",
                        defaultTier: nil, defaultPoints: nil, enableCases: ["01"],
                        disableCases: ["01"]),
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
            let setup = try await makeTestSetup(
                on: app, id: "setup_pf", courseID: courseID, manifest: emptyManifest)
            try pfWriteEmptyZip(at: app.testSetupsDirectory + "setup_pf.zip")
            try await applyPatternFamilies(
                to: setup, nextFamilies: [pfBMIFamily()],
                authoredItems: [.family(id: "bmi_category", sectionID: nil)], on: app.db)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_pf", courseID: courseID, title: "Lab")

            await #expect(throws: MCPToolError.self) {
                _ = try await UpdatePatternFamilyTool().execute(
                    UpdatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, familyID: "bmi_category",
                        defaultTier: nil, defaultPoints: 2, enableCases: nil, disableCases: nil),
                    context(app))
            }
        }
    }
}
