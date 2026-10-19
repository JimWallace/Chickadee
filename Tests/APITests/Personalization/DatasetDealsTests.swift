// Tests/APITests/Personalization/DatasetDealsTests.swift
//
// The deal numbers behind the partition datasets
// (docs/datasets-course-library.md §4.11). The dealer gives the lowest free
// number, keeps it, and deals a freed one again; staff get 0 and are never
// dealt; a class composite's slot is the number; and each delivery path gives
// a student the part their number picks. A job with no student gets the whole
// file.

import Core
import Fluent
import Foundation
import NIOCore
import NIOFoundationCompat
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class DatasetDealsTests {

    let app: Application
    private let workerSecret = "dataset-deal-secret"

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-dataset-deals")
        app.workerSecretStore = WorkerSecretStore(initialOverride: workerSecret)
    }

    private let poolCSV = "id,ward\n" + (1...12).map { "\($0),W\($0)" }.joined(separator: "\n") + "\n"
    private let spec = DatasetSpec(file: "cases.csv", kind: .partition, partCount: 3)

    private struct Fixture {
        let courseID: UUID
        let assignmentID: UUID
        let setupID: String
        let manifest: TestProperties
    }

    private func fixture(_ tag: String, activity: ClassActivity? = nil) async throws -> Fixture {
        let courseID = try await makeTestCourse(on: app, code: "DD\(tag)").requireID()
        var props = TestProperties(language: .python, datasets: [spec])
        props.gradingMode = .worker
        props.activity = activity
        props.testSuites = [TestSuiteEntry(tier: .pub, script: "tests.py")]
        let setupID = "ddsetup_\(tag)"
        try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: try encodeManifest(props))
        let sharedDir = app.testSetupsDirectory + "shared/\(setupID)/"
        try FileManager.default.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
        try poolCSV.write(toFile: sharedDir + "cases.csv", atomically: true, encoding: .utf8)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: "Registry")
        return Fixture(courseID: courseID, assignmentID: try assignment.requireID(), setupID: setupID, manifest: props)
    }

    private func student(_ name: String, in fx: Fixture, role: String = "student") async throws -> UUID {
        let user = try await makeTestUser(on: app, username: name, role: role)
        try await makeTestEnrollment(on: app, userID: user.requireID(), courseID: fx.courseID)
        return try user.requireID()
    }

    private func deal(_ fx: Fixture, _ userID: UUID?, grading: Bool = true) async throws -> Int? {
        try await DatasetDeals.dealNumber(
            manifest: fx.manifest, courseID: fx.courseID, assignmentID: fx.assignmentID, userID: userID,
            grading: grading, on: app.db)
    }

    private func dealRows(_ fx: Fixture) async throws -> Int {
        try await APIDatasetDeal.query(on: app.db).filter(\.$assignmentID == fx.assignmentID).count()
    }

    private func part(_ number: Int) -> String {
        DatasetMaterializer.materialize(source: poolCSV, spec: spec, seedHex: "ab", dealNumber: number)
    }

    // MARK: - The dealer

    @Test func theDealerGivesTheLowestFreeNumberAndKeepsIt() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("a")
            let first = try await student("dd_a1", in: fx)
            let second = try await student("dd_a2", in: fx)
            #expect(try await deal(fx, first) == 0)
            #expect(try await deal(fx, second) == 1)
            #expect(try await deal(fx, first) == 0)
            #expect(try await dealRows(fx) == 2)
        }
    }

    @Test func aFreedNumberIsDealtAgain() async throws {
        try await withApp(app) { app in
            let fx = try await fixture("f")
            let first = try await student("dd_f1", in: fx)
            let second = try await student("dd_f2", in: fx)
            _ = try await deal(fx, first)
            _ = try await deal(fx, second)
            try await APIDatasetDeal.query(on: app.db).filter(\.$userID == first).delete()
            let third = try await student("dd_f3", in: fx)
            #expect(try await deal(fx, third) == 0)
        }
    }

    @Test func concurrentDealsGiveDistinctNumbers() async throws {
        try await withApp(app) { app in
            let fx = try await fixture("c")
            var users: [UUID] = []
            for index in 0..<5 { users.append(try await student("dd_c\(index)", in: fx)) }
            let db = app.db
            let assignmentID = fx.assignmentID
            let numbers = try await withThrowingTaskGroup(of: Int.self) { group in
                for user in users {
                    group.addTask {
                        try await DatasetDeals.deal(assignmentID: assignmentID, userID: user, on: db)
                    }
                }
                return try await group.reduce(into: [Int]()) { $0.append($1) }
            }
            #expect(numbers.sorted() == [0, 1, 2, 3, 4])
        }
    }

    @Test func staffGetZeroAndAreNeverDealt() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("t")
            let ta = try await student("dd_t_staff", in: fx, role: "instructor")
            #expect(try await deal(fx, ta) == 0)
            #expect(try await dealRows(fx) == 0)
        }
    }

    @Test func anAssignmentWithNoPartitionDealsNothing() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("n")
            var plain = fx.manifest
            plain.datasets = [DatasetSpec(file: "cases.csv", sampleSize: 3)]
            let user = try await student("dd_n1", in: fx)
            #expect(
                try await DatasetDeals.dealNumber(
                    manifest: plain, courseID: fx.courseID, assignmentID: fx.assignmentID, userID: user,
                    grading: true, on: app.db)
                    == nil)
            #expect(try await deal(fx, nil) == nil)
            #expect(try await dealRows(fx) == 0)
        }
    }

    /// On a class composite the slot is the number, so a student's tile and
    /// their rows agree.
    @Test func aCompositesSlotIsTheDealNumber() async throws {
        try await withApp(app) { app in
            let fx = try await fixture(
                "k", activity: ClassActivity(kind: .classComposite, composite: .starter))
            let user = try await student("dd_k1", in: fx)
            let number = try #require(try await deal(fx, user))
            let slot = try await CompositeSlots.slot(
                assignmentID: fx.assignmentID, userID: user, spec: .starter, on: app.db)
            #expect(number == slot)
            #expect(try await dealRows(fx) == 0)
        }
    }

    /// Before the session window opens, only a grading path deals a slot, as
    /// for the composite itself. A download or the editor copy reads the
    /// whole file until then.
    @Test func outsideTheWindowOnlyGradingDealsACompositeSlot() async throws {
        try await withApp(app) { app in
            let later = LiveSessionWindow(opensAt: Date().addingTimeInterval(3_600), closesAt: nil)
            let fx = try await fixture(
                "z", activity: ClassActivity(kind: .classComposite, window: later, composite: .starter))
            let user = try await student("dd_z1", in: fx)
            #expect(try await deal(fx, user, grading: false) == nil)
            #expect(try await CompositeSlots.hasDealtSlots(assignmentID: fx.assignmentID, on: app.db) == false)
            let dealt = try #require(try await deal(fx, user, grading: true))
            #expect(try await deal(fx, user, grading: false) == dealt)
        }
    }

    @Test func eachJobKindTakesItsNumber() async throws {
        try await withApp(app) { app in
            let fx = try await fixture("j")
            let user = try await student("dd_j1", in: fx)
            func number(_ kind: String, userID: UUID?) async throws -> Int? {
                let submission = APISubmission(
                    id: "ddj_\(UUID().uuidString.prefix(8))", testSetupID: fx.setupID, zipPath: "/dev/null",
                    attemptNumber: 1, filename: "main.py", userID: userID, kind: kind)
                return try await DatasetDeals.jobDealNumber(
                    manifest: fx.manifest, courseID: fx.courseID, assignmentID: fx.assignmentID,
                    submission: submission, pinned: nil, on: app.db)
            }
            #expect(try await number(APISubmission.Kind.validation, userID: user) == 0)
            #expect(try await number(APISubmission.Kind.starterValidation, userID: user) == 0)
            #expect(try await number(APISubmission.Kind.classAggregate, userID: nil) == nil)
            #expect(try await number(APISubmission.Kind.compositeReference, userID: nil) == nil)
            #expect(try await number(APISubmission.Kind.student, userID: user) == 0)
        }
    }

    /// A reference job renders one slot, so it reads that slot's part; a
    /// pinned run keeps its own number.
    @Test func aReferenceJobReadsItsSlotAndAPinnedRunKeepsItsNumber() async throws {
        try await withApp(app) { app in
            let fx = try await fixture("r")
            let reference = APISubmission(
                id: "ddr_\(UUID().uuidString.prefix(8))", testSetupID: fx.setupID, zipPath: "/dev/null",
                attemptNumber: 1, filename: "main.py", userID: nil, kind: APISubmission.Kind.compositeReference)
            try await reference.save(on: app.db)
            try await APICompositeReference(
                assignmentID: fx.assignmentID, slot: 2, submissionID: try reference.requireID()
            ).save(on: app.db)
            #expect(
                try await DatasetDeals.jobDealNumber(
                    manifest: fx.manifest, courseID: fx.courseID, assignmentID: fx.assignmentID,
                    submission: reference, pinned: 5, on: app.db) == 2)

            let variant = APISubmission(
                id: "ddv_\(UUID().uuidString.prefix(8))", testSetupID: fx.setupID, zipPath: "/dev/null",
                attemptNumber: 1, filename: "main.py", userID: nil, kind: APISubmission.Kind.validation)
            #expect(
                try await DatasetDeals.jobDealNumber(
                    manifest: fx.manifest, courseID: fx.courseID, assignmentID: fx.assignmentID,
                    submission: variant, pinned: 3, on: app.db) == 3)
        }
    }

    // MARK: - Delivery

    private func claim() async throws -> Job? {
        let path = "/api/v1/worker/request"
        let body = try ByteBuffer(
            data: JSONEncoder().encode(
                WorkerActivityPayload(
                    workerID: "dd-worker", hostname: "dd.local", runnerVersion: "runner-tests/1.0",
                    maxConcurrentJobs: 1, activeJobs: 0, profile: nil)))
        var job: Job?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers = workerHMACHeaders(method: .POST, path: path, body: body, workerSecret: self.workerSecret)
                req.body = body
            },
            afterResponse: { res in
                if res.status == .ok { job = try? res.content.decode(Job.self) }
            })
        return job
    }

    private func submit(_ fx: Fixture, userID: UUID?, kind: String) async throws {
        let id = "ddsub_\(UUID().uuidString.prefix(8))"
        let path = app.submissionsDirectory + id + ".py"
        try Data("print(1)\n".utf8).write(to: URL(fileURLWithPath: path))
        try await APISubmission(
            id: id, testSetupID: fx.setupID, zipPath: path, attemptNumber: 1, filename: "main.py", userID: userID,
            kind: kind
        ).save(on: app.db)
    }

    @Test func aStudentsJobGradesTheStudentsPart() async throws {
        try await withApp(app) { _ in
            let fx = try await fixture("w")
            let first = try await student("dd_w1", in: fx)
            let second = try await student("dd_w2", in: fx)
            _ = try await deal(fx, first)
            try await submit(fx, userID: second, kind: APISubmission.Kind.student)
            let job = try #require(try await claim())
            #expect(job.personalizedFiles?["cases.csv"] == part(1))
        }
    }

    @Test func theDownloadServesTheStudentsPart() async throws {
        try await withApp(app) { app in
            let fx = try await fixture("d")
            let first = try await student("dd_d1", in: fx)
            let second = try await student("dd_d2", in: fx)
            let setup = try #require(try await APITestSetup.find(fx.setupID, on: app.db))
            let assignment = try #require(try await APIAssignment.find(fx.assignmentID, on: app.db))
            for (user, number) in [(first, 0), (second, 1)] {
                let file = try await StudentDatasetDelivery.file(
                    named: "cases.csv", setup: setup, assignment: assignment, userID: user,
                    testSetupsDirectory: app.testSetupsDirectory, on: app.db)
                #expect(file == part(number))
            }
        }
    }
}
