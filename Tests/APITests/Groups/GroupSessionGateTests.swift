// Tests/APITests/Groups/GroupSessionGateTests.swift
//
// A per-group activity's submission gate and its authoring rules
// (docs/lab-groups.md, slices 2 and 3a, and "Presence"). The gate: no student
// submits before joining one of the activity's sessions by code, a member of
// the group included; a member joins only their own lab's session; a student
// who joined still submits after the close; staff are never gated.
// Then the refusals at save, on the web path and through set_activity, and
// what a clone and an import keep.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct GroupSessionGateTests {

    private struct Fixture {
        let courseID: UUID
        let setupID: String
        let assignment: APIAssignment
        let labA: UUID
        let labB: UUID
        let member: APIUser
        let other: APIUser
        let loner: APIUser
        let staff: APIUser
    }

    private func manifest(runsPerGroup: Bool) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")], language: nil,
            activity: ClassActivity(kind: .bestMetric, runsPerGroup: runsPerGroup))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// An open per-group assignment: `member` in Lab 101, `other` in Lab 102,
    /// `loner` in no group, and an instructor.
    private func fixture(_ app: Application, prefix: String) async throws -> Fixture {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
        let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
        let labB = try await CourseGroupStore.addGroup(named: "Lab 102", to: set, on: app.db).requireID()
        let setupID = "\(prefix)_setup"
        try await APITestSetup(
            id: setupID, manifest: try manifest(runsPerGroup: true),
            zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID
        ).save(on: app.db)
        let assignment = try await arInsertAssignment(
            testSetupID: setupID, title: "Lab \(prefix)", isOpen: true, on: app)
        var students: [APIUser] = []
        for name in ["member", "other", "loner"] {
            let student = try await arInsertStudent(username: "\(prefix)_\(name)", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            students.append(student)
        }
        try await CourseGroupStore.setMembership(userID: students[0].requireID(), groupID: labA, in: set, on: app.db)
        try await CourseGroupStore.setMembership(userID: students[1].requireID(), groupID: labB, in: set, on: app.db)
        let staff = try await arInsertStudent(username: "\(prefix)_staff", on: app)
        try await APICourseEnrollment(userID: try staff.requireID(), courseID: courseID, role: .instructor)
            .save(on: app.db)
        return Fixture(
            courseID: courseID, setupID: setupID, assignment: assignment, labA: labA, labB: labB,
            member: students[0], other: students[1], loner: students[2], staff: staff)
    }

    private func gate(_ app: Application, _ f: Fixture, _ user: APIUser) async throws {
        _ = try await requireOpenStudentAssignment(
            for: f.setupID, user: user, gate: .submission, on: makeTestRequest(on: app))
    }

    private func refusal(_ app: Application, _ f: Fixture, _ user: APIUser) async -> AssignmentSubmissionGateError? {
        do {
            try await gate(app, f, user)
            return nil
        } catch let error as AssignmentSubmissionGateError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - The gate

    @Test func onlyAStudentWhoJoinedMaySubmit() async throws {
        try await withAssignmentRoutesApp { app in
            let f = try await fixture(app, prefix: "gate")
            let assignmentID = try f.assignment.requireID()

            #expect(await refusal(app, f, f.member) == .notInGroupSession)
            #expect(await refusal(app, f, f.loner) == .notInGroupSession)
            try await gate(app, f, f.staff)  // staff are never gated

            let session = try await ActivitySessionStore.open(
                assignmentID: assignmentID, groupID: f.labA, by: nil, on: app.db)
            #expect(await refusal(app, f, f.member) == .notInGroupSession, "a member types the code too")

            let code = ActivitySessionCode.code(secret: session.codeSecret, at: Date())
            for student in [f.member, f.loner] {
                try await ActivitySessionStore.join(code: code, userID: student.requireID(), on: app.db)
                try await gate(app, f, student)
            }
            await #expect(throws: ActivitySessionError.otherGroup(session: "Lab 101", own: "Lab 102")) {
                try await ActivitySessionStore.join(code: code, userID: f.other.requireID(), on: app.db)
            }
            #expect(await refusal(app, f, f.other) == .notInGroupSession, "a member of another lab stays out")

            // After the close, a student who joined still submits for a grade;
            // the result does not rank (decision 1).
            try await ActivitySessionStore.close(session, now: Date().addingTimeInterval(-1), on: app.db)
            try await gate(app, f, f.member)
            #expect(await refusal(app, f, f.other) == .notInGroupSession)
        }
    }

    @Test func readingIsNotGated() async throws {
        try await withAssignmentRoutesApp { app in
            let f = try await fixture(app, prefix: "read")
            let gated = try await requireOpenStudentAssignment(
                for: f.setupID, user: f.loner, gate: .access, on: makeTestRequest(on: app))
            #expect(gated != nil)
        }
    }

    // MARK: - Authoring

    @Test func aPerGroupActivityNeedsGroupsAndNoWindow() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let setup = APITestSetup(
                id: "author_setup", manifest: try manifest(runsPerGroup: false),
                zipPath: app.testSetupsDirectory + "author_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)
            let current = try #require(setup.decodedManifest()?.activity)

            func refusal(_ requested: ClassActivity) async -> String? {
                do {
                    try await ActivityAuthoring.setActivity(setup: setup, to: requested, on: app.db)
                    return nil
                } catch let error as AppError {
                    return error.reason
                } catch {
                    return "\(error)"
                }
            }
            #expect(
                await refusal(current.withRunsPerGroup(true)) == ActivityAuthoring.runsPerGroupNeedsGroupsMessage)
            _ = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let window = LiveSessionWindow(opensAt: Date(), closesAt: nil)
            #expect(
                await refusal(current.withWindow(window).withRunsPerGroup(true))
                    == ActivityAuthoring.runsPerGroupWithWindowMessage)
            try await ActivityAuthoring.setActivity(setup: setup, to: current.withRunsPerGroup(true), on: app.db)
            #expect(setup.decodedManifest()?.activity?.runsPerGroup == true)
        }
    }

    @Test func setActivityTurnsItOnAndKeepsItWhenAbsent() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS135", name: "Designing Programs")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            try await makeTestSetup(on: app, id: "setup_rpg", courseID: courseID, manifest: TestManifests.workerEmpty)
            let assignment = try await makeTestAssignment(on: app, testSetupID: "setup_rpg", courseID: courseID)
            _ = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let context = ToolContext(
                request: makeTestRequest(on: app), subject: "tester", grantedScopes: [.read, .write])

            var input = SetActivityTool.Input(
                assignmentPublicID: assignment.publicID, kind: "bestMetric", leaderboardVisibility: nil)
            input.runsPerGroup = true
            let on = try await SetActivityTool().execute(input, context)
            #expect(on.runsPerGroup)

            let kept = try await SetActivityTool().execute(
                .init(assignmentPublicID: assignment.publicID, kind: "bestMetric", leaderboardVisibility: "visible"),
                context)
            #expect(kept.runsPerGroup, "a call that leaves it out keeps it")
        }
    }

    // MARK: - Copies into another course

    /// A clone and a bundle import copy no groups, so a per-group activity in
    /// the copy would refuse every student (the #2189 trap).
    @Test func aCloneAndAnImportDoNotRunPerGroup() throws {
        let perGroup = try manifest(runsPerGroup: true)
        let setup = APITestSetup(id: "clone_src", manifest: perGroup, zipPath: "", courseID: UUID())
        let cloned = try AssignmentAuthoringService.cloneManifest(of: setup)
        #expect(decodeManifest(from: Data(cloned.utf8))?.activity?.runsPerGroup == false)
        let imported = try AssignmentAuthoringService.manifestNotRunPerGroup(perGroup)
        #expect(decodeManifest(from: Data(imported.utf8))?.activity?.runsPerGroup == false)

        let plain = try manifest(runsPerGroup: false)
        #expect(try AssignmentAuthoringService.manifestNotRunPerGroup(plain) == plain, "other bytes are kept")
    }
}
