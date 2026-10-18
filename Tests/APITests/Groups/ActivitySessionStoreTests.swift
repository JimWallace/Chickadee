// Tests/APITests/Groups/ActivitySessionStoreTests.swift
//
// The sessions of per-group class activities (docs/lab-groups.md, slice 2):
// the code's alphabet and uniqueness, start, end and reopen, joining by code,
// which session a student plays in, and the joins in a data export.

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

    // MARK: - The code

    @Test func aCodeIsFiveCharactersWithNoLookAlikes() {
        for _ in 0..<200 {
            let code = ActivitySessionStore.newCode()
            #expect(code.count == 5)
            #expect(code.allSatisfy(ActivitySessionStore.codeAlphabet.contains))
        }
        for confusable in "0O1IL2Z5S8B" {
            #expect(!ActivitySessionStore.codeAlphabet.contains(confusable))
        }
    }

    @Test func twoSessionsNeverShareACode() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let a = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, on: app.db)
            let b = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labB, by: nil, on: app.db)
            #expect(a.joinCode != b.joinCode)
            // The database refuses a duplicate too.
            b.joinCode = a.joinCode
            await #expect(throws: (any Error).self) { try await b.save(on: app.db) }
        }
    }

    // MARK: - Start, end, reopen

    @Test func aReopenKeepsTheRowAndDrawsANewCode() async throws {
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

            let firstCode = first.joinCode
            let again = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, now: start.addingTimeInterval(120), on: app.db)
            #expect(again.id == first.id, "one row per assignment and group")
            #expect(again.closedAt == nil)
            #expect(again.joinCode != firstCode, "an earlier lab's code does not open the next one")
            #expect(try await ActivitySessionStore.sessions(assignmentID: f.assignmentID, on: app.db).count == 1)
        }
    }

    @Test func startingAnOpenSessionKeepsItsCode() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let start = Date(timeIntervalSince1970: 1_000_000)
            let first = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, now: start, on: app.db)
            let second = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: f.ada, now: start.addingTimeInterval(30), on: app.db)
            #expect(second.joinCode == first.joinCode, "a second Start does not change the code on the screen")
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
            let code = session.joinCode.lowercased()
            try await ActivitySessionStore.join(code: " \(code) ", userID: f.grace, on: app.db)
            try await ActivitySessionStore.join(code: session.joinCode, userID: f.grace, on: app.db)

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
            try await ActivitySessionStore.join(code: session.joinCode, userID: f.ada, on: app.db)
            let byUser = try await CourseGroupStore.groupIDsByUser(inSet: f.set.requireID(), on: app.db)
            #expect(byUser[f.ada] == f.labA, "attendance does not move a member")
        }
    }

    @Test func aWrongCodeAClosedSessionAndAnOutsiderAreRefused() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let session = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, on: app.db)
            await #expect(throws: ActivitySessionError.unknownCode) {
                try await ActivitySessionStore.join(code: "XXXXX", userID: f.grace, on: app.db)
            }
            let outsider = try await makeTestStudent(on: app, username: "outsider").requireID()
            await #expect(throws: ActivitySessionError.notAStudent) {
                try await ActivitySessionStore.join(code: session.joinCode, userID: outsider, on: app.db)
            }
            try await ActivitySessionStore.close(session, on: app.db)
            await #expect(throws: ActivitySessionError.sessionClosed) {
                try await ActivitySessionStore.join(
                    code: session.joinCode, userID: f.grace, now: Date().addingTimeInterval(1), on: app.db)
            }
        }
    }

    @Test func aRemovedGroupOrAnActivityNoLongerPerGroupRefusesAJoin() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let labB = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labB, by: nil, on: app.db)
            let group = try #require(try await APICourseGroup.find(f.labB, on: app.db))
            try await CourseGroupStore.removeGroup(group, of: f.set, on: app.db)
            await #expect(throws: ActivitySessionError.sessionClosed) {
                try await ActivitySessionStore.join(code: labB.joinCode, userID: f.grace, on: app.db)
            }

            let labA = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, on: app.db)
            let setup = try #require(try await APITestSetup.find("sess_setup", on: app.db))
            let activity = try #require(setup.decodedManifest()?.activity)
            try await ActivityAuthoring.setActivity(setup: setup, to: activity.withRunsPerGroup(false), on: app.db)
            await #expect(throws: ActivitySessionError.sessionClosed) {
                try await ActivitySessionStore.join(code: labA.joinCode, userID: f.grace, on: app.db)
            }
            let ended = try await ActivitySessionStore.session(
                assignmentID: f.assignmentID, groupID: f.labA, on: app.db)
            #expect(ended?.closedAt != nil, "turning the flag off ends the open sessions")

            // On again: Start draws a new code, so the earlier lab's code
            // stays dead.
            try await ActivityAuthoring.setActivity(setup: setup, to: activity, on: app.db)
            let reopened = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, now: Date().addingTimeInterval(1), on: app.db)
            #expect(reopened.joinCode != labA.joinCode)
        }
    }

    // MARK: - The student's session

    @Test func aStudentPlaysInTheSessionTheyJoinedElseTheirGroups() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            func current(_ user: UUID) async throws -> UUID? {
                try await ActivitySessionStore.currentSession(
                    assignmentID: f.assignmentID, courseID: f.courseID, userID: user, on: app.db)?.groupID
            }
            #expect(try await current(f.ada) == nil, "no session is open yet")

            let labA = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, on: app.db)
            #expect(try await current(f.ada) == f.labA, "a member plays in their group's open session")
            #expect(try await current(f.alan) == nil, "Lab 102 has not started")
            #expect(try await current(f.grace) == nil, "a student in no group has no session")

            try await ActivitySessionStore.join(code: labA.joinCode, userID: f.alan, on: app.db)
            #expect(try await current(f.alan) == f.labA, "the code puts alan in Lab 101's session")

            _ = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labB, by: nil, on: app.db)
            #expect(try await current(f.alan) == f.labA, "attendance beats membership")

            try await ActivitySessionStore.close(labA, on: app.db)
            #expect(
                try await ActivitySessionStore.currentSession(
                    assignmentID: f.assignmentID, courseID: f.courseID, userID: f.alan,
                    now: Date().addingTimeInterval(1), on: app.db)?.groupID == f.labB,
                "once the joined session ends, alan's own group's session is theirs")
        }
    }

    @Test func aSecondJoinMovesTheStudentBackAndAnEarlierLabsJoinDoesNotCount() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let start = Date(timeIntervalSince1970: 1_000_000)
            func current(at offset: TimeInterval) async throws -> UUID? {
                try await ActivitySessionStore.currentSession(
                    assignmentID: f.assignmentID, courseID: f.courseID, userID: f.ada,
                    now: start.addingTimeInterval(offset), on: app.db)?.groupID
            }
            let labA = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labA, by: nil, now: start, on: app.db)
            let labB = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labB, by: nil, now: start, on: app.db)
            try await ActivitySessionStore.join(
                code: labB.joinCode, userID: f.ada, now: start.addingTimeInterval(10), on: app.db)
            #expect(try await current(at: 11) == f.labB)
            try await ActivitySessionStore.join(
                code: labA.joinCode, userID: f.ada, now: start.addingTimeInterval(20), on: app.db)
            #expect(try await current(at: 21) == f.labA, "the latest join wins")
            try await ActivitySessionStore.join(
                code: labB.joinCode, userID: f.ada, now: start.addingTimeInterval(30), on: app.db)
            #expect(try await current(at: 31) == f.labB, "a second join moves the student back")

            // Lab 102 ends and starts again for its next lab: ada's join to the
            // earlier lab no longer counts, so ada plays in their own group's.
            try await ActivitySessionStore.close(labB, now: start.addingTimeInterval(40), on: app.db)
            _ = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labB, by: nil, now: start.addingTimeInterval(50), on: app.db)
            #expect(try await current(at: 51) == f.labA)
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
            try await ActivitySessionStore.join(code: session.joinCode, userID: f.ada, now: joinedAt, on: app.db)
            let student = try #require(try await APIUser.find(f.ada, on: app.db))
            let assignment = try #require(try await APIAssignment.find(f.assignmentID, on: app.db))
            let content = try await gatherDataExportContent(for: student, on: app.db)
            #expect(
                content.enrollments.first?.sessionsJoined
                    == [DataExportSessionJoin(assignment: assignment.title, group: "Lab 102", joinedAt: joinedAt)])
        }
    }
}
