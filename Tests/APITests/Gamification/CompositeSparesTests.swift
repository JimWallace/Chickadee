// Tests/APITests/Gamification/CompositeSparesTests.swift
//
// The spare slots of a class composite (docs/class-composite.md, slice 6b): the
// holes and their order, "Fill a hole" with its refusals, the job's seed, claim
// order and slot, the result that fills and covers the slot for the student, the
// projector view, the result page's button and its route, and course deletion.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct CompositeSparesTests {

    /// 2 × 1 pixels, 1 frame, gray: two bytes.
    private let shape = CompositeContributionShape(width: 2, height: 1, frames: 1, format: .gray8)
    private let ownPixels = Data([10, 200]).base64EncodedString()
    private let sparePixels = Data([60, 60]).base64EncodedString()
    private let referencePixels = Data([90, 90]).base64EncodedString()

    private func spec(emptySlots: CompositeEmptySlots = .blank) -> CompositeSpec {
        CompositeSpec(
            compositor: .tile, layout: .grid(columns: 2, rows: 2), contribution: shape, dealOrder: .rowMajor,
            emptySlots: emptySlots)
    }

    private struct Fixture {
        let setupID: String
        let assignment: APIAssignment
        let assignmentID: UUID
        let courseID: UUID
    }

    private func fixture(
        _ id: String, activity: ClassActivity? = nil, isOpen: Bool = true, on app: Application
    ) async throws -> Fixture {
        let setupID = "setup_\(id)"
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "tile.py")], language: .python,
            activity: activity ?? ClassActivity(kind: .classComposite, composite: spec()))
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        try await wrInsertSetup(id: setupID, manifest: manifest, on: app)
        let assignment = try await wrInsertAssignment(
            testSetupID: setupID, title: "Class GPU \(id)", isOpen: isOpen, on: app)
        return Fixture(
            setupID: setupID, assignment: assignment, assignmentID: try assignment.requireID(),
            courseID: try await wrMakeCourse(on: app).requireID())
    }

    private func setup(_ f: Fixture, on app: Application) async throws -> APITestSetup {
        try #require(try await APITestSetup.find(f.setupID, on: app.db))
    }

    /// An enrolled student who holds `slot`, with a tile that passed or not.
    @discardableResult
    private func student(
        _ name: String, slot: Int, passed: Bool = true, _ f: Fixture, on app: Application
    ) async throws -> UUID {
        let user = try await makeTestStudent(on: app, username: name)
        try await wrEnrollUser(user, on: app)
        let id = try user.requireID()
        try await APICompositeSlot(assignmentID: f.assignmentID, userID: id, slot: slot, round: 0).create(on: app.db)
        let submissionID = "sub_\(name)"
        try await wrInsertSubmission(id: submissionID, testSetupID: f.setupID, userID: id, on: app)
        try "print(1)\n".write(
            toFile: app.submissionsDirectory + "\(submissionID).py", atomically: true, encoding: .utf8)
        try await APICompositeContribution(
            assignmentID: f.assignmentID, userID: id, slot: slot, submissionID: submissionID, submittedAt: Date(),
            contribution: CompositeContribution(width: 2, height: 1, frames: 1, format: .gray8, data: ownPixels),
            passed: passed
        ).create(on: app.db)
        return id
    }

    @discardableResult
    private func request(_ f: Fixture, for userID: UUID, on app: Application) async throws -> Int {
        try await CompositeSpares.request(
            assignment: f.assignment, setup: try await setup(f, on: app), userID: userID, app: app, on: app.db)
    }

    private func spare(_ f: Fixture, slot: Int, on app: Application) async throws -> APICompositeSpare {
        try #require(
            try await APICompositeSpare.query(on: app.db)
                .filter(\.$assignmentID == f.assignmentID).filter(\.$slot == slot).first())
    }

    private func collection(
        _ submissionID: String, setupID: String, status: TestStatus = .pass, data: String?
    )
        -> TestOutcomeCollection
    {
        let outcome = TestOutcome(
            testName: "tile.py", testClass: nil, tier: .pub, status: status, shortResult: "", longResult: nil,
            composite: data.map { CompositeContribution(width: 2, height: 1, frames: 1, format: .gray8, data: $0) },
            executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: status == .pass)
        return TestOutcomeCollection(
            submissionID: submissionID, testSetupID: setupID, attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: [outcome], totalTests: 1, passCount: status == .pass ? 1 : 0,
            failCount: status == .pass ? 0 : 1, errorCount: 0, timeoutCount: 0, executionTimeMs: 1,
            runnerVersion: "test", timestamp: Date())
    }

    /// Records `data` as the result of the spare in `slot`.
    private func finish(
        _ f: Fixture, slot: Int, status: TestStatus = .pass, data: String?, on app: Application
    ) async throws {
        let row = try await spare(f, slot: slot, on: app)
        let job = try #require(try await APISubmission.find(row.submissionID, on: app.db))
        try await CompositeSpares.record(
            submission: job, collection: collection(row.submissionID, setupID: f.setupID, status: status, data: data),
            on: app.db)
        job.setStatus(.complete)
        try await job.save(on: app.db)
    }

    // MARK: - Holes

    @Test func aSlotNobodyHoldsComesBeforeAHeldSlotThatHasNotPassed() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("holes", on: app)
            try await student("h_a", slot: 0, f, on: app)
            try await student("h_b", slot: 1, passed: false, f, on: app)
            let holes = try await CompositeSpares.holes(assignmentID: f.assignmentID, spec: spec(), on: app.db)
            #expect(holes == [2, 3, 1])
        }
    }

    // MARK: - Requesting

    @Test func aRequestQueuesAJobOwnedByNobodyWithTheStudentsSeed() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("queue", on: app)
            let id = try await student("q_a", slot: 0, f, on: app)
            #expect(try await request(f, for: id, on: app) == 1)

            let row = try await spare(f, slot: 1, on: app)
            #expect(row.userID == id)
            #expect(!row.passed && row.data == nil)
            let job = try #require(try await APISubmission.find(row.submissionID, on: app.db))
            #expect(job.kind == APISubmission.Kind.compositeSpare)
            #expect(job.userID == nil)
            #expect(job.statusValue == .pending)
            let seed = try await AssignmentSeedStore.ensureSeed(userID: id, assignmentID: f.assignmentID, on: app.db)
            #expect(job.decodedMaterialization()?.seedHex == seed)
            #expect(try String(contentsOfFile: job.zipPath, encoding: .utf8) == "print(1)\n")
        }
    }

    @Test func aRequestIsRefusedWithoutAPassingTileWhileOneGradesOrWithNoHole() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("refuse", on: app)
            let failed = try await student("r_fail", slot: 0, passed: false, f, on: app)
            await #expect(throws: CompositeSpares.RequestError.noPassingTile) {
                try await request(f, for: failed, on: app)
            }
            let passed = try await student("r_pass", slot: 1, f, on: app)
            #expect(try await request(f, for: passed, on: app) == 2)
            await #expect(throws: CompositeSpares.RequestError.inFlight) {
                try await request(f, for: passed, on: app)
            }
            try await finish(f, slot: 2, data: sparePixels, on: app)
            #expect(try await request(f, for: passed, on: app) == 3)
            try await finish(f, slot: 3, data: sparePixels, on: app)
            #expect(try await request(f, for: passed, on: app) == 0, "the failed holder's slot is last")
            try await finish(f, slot: 0, data: sparePixels, on: app)
            await #expect(throws: CompositeSpares.RequestError.noHole) {
                try await request(f, for: passed, on: app)
            }

            let other = try await fixture("refuse_kind", activity: ClassActivity(kind: .bestMetric), on: app)
            await #expect(throws: CompositeSpares.RequestError.notComposite) {
                try await request(other, for: passed, on: app)
            }
        }
    }

    @Test func aFailedSpareLeavesAHoleForOthersAndTheStudentMovesOn() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("failed", on: app)
            let mine = try await student("f_a", slot: 0, f, on: app)
            let other = try await student("f_b", slot: 3, f, on: app)
            // Slot 2 is held by a student who has not submitted.
            let holder = try await makeTestStudent(on: app, username: "f_c").requireID()
            try await APICompositeSlot(assignmentID: f.assignmentID, userID: holder, slot: 2, round: 0)
                .create(on: app.db)

            #expect(try await request(f, for: mine, on: app) == 1)
            let first = try await spare(f, slot: 1, on: app)
            try await finish(f, slot: 1, status: .fail, data: sparePixels, on: app)
            #expect(try await CompositeSpares.holes(assignmentID: f.assignmentID, spec: spec(), on: app.db) == [1, 2])

            #expect(try await request(f, for: mine, on: app) == 2, "the same code fails slot 1 again")
            #expect(try await request(f, for: other, on: app) == 1)
            #expect(try await spare(f, slot: 1, on: app).userID == other)
            #expect(try await APISubmission.find(first.submissionID, on: app.db) == nil, "the failed job goes")
        }
    }

    @Test func aBadPayloadFinishesTheSpareWithNoCredit() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("badpayload", on: app)
            let id = try await student("b_a", slot: 0, f, on: app)
            let slot = try await request(f, for: id, on: app)
            try await finish(f, slot: slot, data: Data([1, 2, 3, 4, 5, 6]).base64EncodedString(), on: app)
            let row = try await spare(f, slot: slot, on: app)
            #expect(row.finished && !row.passed && row.data == nil)
            #expect(try await APIClassItemCoverage.query(on: app.db).count() == 0)
        }
    }

    @Test func theHoldersOwnPassingTileTakesTheCreditBack() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("takeback", on: app)
            let filler = try await student("t_a", slot: 0, f, on: app)
            let holder = try await student("t_b", slot: 1, passed: false, f, on: app)
            try await APICompositeSlot(
                assignmentID: f.assignmentID, userID: try await makeTestStudent(on: app, username: "t_c").requireID(),
                slot: 2, round: 0
            ).create(on: app.db)
            try await APICompositeSlot(
                assignmentID: f.assignmentID, userID: try await makeTestStudent(on: app, username: "t_d").requireID(),
                slot: 3, round: 0
            ).create(on: app.db)
            #expect(try await request(f, for: filler, on: app) == 1)
            try await finish(f, slot: 1, data: sparePixels, on: app)
            let item = CompositeSpec.coverageItem(forSlot: 1)
            #expect(try await APIClassItemCoverage.query(on: app.db).filter(\.$item == item).first()?.userID == filler)

            let sub = try await wrInsertSubmission(id: "sub_t_b2", testSetupID: f.setupID, userID: holder, on: app)
            try await CompositeContributions.record(
                submission: sub, collection: collection("sub_t_b2", setupID: f.setupID, data: ownPixels), on: app.db)
            let coverage = try #require(
                try await APIClassItemCoverage.query(on: app.db).filter(\.$item == item).first())
            #expect(coverage.userID == holder)
            #expect(coverage.submissionID == "sub_t_b2")

            let snapshot = try await CompositeSnapshot.build(
                .init(assignmentID: f.assignmentID, testSetupID: f.setupID, courseID: f.courseID, spec: spec()),
                since: nil, onlyUserID: nil, includeOwners: false, on: app.db)
            #expect(snapshot.pixels.first { $0.slot == 1 }?.data == ownPixels, "the holder's tile wins")
        }
    }

    // MARK: - Grading

    @Test func aSpareIsClaimedAfterStudentsAndBeforeTheCorpusRun() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("claim", on: app)
            let id = try await student("c_a", slot: 0, f, on: app)
            try await request(f, for: id, on: app)
            let path = app.submissionsDirectory + "corpus.py"
            try "".write(toFile: path, atomically: true, encoding: .utf8)
            try await APISubmission(
                id: "corpus_spare", testSetupID: f.setupID, zipPath: path, attemptNumber: 1,
                filename: "corpus.py", userID: nil, kind: APISubmission.Kind.classAggregate
            ).save(on: app.db)
            try await wrInsertSubmission(
                id: "sub_claim_late", testSetupID: f.setupID, userID: id, status: "pending", on: app)
            let kinds = try await collectClaimCandidates(on: app.db).map(\.0.kind)
            #expect(
                kinds == [
                    APISubmission.Kind.student, APISubmission.Kind.compositeSpare, APISubmission.Kind.classAggregate,
                ])
        }
    }

    @Test func aSpareJobGetsItsRowsSlot() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("inputs", on: app)
            let id = try await student("i_a", slot: 0, f, on: app)
            let slot = try await request(f, for: id, on: app)
            let job = try #require(
                try await APISubmission.find(try await spare(f, slot: slot, on: app).submissionID, on: app.db))
            let manifest = try #require(try await setup(f, on: app).decodedManifest())
            let inputs = await CompositeSlots.jobInputs(
                manifest: manifest, courseID: f.courseID, assignmentID: f.assignmentID, submission: job, on: app.db)
            #expect(inputs == spec().inputs(forSlot: slot).mapValues(AssignmentLanguage.python.literal))
        }
    }

    @Test func aPassingSpareCoversItsSlotForTheStudent() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("cover", on: app)
            let id = try await student("v_a", slot: 0, f, on: app)
            let slot = try await request(f, for: id, on: app)
            try await finish(f, slot: slot, data: sparePixels, on: app)
            let row = try await spare(f, slot: slot, on: app)
            #expect(row.passed && row.data == sparePixels)
            let coverage = try await APIClassItemCoverage.query(on: app.db)
                .filter(\.$item == CompositeSpec.coverageItem(forSlot: slot)).all()
            #expect(coverage.map(\.userID) == [id])
            #expect(
                try await CompositeSpares.status(assignmentID: f.assignmentID, userID: id, on: app.db)
                    == [CompositeSpares.Status(slot: slot, grading: false, passed: true)])
        }
    }

    // MARK: - The view

    @Test func aPassingSpareShowsInItsSlotButNotToAStudent() async throws {
        try await withWebRoutesApp { app in
            let f = try await fixture("view", on: app)
            let id = try await student("w_a", slot: 0, f, on: app)
            let failedHolder = try await student("w_b", slot: 1, passed: false, f, on: app)
            #expect(try await request(f, for: id, on: app) == 2)
            try await finish(f, slot: 2, data: sparePixels, on: app)
            // A spare for the failed holder's slot too, made by hand.
            try await APISubmission(
                id: "spare_w1", testSetupID: f.setupID, zipPath: "unused", attemptNumber: 1, filename: nil,
                userID: nil, kind: APISubmission.Kind.compositeSpare
            ).save(on: app.db)
            let handMade = APICompositeSpare(
                assignmentID: f.assignmentID, userID: id, slot: 1, submissionID: "spare_w1")
            handMade.data = sparePixels
            handMade.passed = true
            try await handMade.create(on: app.db)

            let scope = CompositeSnapshot.Scope(
                assignmentID: f.assignmentID, testSetupID: f.setupID, courseID: f.courseID,
                spec: spec(emptySlots: .reference))
            let staff = try await CompositeSnapshot.build(
                scope, since: nil, onlyUserID: nil, includeOwners: false, on: app.db)
            #expect(staff.slots.map(\.state) == ["passed", "passed", "passed"])
            #expect(staff.pixels.map(\.data) == [ownPixels, sparePixels, sparePixels])
            #expect(staff.complete == 3)

            let own = try await CompositeSnapshot.build(
                scope, since: nil, onlyUserID: failedHolder, includeOwners: false, on: app.db)
            #expect(own.slots.map(\.state) == ["failed"])
            #expect(own.complete == 0)
        }
    }

    // MARK: - The result page and the route

    @Test func theResultPageOffersAHoleAndTheRouteQueuesIt() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let me = try await wrStudentUser(on: app)
            try await wrEnrollUser(me, on: app)
            let id = try me.requireID()
            let f = try await fixture("page", on: app)
            try await APICompositeSlot(assignmentID: f.assignmentID, userID: id, slot: 0, round: 0).create(on: app.db)
            try await wrInsertSubmission(id: "sub_page", testSetupID: f.setupID, userID: id, on: app)
            try "print(1)\n".write(
                toFile: app.submissionsDirectory + "sub_page.py", atomically: true, encoding: .utf8)
            let outcome = TestOutcome(
                testName: "tile", testClass: nil, tier: .pub, status: .pass, shortResult: "passed", longResult: nil,
                composite: CompositeContribution(width: 2, height: 1, frames: 1, format: .gray8, data: ownPixels),
                executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: true)
            try await wrInsertResult(submissionID: "sub_page", outcomes: [outcome], on: app)
            try await APICompositeContribution(
                assignmentID: f.assignmentID, userID: id, slot: 0, submissionID: "sub_page", submittedAt: Date(),
                contribution: CompositeContribution(width: 2, height: 1, frames: 1, format: .gray8, data: ownPixels),
                passed: true
            ).create(on: app.db)

            try await app.asyncTest(
                .GET, "/submissions/sub_page",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    let html = res.body.string
                    #expect(html.contains("Fill a hole"))
                    #expect(html.contains("/testsetups/\(f.setupID)/composite/spare"))
                })

            let (csrf, boundCookie) = try await csrfFields(for: "/submissions/sub_page", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/testsetups/\(f.setupID)/composite/spare",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": csrf, "submissionID": "sub_page"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/submissions/sub_page?spare=queued")
                })
            #expect(try await spare(f, slot: 1, on: app).userID == id)

            try await app.asyncTest(
                .GET, "/submissions/sub_page?spare=queued",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    let html = res.body.string
                    #expect(html.contains("Your request to fill a hole is queued."))
                    #expect(html.contains("Spare tile: column 2, row 1"))
                    #expect(!html.contains("Fill a hole"), "one spare at a time")
                })
        }
    }

    @Test func aClosedAssignmentRefusesTheRequest() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let me = try await wrStudentUser(on: app)
            try await wrEnrollUser(me, on: app)
            let f = try await fixture("closed", isOpen: false, on: app)
            let (csrf, boundCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/testsetups/\(f.setupID)/composite/spare",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.headers.first(name: .location) == "/?spare=closed")
                })
            #expect(try await APICompositeSpare.query(on: app.db).count() == 0)
        }
    }

    @Test func aFlashCodeMapsToFixedTextAndAnUnknownCodeToNothing() {
        #expect(SpareFlash.messages(for: "noTile").error == "Your own tile must pass first.")
        #expect(SpareFlash.messages(for: "noHole").error == "Every slot is filled or is being filled.")
        let unknown = SpareFlash.messages(for: "<b>free text</b>")
        #expect(unknown.success == nil && unknown.notice == nil && unknown.error == nil)
    }

    @Test func deletingACourseRemovesTheSpares() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await loginAsAdmin("delete_spare_admin", on: app)
            let f = try await fixture("delete", on: app)
            let id = try await student("d_a", slot: 0, f, on: app)
            try await request(f, for: id, on: app)
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
            #expect(try await APICompositeSpare.query(on: app.db).count() == 0)
            #expect(
                try await APISubmission.query(on: app.db)
                    .filter(\.$kind == APISubmission.Kind.compositeSpare).count() == 0)
        }
    }

    @Test func aRequestForAnotherStudentsSubmissionReturnsToTheDashboard() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let me = try await wrStudentUser(on: app)
            try await wrEnrollUser(me, on: app)
            let f = try await fixture("foreign", on: app)
            try await student("x_other", slot: 1, f, on: app)
            let (csrf, boundCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/testsetups/\(f.setupID)/composite/spare",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": csrf, "submissionID": "sub_x_other"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.headers.first(name: .location) == "/?spare=noTile")
                })
            #expect(try await APICompositeSpare.query(on: app.db).count() == 0)
        }
    }

    @Test func aStudentOutsideTheCourseIsRefused() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let f = try await fixture("outsider", on: app)
            let (csrf, boundCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/testsetups/\(f.setupID)/composite/spare",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .forbidden) })
            #expect(try await APICompositeSpare.query(on: app.db).count() == 0)
        }
    }

    @Test func deletingAStudentRemovesTheirSpareJobs() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await loginAsAdmin("delete_spare_user_admin", on: app)
            let f = try await fixture("deluser", on: app)
            let id = try await student("u_a", slot: 0, f, on: app)
            let slot = try await request(f, for: id, on: app)
            let job = try #require(
                try await APISubmission.find(try await spare(f, slot: slot, on: app).submissionID, on: app.db))

            let (token, boundCookie) = try await csrfFields(for: "/admin", cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "/admin/users/\(id.uuidString)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            #expect(try await APIUser.find(id, on: app.db) == nil)
            #expect(try await APISubmission.find(try job.requireID(), on: app.db) == nil)
            #expect(!FileManager.default.fileExists(atPath: job.zipPath), "the copy of their code goes")
        }
    }
}
