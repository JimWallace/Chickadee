// Tests for CreatePatternFamilyTool (creating a brand-new pattern family),
// backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct CreatePatternFamilyToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    private let emptyManifest = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#

    /// Course + enrolled instructor + setup with an EMPTY suite + assignment.
    /// Optionally seeds global `=` expressions so personalized cases can resolve.
    private func fixture(
        on app: Application, expressions: [PersonalizationExpression] = []
    ) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        let setup = try await makeTestSetup(
            on: app, id: "setup_pf", courseID: courseID, manifest: emptyManifest)
        try pfWriteEmptyZip(at: app.testSetupsDirectory + "setup_pf.zip")
        if !expressions.isEmpty {
            try await applyPatternFamilies(
                to: setup, nextFamilies: [], authoredItems: [],
                globalExpressions: expressions, on: app.db)
        }
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_pf", courseID: courseID, title: "Lab")
    }

    private func reloadFamily(
        _ assignment: APIAssignment, id: String, on db: Database
    ) async throws -> PatternFamily {
        let reloaded = try #require(try await APITestSetup.find(assignment.testSetupID, on: db))
        let items = buildSuitePayload(fromManifest: reloaded.manifest).items
        return try #require(items.compactMap(\.family).first { $0.id == id })
    }

    @Test func createsANewBoundaryFamily() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let output = try await CreatePatternFamilyTool().execute(
                CreatePatternFamilyTool.Input(
                    assignmentPublicID: assignment.publicID, id: "classify", name: "Classify",
                    kind: "boundary_equality", function: "classify", paramNames: ["x"],
                    defaultTier: "public", defaultPoints: 2, tolerance: nil, sectionID: nil,
                    dependsOn: nil, variables: nil,
                    cases: [
                        CreatePatternFamilyTool.CaseInput(
                            key: "01", label: "one", args: [.int(1)], expected: .string("one"),
                            argVarRefs: nil, argsProvided: nil, expectedVarRef: nil, points: nil,
                            tier: nil, enabled: nil)
                    ]),
                context(app))
            #expect(output.familyID == "classify")
            #expect(output.kind == "boundary_equality")
            #expect(output.caseKeys == ["01"])

            let family = try await reloadFamily(assignment, id: "classify", on: app.db)
            #expect(family.functionName == "classify")
            #expect(family.defaults.points == 2)
            #expect(family.cases.first?.expected == .string("one"))
            #expect(family.cases.first?.args == [.int(1)])
        }
    }

    @Test func createsPersonalizedBoundaryFamily() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(
                on: app,
                expressions: [PersonalizationExpression(name: "exp_val", expression: "seed % 5")])
            _ = try await CreatePatternFamilyTool().execute(
                CreatePatternFamilyTool.Input(
                    assignmentPublicID: assignment.publicID, id: "perstud", name: "Per Student",
                    kind: "boundary_equality", function: "f", paramNames: ["x"],
                    defaultTier: nil, defaultPoints: nil, tolerance: nil, sectionID: nil,
                    dependsOn: nil, variables: nil,
                    cases: [
                        CreatePatternFamilyTool.CaseInput(
                            key: "01", label: nil, args: [.int(0)], expected: nil,
                            argVarRefs: nil, argsProvided: nil, expectedVarRef: "exp_val",
                            points: nil, tier: nil, enabled: nil)
                    ]),
                context(app))
            let family = try await reloadFamily(assignment, id: "perstud", on: app.db)
            #expect(family.cases.first?.expectedVarRef == "exp_val")
        }
    }

    @Test func rejectsDuplicateFamilyID() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let make = {
                try await CreatePatternFamilyTool().execute(
                    CreatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, id: "dup", name: "Dup",
                        kind: "boundary_equality", function: "f", paramNames: ["x"],
                        defaultTier: nil, defaultPoints: nil, tolerance: nil, sectionID: nil,
                        dependsOn: nil, variables: nil,
                        cases: [
                            CreatePatternFamilyTool.CaseInput(
                                key: "01", label: nil, args: [.int(1)], expected: .int(1),
                                argVarRefs: nil, argsProvided: nil, expectedVarRef: nil,
                                points: nil, tier: nil, enabled: nil)
                        ]),
                    self.context(app))
            }
            _ = try await make()
            await #expect(throws: MCPToolError.self) { _ = try await make() }
        }
    }

    @Test func duplicateCaseKeyThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreatePatternFamilyTool().execute(
                    CreatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, id: "f", name: "F",
                        kind: "boundary_equality", function: "f", paramNames: ["x"],
                        defaultTier: nil, defaultPoints: nil, tolerance: nil, sectionID: nil,
                        dependsOn: nil, variables: nil,
                        cases: [
                            CreatePatternFamilyTool.CaseInput(
                                key: "01", label: nil, args: [.int(1)], expected: .int(1),
                                argVarRefs: nil, argsProvided: nil, expectedVarRef: nil,
                                points: nil, tier: nil, enabled: nil),
                            CreatePatternFamilyTool.CaseInput(
                                key: "01", label: nil, args: [.int(2)], expected: .int(2),
                                argVarRefs: nil, argsProvided: nil, expectedVarRef: nil,
                                points: nil, tier: nil, enabled: nil),
                        ]),
                    context(app))
            }
        }
    }

    @Test func wrongArgCountThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            // Declares one param but the case passes two args — rejected by the
            // per-kind validation that runs on save (mapped from Vapor Abort).
            await #expect(throws: MCPToolError.self) {
                _ = try await CreatePatternFamilyTool().execute(
                    CreatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, id: "arity", name: "Arity",
                        kind: "boundary_equality", function: "f", paramNames: ["x"],
                        defaultTier: nil, defaultPoints: nil, tolerance: nil, sectionID: nil,
                        dependsOn: nil, variables: nil,
                        cases: [
                            CreatePatternFamilyTool.CaseInput(
                                key: "01", label: nil, args: [.int(1), .int(2)], expected: .int(1),
                                argVarRefs: nil, argsProvided: nil, expectedVarRef: nil,
                                points: nil, tier: nil, enabled: nil)
                        ]),
                    context(app))
            }
        }
    }

    @Test func unknownKindThrows() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await CreatePatternFamilyTool().execute(
                    CreatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, id: "k", name: "K",
                        kind: "bogus_kind", function: "f", paramNames: ["x"],
                        defaultTier: nil, defaultPoints: nil, tolerance: nil, sectionID: nil,
                        dependsOn: nil, variables: nil,
                        cases: [
                            CreatePatternFamilyTool.CaseInput(
                                key: "01", label: nil, args: [.int(1)], expected: .int(1),
                                argVarRefs: nil, argsProvided: nil, expectedVarRef: nil,
                                points: nil, tier: nil, enabled: nil)
                        ]),
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
                on: app, id: "setup_pf", courseID: courseID, manifest: emptyManifest)
            try pfWriteEmptyZip(at: app.testSetupsDirectory + "setup_pf.zip")
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_pf", courseID: courseID, title: "Lab")
            await #expect(throws: MCPToolError.self) {
                _ = try await CreatePatternFamilyTool().execute(
                    CreatePatternFamilyTool.Input(
                        assignmentPublicID: assignment.publicID, id: "x", name: "X",
                        kind: "boundary_equality", function: "f", paramNames: ["x"],
                        defaultTier: nil, defaultPoints: nil, tolerance: nil, sectionID: nil,
                        dependsOn: nil, variables: nil,
                        cases: [
                            CreatePatternFamilyTool.CaseInput(
                                key: "01", label: nil, args: [.int(1)], expected: .int(1),
                                argVarRefs: nil, argsProvided: nil, expectedVarRef: nil,
                                points: nil, tier: nil, enabled: nil)
                        ]),
                    context(app))
            }
        }
    }
}
