// Tests/APITests/Groups/ActivitySessionStoreTests.swift
//
// The sessions of per-group class activities (docs/lab-groups.md, slice 2 and
// "Presence"): start, end and reopen, joining by the changing code, which
// session a student plays in, removal by staff, the limit on wrong codes, and
// the joins in a data export. The code itself is in ActivitySessionCodeTests.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct ActivitySessionStoreTests {

    private struct Fixture {
        let courseID: UUID
        let assignmentID: UUID
        let set: APICourseGroupSet
        let labA: UUID
        let labB: UUID
        let ada: UUID
        let alan: UUID
        let grace: UUID
    }

    /// A course with two groups; ada in Lab 101, alan in Lab 102, grace in none.
    private func fixture(on app: Application) async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "CS135", name: "Designing Programs")
        let courseID = try course.requireID()
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")], language: nil,
            activity: ClassActivity(kind: .bestMetric, runsPerGroup: true))
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        try await makeTestSetup(on: app, id: "sess_setup", courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(on: app, testSetupID: "sess_setup", courseID: courseID)
        var students: [UUID] = []
        for name in ["ada", "alan", "grace"] {
            let id = try await makeTestStudent(on: app, username: name).requireID()
            try await makeTestEnrollment(on: app, userID: id, courseID: courseID)
            students.append(id)
        }
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
        let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
        let labB = try await CourseGroupStore.addGroup(named: "Lab 102", to: set, on: app.db).requireID()
        try await CourseGroupStore.setMembership(userID: students[0], groupID: labA, in: set, on: app.db)
        try await CourseGroupStore.setMembership(userID: students[1], groupID: labB, in: set, on: app.db)
        return Fixture(
            courseID: courseID, assignmentID: try assignment.requireID(), set: set, labA: labA, labB: labB,
            ada: students[0], alan: students[1], grace: students[2])
    }

    /// The code a session shows at `date`, as the projector does.
    private func code(_ session: APIActivitySession, at date: Date = Date()) -> String {
        ActivitySessionCode.code(secret: session.codeSecret, at: date)
    }

    // MARK: - Start, end, reopen

    @Test func aReopenKeepsTheRowAndDrawsANewSecret() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let start = Date(timeIntervalSince1970: 1_000_000)
            let first = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: f.ada, now: start, on: app.db)
            #expect(first.isOpen(at: start))
            try await ActivitySessionStore.close(first, now: start.addingTimeInterval(60), on: app.db)
            #expect(!first.isOpen(at: start.addingTimeInterval(60)), "the closing instant is outside")
            #expect(first.isOpen(at: start.addingTimeInterval(59)))

            let firstSecret = first.codeSecret
            let again = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, now: start.addingTimeInterval(120), on: app.db)
            #expect(again.id == first.id, "one row per assignment and group")
            #expect(again.closedAt == nil)
            #expect(again.codeSecret != firstSecret, "no code of an earlier lab opens the next one")
            #expect(try await ActivitySessionStore.sessions(assignmentID: f.assignmentID, on: app.db).count == 1)
        }
    }

    @Test func startingAnOpenSessionKeepsItsSecret() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let start = Date(timeIntervalSince1970: 1_000_000)
            let first = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, now: start, on: app.db)
            let second = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: f.ada, now: start.addingTimeInterval(30), on: app.db)
            #expect(second.codeSecret == first.codeSecret, "a second Start does not change the code on the screen")
            #expect(second.openedAt == start)
        }
    }

    // MARK: - Joining

    @Test func joiningRecordsAttendanceAndPlacesAStudentInNoGroup() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let session = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labB, by: nil, on: app.db)
            try await ActivitySessionStore.join(code: " \(code(session).lowercased()) ", userID: f.grace, on: app.db)
            try await ActivitySessionStore.join(code: code(session), userID: f.grace, on: app.db)

            let attendance = try await APIActivitySessionAttendance.query(on: app.db)
                .filter(\.$userID == f.grace).count()
            #expect(attendance == 1, "a second join is the same attendance")
            let byUser = try await CourseGroupStore.groupIDsByUser(inSet: f.set.requireID(), on: app.db)
            #expect(byUser[f.grace] == f.labB, "a student in no group joins the session's group")
        }
    }

    @Test func joiningAnotherLabKeepsTheStudentsOwnGroup() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let session = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labB, by: nil, on: app.db)
            try await ActivitySessionStore.join(code: code(session), userID: f.ada, on: app.db)
            let byUser = try await CourseGroupStore.groupIDsByUser(inSet: f.set.requireID(), on: app.db)
            #expect(byUser[f.ada] == f.labA, "attendance does not move a member")
        }
    }

    @Test func aWrongCodeAnOldCodeAClosedSessionAndAnOutsiderAreRefused() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let now = Date()
            let session = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, now: now.addingTimeInterval(-300), on: app.db)
            await #expect(throws: ActivitySessionError.unknownCode) {
                try await ActivitySessionStore.join(code: "XXXXX", userID: f.grace, now: now, on: app.db)
            }
            let stale = code(session, at: now.addingTimeInterval(-120))
            if stale != code(session, at: now) && stale != code(session, at: now.addingTimeInterval(-30)) {
                await #expect(throws: ActivitySessionError.unknownCode, "a code read two minutes ago") {
                    try await ActivitySessionStore.join(code: stale, userID: f.grace, now: now, on: app.db)
                }
            }
            let outsider = try await makeTestStudent(on: app, username: "outsider").requireID()
            await #expect(throws: ActivitySessionError.notAStudent) {
                try await ActivitySessionStore.join(
                    code: code(session, at: now), userID: outsider, now: now, on: app.db)
            }
            try await ActivitySessionStore.close(session, now: now, on: app.db)
            await #expect(throws: ActivitySessionError.unknownCode, "an ended session shows no code") {
                try await ActivitySessionStore.join(code: code(session, at: now), userID: f.grace, now: now, on: app.db)
            }
        }
    }

    @Test func turningTheFlagOffEndsTheSessions() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let labA = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, on: app.db)
            let setup = try #require(try await APITestSetup.find("sess_setup", on: app.db))
            let activity = try #require(setup.decodedManifest()?.activity)
            try await ActivityAuthoring.setActivity(setup: setup, to: activity.withRunsPerGroup(false), on: app.db)
            let ended = try await ActivitySessionStore.session(
                assignmentID: f.assignmentID, groupID: f.labA, on: app.db)
            #expect(ended?.closedAt != nil, "turning the flag off ends the open sessions")
            await #expect(throws: ActivitySessionError.unknownCode) {
                try await ActivitySessionStore.join(code: code(labA), userID: f.grace, on: app.db)
            }

            // On again: Start draws a new secret, so the earlier lab's codes
            // stay dead.
            try await ActivityAuthoring.setActivity(setup: setup, to: activity, on: app.db)
            let reopened = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, now: Date().addingTimeInterval(1), on: app.db)
            #expect(reopened.codeSecret != labA.codeSecret)
        }
    }

    @Test func removingAGroupEndsItsSession() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let labB = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labB, by: nil, on: app.db)
            let group = try #require(try await APICourseGroup.find(f.labB, on: app.db))
            try await CourseGroupStore.removeGroup(group, of: f.set, on: app.db)
            await #expect(throws: ActivitySessionError.unknownCode) {
                try await ActivitySessionStore.join(code: code(labB), userID: f.grace, on: app.db)
            }
        }
    }

    // MARK: - The student's session

    @Test func onlyAStudentWhoJoinedPlays() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            func current(_ user: UUID, at date: Date = Date()) async throws -> UUID? {
                try await ActivitySessionStore.currentSession(
                    assignmentID: f.assignmentID, userID: user, now: date, on: app.db)?.groupID
            }
            let labA = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, on: app.db)
            #expect(try await current(f.ada) == nil, "membership alone is not presence")

            try await ActivitySessionStore.join(code: code(labA), userID: f.ada, on: app.db)
            #expect(try await current(f.ada) == f.labA)
            try await ActivitySessionStore.join(code: code(labA), userID: f.alan, on: app.db)
            #expect(try await current(f.alan) == f.labA, "the code puts alan in Lab 101's session")

            try await ActivitySessionStore.close(labA, on: app.db)
            #expect(try await current(f.ada, at: Date().addingTimeInterval(1)) == nil, "an ended session has no one")
        }
    }

    @Test func aSecondJoinMovesTheStudentBackAndAnEarlierLabsJoinDoesNotCount() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let start = Date(timeIntervalSince1970: 1_000_000)
            func at(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }
            func current(at offset: TimeInterval) async throws -> UUID? {
                try await ActivitySessionStore.currentSession(
                    assignmentID: f.assignmentID, userID: f.ada, now: at(offset), on: app.db)?.groupID
            }
            let labA = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, now: start, on: app.db)
            let labB = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labB, by: nil, now: start, on: app.db)
            try await ActivitySessionStore.join(code: code(labB, at: at(10)), userID: f.ada, now: at(10), on: app.db)
            #expect(try await current(at: 11) == f.labB)
            try await ActivitySessionStore.join(code: code(labA, at: at(20)), userID: f.ada, now: at(20), on: app.db)
            #expect(try await current(at: 21) == f.labA, "the latest join wins")
            try await ActivitySessionStore.join(code: code(labB, at: at(30)), userID: f.ada, now: at(30), on: app.db)
            #expect(try await current(at: 31) == f.labB, "a second join moves the student back")

            // Lab 102 ends and starts again for its next lab: ada's join to the
            // earlier lab no longer counts, so ada plays in Lab 101's.
            try await ActivitySessionStore.close(labB, now: at(40), on: app.db)
            _ = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labB, by: nil, now: at(50), on: app.db)
            #expect(try await current(at: 51) == f.labA)
        }
    }

    // MARK: - Removal and wrong codes

    @Test func aRemovedStudentStopsPlayingAndCannotRejoinThisRun() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let start = Date().addingTimeInterval(-60)
            let session = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, now: start, on: app.db)
            try await ActivitySessionStore.join(code: code(session), userID: f.ada, on: app.db)
            #expect(try await ActivitySessionStore.joinedCount(of: session, on: app.db) == 1)

            try await ActivitySessionStore.remove(userID: f.ada, from: session, on: app.db)
            #expect(try await ActivitySessionStore.joinedCount(of: session, on: app.db) == 0)
            #expect(
                try await ActivitySessionStore.currentSession(assignmentID: f.assignmentID, userID: f.ada, on: app.db)
                    == nil)
            await #expect(throws: ActivitySessionError.removed) {
                try await ActivitySessionStore.join(code: code(session), userID: f.ada, on: app.db)
            }
            let rows = try await ActivitySessionStore.attendance(of: session, on: app.db)
            #expect(rows.count == 1 && rows.first?.removedAt != nil, "staff still see who they removed")

            // The next run of the session starts clean.
            try await ActivitySessionStore.close(session, on: app.db)
            let next = Date().addingTimeInterval(1)
            let reopened = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, now: next, on: app.db)
            let later = next.addingTimeInterval(1)
            try await ActivitySessionStore.join(
                code: code(reopened, at: later), userID: f.ada, now: later, on: app.db)
            #expect(try await ActivitySessionStore.joinedCount(of: reopened, on: app.db) == 1)
        }
    }

    @Test func removingAStudentUndoesTheGroupTheirJoinGaveThem() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let session = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labB, by: nil, on: app.db)
            try await ActivitySessionStore.join(code: code(session), userID: f.grace, on: app.db)
            try await ActivitySessionStore.join(code: code(session), userID: f.ada, on: app.db)
            #expect(try await ActivitySessionStore.remove(userID: f.grace, from: session, on: app.db))
            #expect(try await ActivitySessionStore.remove(userID: f.ada, from: session, on: app.db))
            #expect(
                try await !ActivitySessionStore.remove(userID: f.ada, from: session, on: app.db),
                "a second Remove changes nothing")

            let byUser = try await CourseGroupStore.groupIDsByUser(inSet: f.set.requireID(), on: app.db)
            #expect(byUser[f.grace] == nil, "the join placed grace in Lab 102, so Remove takes grace out")
            #expect(byUser[f.ada] == f.labA, "ada's own group is not the join's to undo")
        }
    }

    @Test func tooManyWrongCodesStopJoiningForAWhile() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let session = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, on: app.db)
            for _ in 0..<ActivitySessionStore.joinFailureLimit {
                await #expect(throws: ActivitySessionError.unknownCode) {
                    try await ActivitySessionStore.join(code: "XXXXX", userID: f.grace, on: app.db)
                }
            }
            await #expect(throws: ActivitySessionError.tooManyAttempts, "even the right code") {
                try await ActivitySessionStore.join(code: code(session), userID: f.grace, on: app.db)
            }
            try await ActivitySessionStore.join(code: code(session), userID: f.ada, on: app.db)

            let afterWindow = Date().addingTimeInterval(ActivitySessionStore.joinFailureWindow + 1)
            try await ActivitySessionStore.join(
                code: code(session, at: afterWindow), userID: f.grace, now: afterWindow, on: app.db)
        }
    }

    // MARK: - Data export

    @Test func aStudentsDataExportListsTheSessionsTheyJoined() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let session = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labB, by: nil, on: app.db)
            // A whole second, so the time survives the database's precision.
            let joinedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 1).rounded())
            try await ActivitySessionStore.join(
                code: code(session, at: joinedAt), userID: f.ada, now: joinedAt, on: app.db)
            let student = try #require(try await APIUser.find(f.ada, on: app.db))
            let assignment = try #require(try await APIAssignment.find(f.assignmentID, on: app.db))
            let content = try await gatherDataExportContent(for: student, on: app.db)
            #expect(
                content.enrollments.first?.sessionsJoined
                    == [DataExportSessionJoin(assignment: assignment.title, group: "Lab 102", joinedAt: joinedAt)])

            let removedAt = joinedAt.addingTimeInterval(5)
            try await ActivitySessionStore.remove(userID: f.ada, from: session, now: removedAt, on: app.db)
            let after = try await gatherDataExportContent(for: student, on: app.db)
            #expect(after.enrollments.first?.sessionsJoined.first?.removedAt == removedAt, "a removal is exported")
        }
    }
}
