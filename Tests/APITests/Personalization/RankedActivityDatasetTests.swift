// Tests/APITests/Personalization/RankedActivityDatasetTests.swift
//
// An activity that ranks or matches students refuses personal data
// (docs/datasets-course-library.md §4.11). The rule is one `ManifestCoherence`
// rule, and each door that saves a dataset spec or an activity refuses the
// pair: `set_activity` and the edit page, both `/datasets` PUTs,
// `set_dataset`, and the library attach. A class composite is not ranked, so
// it accepts personal data.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct RankedActivityDatasetRuleTests {

    private func manifest(activity: ActivityKind?, datasets: [DatasetSpec]) -> TestProperties {
        var props = TestProperties(testSuites: [TestSuiteEntry(tier: .pub, script: "t.sh")], language: .python)
        props.activity = activity.map { ClassActivity(kind: $0) }
        props.datasets = datasets
        return props
    }

    private let sample = DatasetSpec(file: "cases.csv", sampleSize: 3)
    private let shared = DatasetSpec(file: "cases.csv")

    @Test func onlyAClassCompositeDoesNotCompareStudents() {
        #expect(ActivityKind.allCases.filter { !$0.comparesStudents } == [.classComposite])
    }

    @Test func aSpecIsSharedOnlyWithNoSampleAndNoTransforms() {
        #expect(shared.isShared)
        #expect(!sample.isShared)
        #expect(
            !DatasetSpec(file: "cases.csv", transforms: [.init(kind: .missingValues, columns: ["ward"], rate: 0.1)])
                .isShared)
    }

    @Test(arguments: ActivityKind.allCases.filter(\.comparesStudents))
    func aRankedActivityRefusesPersonalData(kind: ActivityKind) {
        #expect(
            ManifestCoherence.violations(in: manifest(activity: kind, datasets: [sample]))
                == [ActivityAuthoring.personalDataMessage(file: "cases.csv")])
        #expect(ManifestCoherence.violations(in: manifest(activity: kind, datasets: [shared])).isEmpty)
    }

    @Test func aCompositeOrAnAssignmentWithNoActivityAcceptsPersonalData() {
        #expect(ManifestCoherence.violations(in: manifest(activity: .classComposite, datasets: [sample])).isEmpty)
        #expect(ManifestCoherence.violations(in: manifest(activity: nil, datasets: [sample])).isEmpty)
    }

    /// A plain file with no sample is not a valid spec, so the message names
    /// both ways out: remove the dataset settings, or clear the sample of a
    /// library file.
    @Test func theMessageNamesTheFileAndBothWaysOut() {
        let message = ActivityAuthoring.personalDataMessage(file: "cases.csv")
        #expect(message.contains("\"cases.csv\""))
        #expect(message.contains("remove its dataset settings"))
        #expect(message.contains("clear its sample"))
    }

    /// One message per file: an edit that adds a second personal file is
    /// refused although the first one is inherited, and a change between two
    /// ranked kinds is not refused for a file that was already there.
    @Test func anEditIsRefusedOnlyForAPersonalFileItAdds() throws {
        let stored = try #require(
            String(data: JSONEncoder().encode(manifest(activity: .bestMetric, datasets: [sample])), encoding: .utf8))
        #expect(
            ManifestCoherence.violation(
                introducedBy: { $0.datasets.append(DatasetSpec(file: "wards.csv", sampleSize: 2)) }, in: stored)
                == ActivityAuthoring.personalDataMessage(file: "wards.csv"))
        #expect(
            ManifestCoherence.violation(introducedBy: { $0.activity = ClassActivity(kind: .roundRobin) }, in: stored)
                == nil)
        #expect(ManifestCoherence.violation(introducedBy: { $0.datasets = [shared] }, in: stored) == nil)
    }
}

/// The doors read the setup zip with `unzip`, so the suite has a time limit.
@Suite(.serialized, .timeLimit(.minutes(5))) struct RankedActivityDatasetDoorTests {

    private let pool = "id,ward,systolic\n1,A,120\n2,B,131\n3,A,118\n4,B,125\n5,A,140\n"

    /// A Python setup with `cases.csv` in its zip, the given activity and
    /// datasets, and an instructor enrolled to call the MCP tools.
    private func fixture(
        on app: Application, code: String, activity: ActivityKind?, datasets: [DatasetSpec]
    ) async throws -> (assignment: APIAssignment, setup: APITestSetup) {
        var props = TestProperties(testSuites: [TestSuiteEntry(tier: .pub, script: "test_a.sh")], language: .python)
        props.activity = activity.map { ClassActivity(kind: $0) }
        props.datasets = datasets
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        let setupID = "rk_\(code.lowercased())"
        let scenario = try await TestScenario.make(
            on: app, code: code, setupID: setupID, manifest: manifest, title: "Ward race")
        try await scenario.enroll("\(code.lowercased())_tester", role: "instructor", on: app)
        try await writeZipFixture(
            at: app.testSetupsDirectory + setupID + ".zip", entries: [("test_a.sh", "exit 0\n"), ("cases.csv", pool)])
        return (scenario.assignment, scenario.setup)
    }

    private func reloaded(_ setup: APITestSetup, on app: Application) async throws -> APITestSetup {
        try #require(try await APITestSetup.find(try setup.requireID(), on: app.db))
    }

    // MARK: - The activity door

    @Test func aRankedKindIsRefusedOnAnAssignmentWithPersonalData() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (_, setup) = try await fixture(
                on: app, code: "RKA1", activity: nil, datasets: [DatasetSpec(file: "cases.csv", sampleSize: 3)])
            await #expect(throws: AppError.self) {
                try await ActivityAuthoring.setActivity(
                    setup: setup, to: ClassActivity(kind: .bestMetric), on: app.db)
            }
            #expect(try await reloaded(setup, on: app).decodedManifest()?.activity == nil, "nothing was stored")
        }
    }

    @Test func aCompositeIsAllowedOnAnAssignmentWithPersonalData() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (_, setup) = try await fixture(
                on: app, code: "RKA2", activity: nil, datasets: [DatasetSpec(file: "cases.csv", sampleSize: 3)])
            try await ActivityAuthoring.setActivity(
                setup: setup, to: ClassActivity(kind: .classComposite), on: app.db)
            #expect(try await reloaded(setup, on: app).decodedManifest()?.activity?.kind == .classComposite)
        }
    }

    // MARK: - The dataset doors

    @Test func theDatasetsPutRefusesASampleOnARankedActivity() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (_, setup) = try await fixture(on: app, code: "RKD1", activity: .kingOfTheHill, datasets: [])
            await #expect(throws: AppError.self) {
                try await applyDatasetsEdit(
                    setup: setup, datasets: [DatasetSpec(file: "cases.csv", sampleSize: 3)], on: app.db)
            }
            #expect(try await reloaded(setup, on: app).decodedManifest()?.datasets.isEmpty == true)
        }
    }

    @Test func setDatasetRefusesASampleOnARankedActivity() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, setup) = try await fixture(on: app, code: "RKD2", activity: .roundRobin, datasets: [])
            await #expect(throws: MCPToolError.self) {
                _ = try await SetDatasetTool().execute(
                    .init(
                        assignmentPublicID: assignment.publicID, filename: "cases.csv", sampleSize: 3,
                        stratumColumn: nil, remove: nil, transforms: nil),
                    ToolContext(
                        request: makeTestRequest(on: app), subject: "rkd2_tester", grantedScopes: [.read, .write]))
            }
            #expect(try await reloaded(setup, on: app).decodedManifest()?.datasets.isEmpty == true)
        }
    }

    /// A legacy manifest that already pairs a ranked activity with personal
    /// data can still be edited toward the rule: clearing the sample passes.
    @Test func anInheritedPairCanBeEditedTowardTheRule() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (_, setup) = try await fixture(
                on: app, code: "RKD3", activity: .bestMetric,
                datasets: [DatasetSpec(file: "cases.csv", sampleSize: 3)])
            try await applyDatasetsEdit(setup: setup, datasets: [], on: app.db)
            #expect(try await reloaded(setup, on: app).decodedManifest()?.datasets.isEmpty == true)
        }
    }

    // MARK: - The library attach

    @Test func theLibraryAttachRefusesASampleOnARankedActivityAndAcceptsTheWholeFile() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (_, setup) = try await fixture(on: app, code: "RKL1", activity: .bestMetric, datasets: [])
            let blobs = AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
            let dataset = try await CourseDatasetService.create(
                courseID: setup.courseID, dataset: .init(name: "Ward vitals", slug: "ward-vitals"),
                upload: .init(filename: "vitals.csv", bytes: Data(pool.utf8)), blobs: blobs, on: app.db
            ).dataset

            await #expect(
                throws: CourseDatasetError.attachmentIssue(ActivityAuthoring.personalDataMessage(file: "vitals.csv"))
            ) {
                try await CourseDatasetService.attach(
                    dataset, to: setup, request: .init(sampleSize: 3, scope: .assignment),
                    testSetupsDirectory: app.testSetupsDirectory, on: app.db)
            }
            #expect(!(await listZipEntries(zipPath: setup.zipPath)).contains("vitals.csv"), "nothing was written")

            let spec = try await CourseDatasetService.attach(
                dataset, to: setup, request: .init(scope: .assignment),
                testSetupsDirectory: app.testSetupsDirectory, on: app.db)
            #expect(spec.isShared)
        }
    }
}
