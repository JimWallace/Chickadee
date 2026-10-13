// Tests/APITests/CompositeSlotsTests.swift
//
// Dealing a class composite's slots and delivering them to the grader
// (docs/class-composite.md, slice 3): the deal order, the second round, a
// freed slot dealt again, a race, the lock a deal sets, the inputs on the
// grading paths, and the deal on first open.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct CompositeSlotsTests {

    private func spec(columns: Int = 3, rows: Int = 2, order: CompositeDealOrder = .rowMajor) -> CompositeSpec {
        CompositeSpec(
            compositor: .tile, layout: .grid(columns: columns, rows: rows),
            contribution: CompositeContributionShape(width: 4, height: 4, frames: 1, format: .gray8),
            dealOrder: order)
    }

    private func compositeManifest(_ spec: CompositeSpec, language: AssignmentLanguage? = .python) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "tile.py")],
            language: language,
            activity: ClassActivity(kind: .classComposite, composite: spec))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private struct Fixture {
        let assignment: APIAssignment
        let assignmentID: UUID
        let courseID: UUID
        let setup: APITestSetup
    }

    private func fixture(
        _ spec: CompositeSpec, setupID: String = "setup_slots", on app: Application
    ) async throws
        -> Fixture
    {
        let course = try await makeTestCourse(on: app, code: "CS135", name: "Designing Programs")
        let courseID = try course.requireID()
        let setup = try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: try compositeManifest(spec))
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        return Fixture(
            assignment: assignment, assignmentID: try assignment.requireID(), courseID: courseID, setup: setup)
    }

    private func students(_ count: Int, on app: Application) async throws -> [UUID] {
        var ids: [UUID] = []
        for index in 0..<count {
            ids.append(try await makeTestStudent(on: app, username: "slot_student_\(index)").requireID())
        }
        return ids
    }

    // MARK: - Dealing

    @Test func slotsAreDealtInOrderAndDoNotChange() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let spec = spec()
            let f = try await fixture(spec, on: app)
            let ids = try await students(3, on: app)
            var dealt: [Int] = []
            for id in ids {
                dealt.append(
                    try await CompositeSlots.slot(assignmentID: f.assignmentID, userID: id, spec: spec, on: app.db))
            }
            #expect(dealt == [0, 1, 2])
            let again = try await CompositeSlots.slot(
                assignmentID: f.assignmentID, userID: ids[0], spec: spec, on: app.db)
            #expect(again == 0, "a dealt slot does not change")
        }
    }

    /// More students than slots: the second round starts only when the first
    /// is full, and repeats the order.
    @Test func aSecondRoundStartsWhenEverySlotIsTaken() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let spec = spec(columns: 2, rows: 1)
            let f = try await fixture(spec, on: app)
            var dealt: [Int] = []
            for id in try await students(3, on: app) {
                dealt.append(
                    try await CompositeSlots.slot(assignmentID: f.assignmentID, userID: id, spec: spec, on: app.db))
            }
            #expect(dealt == [0, 1, 0])
            let rounds = try await APICompositeSlot.query(on: app.db).all().map(\.round).sorted()
            #expect(rounds == [0, 0, 1])
        }
    }

    @Test func aFreedSlotIsDealtAgain() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let spec = spec()
            let f = try await fixture(spec, on: app)
            let ids = try await students(3, on: app)
            for id in ids.prefix(2) {
                _ = try await CompositeSlots.slot(assignmentID: f.assignmentID, userID: id, spec: spec, on: app.db)
            }
            try await APICompositeSlot.query(on: app.db).filter(\.$userID == ids[0]).delete()
            let next = try await CompositeSlots.slot(
                assignmentID: f.assignmentID, userID: ids[2], spec: spec, on: app.db)
            #expect(next == 0)
        }
    }

    /// Students who open the page at the same moment each get their own slot.
    @Test func concurrentDealsGiveEveryStudentADifferentSlot() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let spec = spec()
            let f = try await fixture(spec, on: app)
            let ids = try await students(6, on: app)
            let dealt = try await withThrowingTaskGroup(of: Int.self) { group in
                for id in ids {
                    group.addTask {
                        try await CompositeSlots.slot(assignmentID: f.assignmentID, userID: id, spec: spec, on: app.db)
                    }
                }
                return try await group.reduce(into: [Int]()) { $0.append($1) }
            }
            #expect(dealt.sorted() == [0, 1, 2, 3, 4, 5])
        }
    }

    // MARK: - The lock

    /// A dealt slot locks the structure before any student has submitted.
    @Test func aDealtSlotLocksTheStructure() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let spec = spec()
            let f = try await fixture(spec, on: app)
            #expect(try await !ActivityAuthoring.compositeStructureLocked(setup: f.setup, on: app.db))
            let id = try await students(1, on: app)[0]
            _ = try await CompositeSlots.slot(assignmentID: f.assignmentID, userID: id, spec: spec, on: app.db)
            #expect(try await ActivityAuthoring.compositeStructureLocked(setup: f.setup, on: app.db))

            let current = try #require(f.setup.decodedManifest()?.activity)
            await #expect(throws: AppError.self) {
                try await ActivityAuthoring.setActivity(
                    setup: f.setup, to: current.withComposite(self.spec(columns: 4)), on: app.db)
            }
            // The display settings stay editable.
            let display = spec.withDisplay(frameRate: 30, showFailed: false, emptySlots: .blank)
            try await ActivityAuthoring.setActivity(setup: f.setup, to: current.withComposite(display), on: app.db)
            #expect(f.setup.decodedManifest()?.activity?.composite == display)
        }
    }

    @Test func aCompositeIsRefusedOnAnAssignmentWithNoLanguage() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS135", name: "Designing Programs")
            let manifest = #"{"schemaVersion":1,"languageDeclared":true,"testSuites":[],"timeLimitSeconds":10}"#
            let setup = try await makeTestSetup(
                on: app, id: "setup_none", courseID: try course.requireID(), manifest: manifest)
            do {
                try await ActivityAuthoring.setActivity(
                    setup: setup, to: ClassActivity(kind: .classComposite), on: app.db)
                Issue.record("a composite on an assignment with no language was accepted")
            } catch let error as AppError {
                #expect(error.reason == ActivityAuthoring.compositeNeedsLanguageMessage)
            }
            #expect(setup.decodedManifest()?.activity == nil)
        }
    }

    // MARK: - Delivery to the grader

    @Test func aStudentRunCarriesTheDealtSlotAsPythonLiterals() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let spec = spec(columns: 3, rows: 2)
            let f = try await fixture(spec, on: app)
            let ids = try await students(5, on: app)
            for id in ids {
                _ = try await CompositeSlots.slot(assignmentID: f.assignmentID, userID: id, spec: spec, on: app.db)
            }
            let manifest = try #require(f.setup.decodedManifest())
            let inputs = await CompositeSlots.gradingInputs(
                manifest: manifest, language: .python, assignmentID: f.assignmentID, userID: ids[4],
                usesReferenceSlot: false, logger: app.logger, on: app.db)
            #expect(inputs == ["composite_slot": "4", "composite_col": "1", "composite_row": "1"])
        }
    }

    @Test func aValidationRunGetsSlotZeroAndDealsNothing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(spec(), on: app)
            let manifest = try #require(f.setup.decodedManifest())
            let inputs = await CompositeSlots.gradingInputs(
                manifest: manifest, language: .python, assignmentID: f.assignmentID, userID: nil,
                usesReferenceSlot: true, logger: app.logger, on: app.db)
            #expect(inputs?["composite_slot"] == "0")
            #expect(try await APICompositeSlot.query(on: app.db).count() == 0)
        }
    }

    /// Never fail while grading: with no language there is no inputs file,
    /// so the composite inputs are left out rather than refused.
    @Test func noLanguageOrAnotherKindCarriesNoCompositeInputs() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(spec(), on: app)
            let manifest = try #require(f.setup.decodedManifest())
            let id = try await students(1, on: app)[0]
            #expect(
                await CompositeSlots.gradingInputs(
                    manifest: manifest, language: nil, assignmentID: f.assignmentID, userID: id,
                    usesReferenceSlot: false, logger: app.logger, on: app.db) == nil)
            var other = manifest
            other.activity = ClassActivity(kind: .bestMetric)
            #expect(
                await CompositeSlots.gradingInputs(
                    manifest: other, language: .python, assignmentID: f.assignmentID, userID: id,
                    usesReferenceSlot: false, logger: app.logger, on: app.db) == nil)
        }
    }

    @Test func compositeInputsWinAClashAndKeepTheOthers() {
        let merged = CompositeSlots.merged(
            ["offset": "3", "composite_slot": "99"], with: ["composite_slot": "4"])
        #expect(merged == ["offset": "3", "composite_slot": "4"])
        #expect(CompositeSlots.merged(nil, with: nil) == nil)
        #expect(CompositeSlots.merged(["offset": "3"], with: nil) == ["offset": "3"])
    }

    // MARK: - Dealing on open

    @Test func dealOnOpenDealsOnlyInsideTheWindow() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let spec = spec()
            let f = try await fixture(spec, on: app)
            let id = try await students(1, on: app)[0]
            let closed = ClassActivity(
                kind: .classComposite,
                window: LiveSessionWindow(opensAt: Date(timeIntervalSinceNow: 3_600), closesAt: nil),
                composite: spec)
            var props = try #require(f.setup.decodedManifest())
            props.activity = closed
            f.setup.manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))

            await CompositeSlots.dealOnOpen(
                setup: f.setup, assignment: f.assignment, userID: id, logger: app.logger, on: app.db)
            #expect(try await APICompositeSlot.query(on: app.db).count() == 0, "the window has not opened")

            await CompositeSlots.dealOnOpen(
                setup: f.setup, assignment: f.assignment, userID: id, now: Date(timeIntervalSinceNow: 7_200),
                logger: app.logger, on: app.db)
            #expect(try await APICompositeSlot.query(on: app.db).count() == 1)
        }
    }

    /// Opening the notebook page deals a student a slot; staff are not dealt.
    @Test func openingTheNotebookPageDealsAStudentButNotStaff() async throws {
        try await withWebRoutesApp { app in
            let studentCookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            let staffCookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            try await wrInsertSetup(id: "setup_open", manifest: try compositeManifest(spec()), on: app)
            try await wrInsertAssignment(testSetupID: "setup_open", title: "Class GPU", isOpen: true, on: app)

            for cookie in [staffCookie, studentCookie] {
                try await app.asyncTest(
                    .GET, "/testsetups/setup_open/notebook",
                    beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                    afterResponse: { _ in })
            }
            let rows = try await APICompositeSlot.query(on: app.db).all()
            #expect(rows.map(\.userID) == [try student.requireID()])
        }
    }

    /// The browser grader receives the slot from the seed endpoint, in the
    /// same inputs the worker writes to `_ck_inputs.py`.
    @Test func theBrowserSeedEndpointCarriesTheStudentsSlot() async throws {
        try await withWebRoutesApp { app in
            let studentCookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            try await wrInsertSetup(id: "setup_seed", manifest: try compositeManifest(spec()), on: app)
            try await wrInsertAssignment(testSetupID: "setup_seed", title: "Class GPU", isOpen: true, on: app)

            try await app.asyncTest(
                .GET, "/api/v1/browser-runner/testsetups/setup_seed/seed",
                beforeRequest: { req in req.headers.add(name: .cookie, value: studentCookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(BrowserRunnerSeedResponse.self)
                    #expect(body.personalizedInputs?["composite_slot"] == "0")
                    #expect(body.personalizedInputs?["composite_col"] == "0")
                    #expect(body.language == "python")
                })
            #expect(try await APICompositeSlot.query(on: app.db).count() == 1)
        }
    }

    /// Staff grading in the browser get the reference slot and take no
    /// student's slot.
    @Test func staffOnTheSeedEndpointGetSlotZeroAndAreNotDealt() async throws {
        try await withWebRoutesApp { app in
            let staffCookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)
            try await wrInsertSetup(id: "setup_staff", manifest: try compositeManifest(spec()), on: app)
            try await wrInsertAssignment(testSetupID: "setup_staff", title: "Class GPU", isOpen: true, on: app)

            try await app.asyncTest(
                .GET, "/api/v1/browser-runner/testsetups/setup_staff/seed",
                beforeRequest: { req in req.headers.add(name: .cookie, value: staffCookie) },
                afterResponse: { res in
                    let body = try res.content.decode(BrowserRunnerSeedResponse.self)
                    #expect(body.personalizedInputs?["composite_slot"] == "0")
                })
            #expect(try await APICompositeSlot.query(on: app.db).count() == 0)
        }
    }
}
