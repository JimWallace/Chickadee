// Tests/APITests/Assignments/AssignmentTypeRulesTests.swift
//
// The rules the declared assignment type carries (docs/assignment-types.md,
// phase 2): an Assignment refuses browser grading, a Class activity keeps its
// activity and stays out of the LMS push and slip days, a type change checks
// the rules and writes an audit record, and create_assignment's type sets the
// grading mode. The section side (phase 3) is in `SectionPlacementTests` and
// `CourseSectionServiceTests`.

import Core
import Fluent
import Foundation
import SQLKit
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) struct AssignmentTypeRulesTests {

    private static let workerManifest =
        #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[],"timeLimitSeconds":10}"#
    private static let browserManifest =
        #"{"schemaVersion":1,"gradingMode":"browser","testSuites":[],"timeLimitSeconds":10}"#
    private static let activityManifest =
        #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[],"activity":{"kind":"bestMetric"}}"#
    private static let notebook = #"{"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}"#

    private func manifest(_ json: String) throws -> TestProperties {
        try #require(decodeManifest(fromJSON: json))
    }

    /// An MCP-seeded assignment on `manifest`, declared as `type`.
    private func seeded(
        on app: Application, setupID: String, manifest: String, type: AssignmentType
    ) async throws -> APIAssignment {
        let assignment = try await seedMCPAssignment(on: app, setupID: setupID, manifest: manifest)
        assignment.assignmentType = type
        try await assignment.save(on: app.db)
        return assignment
    }

    // MARK: - The pure rules

    @Test func anAssignmentRefusesBrowserGrading() throws {
        let browser = try manifest(Self.browserManifest)
        #expect(
            ManifestCoherence.typeViolations(in: browser, type: .assignment)
                == [ManifestCoherence.assignmentBrowserGradingMessage])
        #expect(ManifestCoherence.typeViolations(in: browser, type: .lab).isEmpty)
        #expect(ManifestCoherence.typeViolations(in: browser, type: nil).isEmpty)
    }

    /// A stored browser mode on an upload-only setup grades on the worker, so
    /// it breaks no type rule.
    @Test func theRuleReadsTheEffectiveGradingMode() throws {
        let uploadOnly = try manifest(
            #"{"schemaVersion":1,"gradingMode":"browser","submissionMode":"uploadOnly","testSuites":[]}"#)
        #expect(ManifestCoherence.typeViolations(in: uploadOnly, type: .assignment).isEmpty)
    }

    @Test func aClassActivityNeedsAnActivity() throws {
        #expect(
            ManifestCoherence.typeViolations(in: try manifest(Self.workerManifest), type: .classActivity)
                == [ManifestCoherence.classActivityRequiresActivityMessage])
        #expect(ManifestCoherence.typeViolations(in: try manifest(Self.activityManifest), type: .classActivity).isEmpty)
    }

    /// Bug Hunt 1 and 2 in HLTH 230-W27: a Class activity with no activity may
    /// still become an Assignment, but an Assignment may not become a Class
    /// activity before it has an activity.
    @Test func aTypeChangeIsRefusedOnlyForARuleItIntroduces() {
        #expect(
            ManifestCoherence.violation(declaring: .assignment, over: .classActivity, in: Self.workerManifest)
                == nil)
        #expect(
            ManifestCoherence.violation(declaring: .classActivity, over: .assignment, in: Self.workerManifest)
                == ManifestCoherence.classActivityRequiresActivityMessage)
        #expect(
            ManifestCoherence.violation(declaring: .assignment, over: .lab, in: Self.browserManifest)
                == ManifestCoherence.assignmentBrowserGradingMessage)
    }

    /// A copy never creates a browser-graded Assignment, and copies a Class
    /// activity with no activity as it is.
    @Test func aCopyKeepsItsTypeUnlessItWouldLeakSecretTests() throws {
        #expect(admissibleAssignmentType(.assignment, manifest: try manifest(Self.browserManifest)) == .lab)
        #expect(admissibleAssignmentType(.classActivity, manifest: try manifest(Self.workerManifest)) == .classActivity)
        #expect(admissibleAssignmentType(.lab, manifest: try manifest(Self.workerManifest)) == .lab)
        #expect(admissibleAssignmentType(nil, manifest: try manifest(Self.activityManifest)) == .classActivity)
    }

    @Test(arguments: AssignmentType.allCases)
    func everyTypeStatesItsRules(type: AssignmentType) {
        let rules = AssignmentTypeRules.rules(for: type)
        #expect(rules.count >= 4)
        let capability = MCPAssignmentTypeCapability(type)
        #expect(capability.name == type.rawValue)
        #expect(capability.defaultGradingMode == type.defaultGradingMode.rawValue)
        #expect(capability.rules == rules)
    }

    @Test func theTypeDecidesThePushAndTheSlipDays() {
        let activity = APIAssignment(testSetupID: "s", title: "Live", dueAt: nil, isOpen: true, courseID: UUID())
        activity.assignmentType = .classActivity
        #expect(activity.isExcludedFromGradePush)
        let lab = APIAssignment(testSetupID: "s", title: "Lab", dueAt: nil, isOpen: true, courseID: UUID())
        lab.assignmentType = .lab
        #expect(!lab.isExcludedFromGradePush)

        let slipDays = DashboardSlipDayData(
            policy: SlipDayPolicy.resolve(enabled: true, daysPerStudent: 2, extensionHours: 24),
            balance: 2, totalBudget: 2, spendCountBySetupID: [:])
        #expect(slipDays.claimState(forSetupID: "s", assignment: activity) == nil)
        #expect(slipDays.claimState(forSetupID: "s", assignment: lab) != nil)
    }

    // MARK: - The writers check the type

    @Test func setGradingModeRefusesBrowserOnAnAssignment() async throws {
        try await withTestApp { app in
            let assignment = try await seeded(
                on: app, setupID: "setup_rule_gm", manifest: Self.workerManifest, type: .assignment)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetGradingModeTool().execute(
                    .init(assignmentPublicID: assignment.publicID, gradingMode: "browser"), mcpContext(app))
            }
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            #expect(setup.decodedManifest()?.gradingMode == .worker)
            // The shared writer refuses it too, for the web editor's door.
            await #expect(throws: AppError.self) {
                _ = try await setManifestGradingMode(setup: setup, to: "browser", on: app.db)
            }

            assignment.assignmentType = .lab
            try await assignment.save(on: app.db)
            let out = try await SetGradingModeTool().execute(
                .init(assignmentPublicID: assignment.publicID, gradingMode: "browser"), mcpContext(app))
            #expect(out.gradingMode == "browser")
        }
    }

    @Test func aClassActivityKeepsItsActivity() async throws {
        try await withTestApp { app in
            let assignment = try await seeded(
                on: app, setupID: "setup_rule_act", manifest: Self.activityManifest, type: .classActivity)
            let setup = try #require(try await APITestSetup.find(assignment.testSetupID, on: app.db))
            await #expect(throws: AppError.self) {
                try await ActivityAuthoring.setActivity(setup: setup, to: nil, on: app.db)
            }
            #expect(setup.decodedManifest()?.activity != nil)
        }
    }

    // MARK: - The type change

    @Test func aTypeChangeChecksTheRulesAndIsAudited() async throws {
        try await withTestApp { app in
            let assignment = try await seeded(
                on: app, setupID: "setup_rule_tc", manifest: Self.workerManifest, type: .classActivity)

            // Bug Hunt's way back: a Class activity with no activity becomes an
            // Assignment.
            let out = try await UpdateAssignmentTool().execute(
                .init(assignmentPublicID: assignment.publicID, assignmentType: "assignment"), mcpContext(app))
            #expect(out.assignmentType == "assignment")

            // And not forward again before it has an activity. Nothing else in
            // the call is written.
            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateAssignmentTool().execute(
                    .init(assignmentPublicID: assignment.publicID, title: "Renamed", assignmentType: "classActivity"),
                    mcpContext(app))
            }
            let stored = try #require(try await APIAssignment.find(assignment.id, on: app.db))
            #expect(stored.assignmentType == .assignment)
            #expect(stored.title == assignment.title)

            let audits = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.assignmentTypeChanged.rawValue)
                .all()
            #expect(audits.count == 1)
            #expect(audits.first?.targetID == assignment.id?.uuidString)
        }
    }

    // MARK: - Creation

    @Test func createAssignmentTakesATypeThatSetsTheGradingMode() async throws {
        try await withTestApp { app in
            _ = try await seedMCPAssignment(on: app, setupID: "setup_rule_seed")
            let notebook = try JSONDecoder().decode(JSONValue.self, from: Data(Self.notebook.utf8))

            let assignment = try await CreateAssignmentTool().execute(
                .init(
                    courseCode: "CS246", title: "Assignment 5", notebook: notebook, language: "python",
                    assignmentType: "assignment"),
                mcpContext(app))
            #expect(assignment.assignmentType == "assignment")
            #expect(assignment.gradingMode == "worker")

            let activity = try await CreateAssignmentTool().execute(
                .init(
                    courseCode: "CS246", title: "Class Activity 6", notebook: notebook, language: "python",
                    assignmentType: "classActivity"),
                mcpContext(app))
            #expect(activity.assignmentType == "classActivity")
            #expect(activity.gradingMode == "worker")

            // Omitted keeps what the tool did before: a browser-graded Lab.
            let lab = try await CreateAssignmentTool().execute(
                .init(courseCode: "CS246", title: "Lab 10", notebook: notebook, language: "python"),
                mcpContext(app))
            #expect(lab.assignmentType == "lab")
            #expect(lab.gradingMode == "browser")
        }
    }

    @Test func getServerInfoListsEveryTypesRules() async throws {
        try await withTestApp { app in
            _ = try await seedMCPAssignment(on: app, setupID: "setup_rule_info")
            let info = try await GetServerInfoTool().execute(.init(), mcpContext(app))
            #expect(info.assignmentTypes.map(\.name) == AssignmentType.allCases.map(\.rawValue))
            let assignment = try #require(info.assignmentTypes.first { $0.name == "assignment" })
            #expect(!assignment.allowsBrowserGrading)
            let activity = try #require(info.assignmentTypes.first { $0.name == "classActivity" })
            #expect(activity.requiresActivity && !activity.pushesGradesToLMS && !activity.allowsSlipDays)
        }
    }

    // MARK: - The section migration

    /// A section saved by this release omits the old grading-mode column,
    /// which the migration gave a default, so the old color of a blue-green
    /// deploy still reads a value.
    @Test func aNewSectionGetsTheOldColumnsDefault() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "MIG_SECT").requireID()
            let section = APICourseSection(name: "Labs", defaultAssignmentType: .lab, sortOrder: 1, courseID: courseID)
            try await section.save(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            struct Row: Decodable {
                let mode: String
                enum CodingKeys: String, CodingKey { case mode = "default_grading_mode" }
            }
            let row = try #require(
                try await sql.raw(
                    "SELECT default_grading_mode FROM course_sections WHERE id = \(bind: try section.requireID())"
                ).first(decoding: Row.self))
            #expect(row.mode == "worker")
        }
    }
}
