// Tests/APITests/Gamification/CompositeReferencesTests.swift
//
// The reference render of a class composite (docs/class-composite.md,
// slice 6): "Prepare reference" queues one job for each slot, the jobs wait
// behind student work, each job gets its slot's inputs, the result fills the
// slot's row, and the projector shows a render only in an empty slot and
// never to a student. Also the edit page's line and button, and the route.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct CompositeReferencesTests {

    /// 2 × 1 pixels, 1 frame, gray: two bytes.
    private let shape = CompositeContributionShape(width: 2, height: 1, frames: 1, format: .gray8)
    private let studentPixels = Data([10, 200]).base64EncodedString()
    private let referencePixels = Data([90, 90]).base64EncodedString()

    private func spec(emptySlots: CompositeEmptySlots = .reference) -> CompositeSpec {
        CompositeSpec(
            compositor: .tile, layout: .grid(columns: 2, rows: 2), contribution: shape, dealOrder: .rowMajor,
            emptySlots: emptySlots)
    }

    private func manifest(_ activity: ClassActivity?) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "tile.py")], language: .python, activity: activity)
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private struct Fixture {
        let setupID: String
        let assignment: APIAssignment
        let assignmentID: UUID
        let courseID: UUID
    }

    /// A composite assignment, with a reference solution unless
    /// `withSolution` is false.
    private func fixture(
        _ id: String, activity: ClassActivity? = nil, withSolution: Bool = true, on app: Application
    ) async throws -> Fixture {
        let setupID = "setup_\(id)"
        try await wrInsertSetup(
            id: setupID, manifest: try manifest(activity ?? ClassActivity(kind: .classComposite, composite: spec())),
            on: app)
        let assignment = try await wrInsertAssignment(
            testSetupID: setupID, title: "Class GPU \(id)", isOpen: true, on: app)
        if withSolution {
            let path = app.submissionsDirectory + "sol_\(id).ipynb"
            try #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.write(
                to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            try await APISubmission(
                id: "sol_\(id)", testSetupID: setupID, zipPath: path, attemptNumber: 1,
                filename: "solution.ipynb", userID: nil, kind: APISubmission.Kind.validation
            ).save(on: app.db)
            assignment.validationSubmissionID = "sol_\(id)"
            try await assignment.save(on: app.db)
        }
        return Fixture(
            setupID: setupID, assignment: assignment, assignmentID: try assignment.requireID(),
            courseID: try await wrMakeCourse(on: app).requireID())
    }

    private func setup(_ f: Fixture, on app: Application) async throws -> APITestSetup {
        try #require(try await APITestSetup.find(f.setupID, on: app.db))
    }

    private func references(_ f: Fixture, on app: Application) async throws -> [APICompositeReference] {
        try await APICompositeReference.query(on: app.db).filter(\.$assignmentID == f.assignmentID)
            .sort(\.$slot).all()
    }

    private func collection(
        _ submissionID: String, setupID: String, status: TestStatus = .pass, data: String?
    ) -> TestOutcomeCollection {
        let outcome = TestOutcome(
            testName: "tile.py", testClass: nil, tier: .pub, status: status, shortResult: "",
            longResult: nil,
            composite: data.map { CompositeContribution(width: 2, height: 1, frames: 1, format: .gray8, data: $0) },
            executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: status == .pass)
        return TestOutcomeCollection(
            submissionID: submissionID, testSetupID: setupID, attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: [outcome], totalTests: 1, passCount: status == .pass ? 1 : 0,
            failCount: status == .pass ? 0 : 1, errorCount: 0, timeoutCount: 0, executionTimeMs: 1,
            runnerVersion: "test", timestamp: Date())
    }

    /// Prepares the render and records `data` as every slot's result.
    private func render(_ f: Fixture, data: String?, on app: Application) async throws {
        try await CompositeReferences.prepare(
            assignment: f.assignment, setup: try await setup(f, on: app), app: app, on: app.db)
        for row in try await references(f, on: app) {
            let job = try #require(try await APISubmission.find(row.submissionID, on: app.db))
            try await CompositeReferences.record(
                submission: job, collection: collection(row.submissionID, setupID: f.setupID, data: data), on: app.db)
        }
    }

    // MARK: - Preparing

    @Test func prepareQueuesOneJobForEachSlotOwnedByNobody() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("prep", on: app)
            let queued = try await CompositeReferences.prepare(
                assignment: f.assignment, setup: try await setup(f, on: app), app: app, on: app.db)
            #expect(queued == 4)
            let rows = try await references(f, on: app)
            #expect(rows.map(\.slot) == [0, 1, 2, 3])
            #expect(rows.allSatisfy { !$0.passed && $0.data == nil })
            let jobs = try await APISubmission.query(on: app.db)
                .filter(\.$kind == APISubmission.Kind.compositeReference).all()
            #expect(jobs.count == 4)
            #expect(jobs.allSatisfy { $0.userID == nil && $0.statusValue == .pending })
            #expect(Set(jobs.compactMap(\.id)) == Set(rows.map(\.submissionID)))
        }
    }

    @Test func aSecondPrepareReplacesTheEarlierRender() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("again", on: app)
            try await render(f, data: referencePixels, on: app)
            let first = Set(try await references(f, on: app).map(\.submissionID))
            try await CompositeReferences.prepare(
                assignment: f.assignment, setup: try await setup(f, on: app), app: app, on: app.db)
            let second = try await references(f, on: app)
            #expect(second.count == 4)
            #expect(first.isDisjoint(with: second.map(\.submissionID)))
            #expect(second.allSatisfy { $0.data == nil })
            let jobs = try await APISubmission.query(on: app.db)
                .filter(\.$kind == APISubmission.Kind.compositeReference).count()
            #expect(jobs == 4, "the earlier jobs are gone")
        }
    }

    @Test func prepareRefusesAnotherKindOrNoSolution() async throws {
        try await withWebRoutesApp { app in
            let leaderboard = try await fixture(
                "kind", activity: ClassActivity(kind: .bestMetric), on: app)
            await #expect(throws: CompositeReferences.PrepareError.notComposite) {
                try await CompositeReferences.prepare(
                    assignment: leaderboard.assignment, setup: try await setup(leaderboard, on: app), app: app,
                    on: app.db)
            }
            let unsolved = try await fixture("nosol", withSolution: false, on: app)
            await #expect(throws: CompositeReferences.PrepareError.noSolution) {
                try await CompositeReferences.prepare(
                    assignment: unsolved.assignment, setup: try await setup(unsolved, on: app), app: app, on: app.db)
            }
            #expect(try await APICompositeReference.query(on: app.db).count() == 0)
        }
    }

    // MARK: - Grading

    @Test func aReferenceJobIsClaimedAfterAStudentJob() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("claim", on: app)
            try await CompositeReferences.prepare(
                assignment: f.assignment, setup: try await setup(f, on: app), app: app, on: app.db)
            let student = try await makeTestStudent(on: app, username: "ref_claim")
            try await wrInsertSubmission(
                id: "sub_claim", testSetupID: f.setupID, userID: try student.requireID(), status: "pending", on: app)
            let kinds = try await collectClaimCandidates(on: app.db).map(\.0.kind)
            #expect(kinds.first == APISubmission.Kind.student)
            #expect(kinds.filter { $0 == APISubmission.Kind.compositeReference }.count == 4)
            #expect(kinds.last == APISubmission.Kind.compositeReference)
        }
    }

    @Test func aReferenceJobGetsItsRowsSlot() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("inputs", on: app)
            try await CompositeReferences.prepare(
                assignment: f.assignment, setup: try await setup(f, on: app), app: app, on: app.db)
            let row = try #require(try await references(f, on: app).first { $0.slot == 2 })
            let job = try #require(try await APISubmission.find(row.submissionID, on: app.db))
            let manifest = try #require(try await setup(f, on: app).decodedManifest())
            let inputs = try #require(
                await CompositeSlots.jobInputs(
                    manifest: manifest, courseID: f.courseID, assignmentID: f.assignmentID, submission: job,
                    on: app.db))
            let expected = spec().inputs(forSlot: 2).mapValues(AssignmentLanguage.python.literal)
            #expect(inputs == expected)
        }
    }

    @Test func aResultFillsTheRowAndABadPayloadClearsIt() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("record", on: app)
            try await render(f, data: referencePixels, on: app)
            #expect(try await references(f, on: app).allSatisfy { $0.passed && $0.data == referencePixels })
            #expect(try await CompositeReferences.progress(assignmentID: f.assignmentID, on: app.db)?.ready == 4)

            let row = try #require(try await references(f, on: app).first)
            let job = try #require(try await APISubmission.find(row.submissionID, on: app.db))
            let threeBytes = Data([1, 2, 3]).base64EncodedString()
            try await CompositeReferences.record(
                submission: job, collection: collection(row.submissionID, setupID: f.setupID, data: threeBytes),
                on: app.db)
            let cleared = try #require(try await references(f, on: app).first)
            #expect(cleared.data == nil)
            #expect(!cleared.passed)
            let progress = try #require(
                try await CompositeReferences.progress(assignmentID: f.assignmentID, on: app.db))
            #expect(progress.ready == 3)
            #expect(progress.total == 4)
        }
    }

    // MARK: - The view

    @Test func aRenderShowsOnlyInAnEmptySlotAndNeverToAStudent() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("view", on: app)
            try await render(f, data: referencePixels, on: app)
            let user = try await makeTestStudent(on: app, username: "ref_view")
            let userID = try user.requireID()
            try await APICompositeSlot(assignmentID: f.assignmentID, userID: userID, slot: 0, round: 0)
                .create(on: app.db)
            try await wrInsertSubmission(id: "sub_view", testSetupID: f.setupID, userID: userID, on: app)
            try await APICompositeContribution(
                assignmentID: f.assignmentID, userID: userID, slot: 0, submissionID: "sub_view", submittedAt: Date(),
                contribution: CompositeContribution(
                    width: 2, height: 1, frames: 1, format: .gray8, data: studentPixels),
                passed: true
            ).create(on: app.db)
            let scope = CompositeSnapshot.Scope(
                assignmentID: f.assignmentID, testSetupID: f.setupID, courseID: f.courseID, spec: spec())

            let staff = try await CompositeSnapshot.build(
                scope, since: nil, onlyUserID: nil, includeOwners: false, on: app.db)
            #expect(staff.slots.map(\.state) == ["passed", "reference", "reference", "reference"])
            #expect(staff.pixels.map(\.data) == [studentPixels, referencePixels, referencePixels, referencePixels])
            #expect(staff.complete == 1, "a reference render is not a completed slot")

            let own = try await CompositeSnapshot.build(
                scope, since: nil, onlyUserID: userID, includeOwners: false, on: app.db)
            #expect(own.slots.map(\.state) == ["passed"])
            #expect(!own.pixels.contains { $0.data == referencePixels })

            let blank = try await CompositeSnapshot.build(
                CompositeSnapshot.Scope(
                    assignmentID: f.assignmentID, testSetupID: f.setupID, courseID: f.courseID,
                    spec: spec(emptySlots: .blank)),
                since: nil, onlyUserID: nil, includeOwners: false, on: app.db)
            #expect(blank.slots.map(\.state) == ["passed"])
        }
    }

    // MARK: - The edit page and the route

    @Test func theEditPageShowsTheRenderAndTheButtonPrepares() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            let f = try await fixture("route", on: app)
            let editPath = "/instructor/\(f.assignment.publicID)/edit"

            try await app.asyncTest(
                .GET, editPath,
                beforeRequest: { req in req.headers.add(name: .cookie, value: instructorCookie) },
                afterResponse: { res in
                    let html = res.body.string
                    #expect(html.contains("Not prepared"))
                    #expect(html.contains("/activity/composite/reference"))
                    #expect(html.contains("Prepare reference"))
                })

            let (csrf, cookie) = try await csrfFields(for: editPath, cookie: instructorCookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/\(f.assignment.publicID)/activity/composite/reference",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("notice=") == true)
                })
            #expect(try await references(f, on: app).count == 4)

            try await app.asyncTest(
                .GET, editPath,
                beforeRequest: { req in req.headers.add(name: .cookie, value: instructorCookie) },
                afterResponse: { res in #expect(res.body.string.contains("0 of 4 slots ready")) })
        }
    }

    // MARK: - Review cases

    @Test func aHeldJobSurvivesASecondPrepareAndRecordsNothing() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("held", on: app)
            try await CompositeReferences.prepare(
                assignment: f.assignment, setup: try await setup(f, on: app), app: app, on: app.db)
            let heldRow = try #require(try await references(f, on: app).first)
            let held = try #require(try await APISubmission.find(heldRow.submissionID, on: app.db))
            held.status = SubmissionStatus.running.rawValue
            try await held.save(on: app.db)
            var removedFiles: [String] = []
            for row in try await references(f, on: app).dropFirst() {
                removedFiles.append(try #require(try await APISubmission.find(row.submissionID, on: app.db)).zipPath)
            }
            #expect(removedFiles.allSatisfy { FileManager.default.fileExists(atPath: $0) })

            try await CompositeReferences.prepare(
                assignment: f.assignment, setup: try await setup(f, on: app), app: app, on: app.db)
            #expect(try await APISubmission.find(heldRow.submissionID, on: app.db) != nil, "a runner holds it")
            #expect(removedFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "their files go")
            try await CompositeReferences.record(
                submission: held,
                collection: collection(heldRow.submissionID, setupID: f.setupID, data: referencePixels), on: app.db)
            #expect(try await references(f, on: app).allSatisfy { $0.data == nil }, "the old job fills no new row")
            let jobs = try await APISubmission.query(on: app.db)
                .filter(\.$kind == APISubmission.Kind.compositeReference).count()
            #expect(jobs == 5, "four new jobs and the held one")
        }
    }

    @Test func theCorpusRunIsClaimedBeforeReferenceJobs() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("corpus", on: app)
            try await CompositeReferences.prepare(
                assignment: f.assignment, setup: try await setup(f, on: app), app: app, on: app.db)
            let path = app.submissionsDirectory + "corpus.ipynb"
            try #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.write(
                to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            try await APISubmission(
                id: "corpus_run", testSetupID: f.setupID, zipPath: path, attemptNumber: 1,
                filename: "corpus.ipynb", userID: nil, kind: APISubmission.Kind.classAggregate
            ).save(on: app.db)
            let kinds = try await collectClaimCandidates(on: app.db).map(\.0.kind)
            #expect(kinds.firstIndex(of: APISubmission.Kind.classAggregate) == kinds.count - 5)
        }
    }

    @Test func aSlotThatLosesItsContributionGetsTheRenderAgain() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("lost", on: app)
            try await render(f, data: referencePixels, on: app)
            let user = try await makeTestStudent(on: app, username: "ref_lost")
            let userID = try user.requireID()
            try await wrInsertSubmission(id: "sub_lost", testSetupID: f.setupID, userID: userID, on: app)
            let row = APICompositeContribution(
                assignmentID: f.assignmentID, userID: userID, slot: 3, submissionID: "sub_lost", submittedAt: Date(),
                contribution: CompositeContribution(
                    width: 2, height: 1, frames: 1, format: .gray8, data: studentPixels),
                passed: true)
            try await row.create(on: app.db)
            let scope = CompositeSnapshot.Scope(
                assignmentID: f.assignmentID, testSetupID: f.setupID, courseID: f.courseID, spec: spec())
            let before = try await CompositeSnapshot.build(
                scope, since: nil, onlyUserID: nil, includeOwners: false, on: app.db)
            #expect(before.slots.last?.state == "passed")

            let cursor: Int64 = try #require(Int64(before.cursor))
            try await row.delete(on: app.db)
            let after = try await CompositeSnapshot.build(
                scope, since: cursor, onlyUserID: nil, includeOwners: false, on: app.db)
            #expect(after.slots.last?.state == "reference")
            #expect(after.pixels.last == CompositeSnapshot.Pixels(slot: 3, data: referencePixels))

            let statesOnly = try await CompositeSnapshot.build(
                scope, since: .max, onlyUserID: nil, includeOwners: false, on: app.db)
            #expect(statesOnly.pixels.isEmpty)
        }
    }

    @Test func aRenderOfAnotherLengthIsNotShown() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("length", on: app)
            try await render(f, data: referencePixels, on: app)
            let row = try #require(try await references(f, on: app).first)
            row.data = Data([1, 2, 3, 4, 5, 6]).base64EncodedString()
            try await row.save(on: app.db)
            let snapshot = try await CompositeSnapshot.build(
                .init(assignmentID: f.assignmentID, testSetupID: f.setupID, courseID: f.courseID, spec: spec()),
                since: nil, onlyUserID: nil, includeOwners: false, on: app.db)
            #expect(snapshot.slots.map(\.slot) == [1, 2, 3])
        }
    }

    @Test func theRouteRefusesWithoutASolution() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            let f = try await fixture("routenosol", withSolution: false, on: app)
            let editPath = "/instructor/\(f.assignment.publicID)/edit"
            let (csrf, cookie) = try await csrfFields(for: editPath, cookie: instructorCookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/\(f.assignment.publicID)/activity/composite/reference",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("error=Save+a+reference+solution") == true)
                })
            #expect(try await APICompositeReference.query(on: app.db).count() == 0)
        }
    }

    @Test func deletingACourseRemovesTheRenders() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await loginAsAdmin("delete_reference_admin", on: app)
            let f = try await fixture("delete", on: app)
            try await render(f, data: referencePixels, on: app)
            let course = try #require(try await APICourse.find(f.courseID, on: app.db))
            course.isArchived = true
            // Past the 365-day retention window, so deletion is permitted.
            course.archivedAt = Date().addingTimeInterval(-400 * 86_400)
            try await course.save(on: app.db)

            let path = "/admin/courses/\(f.courseID.uuidString)"
            let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "\(path)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            #expect(try await APICourse.find(f.courseID, on: app.db) == nil)
            #expect(try await APICompositeReference.query(on: app.db).count() == 0)
            #expect(
                try await APISubmission.query(on: app.db)
                    .filter(\.$kind == APISubmission.Kind.compositeReference).count() == 0)
        }
    }
}
