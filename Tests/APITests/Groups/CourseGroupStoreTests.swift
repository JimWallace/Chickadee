// Tests/APITests/Groups/CourseGroupStoreTests.swift
//
// The rules `CourseGroupStore` keeps (docs/lab-groups.md, slice 1): one group
// per set, a replace that moves a student, a removed group that keeps its
// row, the refusals, the import, and the groups in a student's data export.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct CourseGroupStoreTests {

    private struct Fixture {
        let courseID: UUID
        let set: APICourseGroupSet
        let labA: APICourseGroup
        let labB: APICourseGroup
        let students: [UUID]
    }

    /// A course with a manual set of two groups and three enrolled students.
    private func fixture(on app: Application) async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "CS135", name: "Designing Programs")
        let courseID = try course.requireID()
        var students: [UUID] = []
        for name in ["ada", "alan", "grace"] {
            let id = try await makeTestStudent(on: app, username: name).requireID()
            try await makeTestEnrollment(on: app, userID: id, courseID: courseID)
            students.append(id)
        }
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
        let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db)
        let labB = try await CourseGroupStore.addGroup(named: "Lab 102", to: set, on: app.db)
        return Fixture(courseID: courseID, set: set, labA: labA, labB: labB, students: students)
    }

    private func membershipRows(_ f: Fixture, on app: Application) async throws -> [APICourseGroupMembership] {
        try await APICourseGroupMembership.query(on: app.db).filter(\.$setID == f.set.requireID()).all()
    }

    // MARK: - One group per set

    @Test func movingAStudentLeavesOneMembership() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            try await CourseGroupStore.setMembership(
                userID: f.students[0], groupID: f.labA.requireID(), in: f.set, on: app.db)
            try await CourseGroupStore.setMembership(
                userID: f.students[0], groupID: f.labB.requireID(), in: f.set, on: app.db)
            let rows = try await membershipRows(f, on: app)
            #expect(rows.count == 1)
            #expect(try rows.first?.groupID == f.labB.requireID())

            try await CourseGroupStore.setMembership(userID: f.students[0], groupID: nil, in: f.set, on: app.db)
            #expect(try await membershipRows(f, on: app).isEmpty, "no group removes the row")
        }
    }

    /// The database itself refuses a second row for one person in one set.
    @Test func theDatabaseRefusesASecondMembershipInASet() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let setID = try f.set.requireID()
            try await APICourseGroupMembership(setID: setID, groupID: f.labA.requireID(), userID: f.students[0])
                .save(on: app.db)
            await #expect(throws: (any Error).self) {
                try await APICourseGroupMembership(
                    setID: setID, groupID: f.labB.requireID(), userID: f.students[0]
                ).save(on: app.db)
            }
        }
    }

    // MARK: - Replace

    @Test func aReplaceMovesAStudentAndDropsTheAbsent() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let labA = try f.labA.requireID()
            let labB = try f.labB.requireID()
            try await CourseGroupStore.replaceMemberships(
                in: f.set, assignments: [f.students[0]: labA, f.students[1]: labA], on: app.db)
            try await CourseGroupStore.replaceMemberships(
                in: f.set, assignments: [f.students[0]: labB], on: app.db)
            let byUser = try await CourseGroupStore.groupIDsByUser(inSet: f.set.requireID(), on: app.db)
            #expect(byUser == [f.students[0]: labB])
        }
    }

    // MARK: - Remove

    @Test func aRemovedGroupKeepsItsRowAndLosesItsMembers() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let setID = try f.set.requireID()
            try await CourseGroupStore.setMembership(
                userID: f.students[0], groupID: f.labA.requireID(), in: f.set, on: app.db)
            try await CourseGroupStore.removeGroup(f.labA, of: f.set, on: app.db)

            let stored = try #require(try await APICourseGroup.find(f.labA.requireID(), on: app.db))
            #expect(stored.removedAt != nil, "the row stays, marked removed")
            #expect(try await membershipRows(f, on: app).isEmpty)
            #expect(try await CourseGroupStore.groups(inSet: setID, on: app.db).map(\.name) == ["Lab 102"])
            let all = try await CourseGroupStore.groups(inSet: setID, includingRemoved: true, on: app.db)
            #expect(all.count == 2)

            await #expect(throws: CourseGroupError.groupRemoved) {
                try await CourseGroupStore.setMembership(
                    userID: f.students[1], groupID: f.labA.requireID(), in: f.set, on: app.db)
            }
        }
    }

    // MARK: - Refusals

    @Test func aDuplicateOrBlankGroupNameIsRefused() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            await #expect(throws: CourseGroupError.duplicateGroupName("lab 101")) {
                _ = try await CourseGroupStore.addGroup(named: "lab 101", to: f.set, on: app.db)
            }
            await #expect(throws: CourseGroupError.blankName) {
                _ = try await CourseGroupStore.addGroup(named: "  ", to: f.set, on: app.db)
            }
        }
    }

    @Test func aPersonNotInTheCourseIsRefused() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let outsider = try await makeTestStudent(on: app, username: "outsider").requireID()
            await #expect(throws: CourseGroupError.notEnrolled) {
                try await CourseGroupStore.setMembership(
                    userID: outsider, groupID: f.labA.requireID(), in: f.set, on: app.db)
            }
        }
    }

    @Test func aGroupOfAnotherSetIsRefused() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let other = try await CourseGroupStore.createSet(courseID: f.courseID, name: "Teams", on: app.db)
            let team = try await CourseGroupStore.addGroup(named: "Team 1", to: other, on: app.db)
            await #expect(throws: CourseGroupError.groupNotInSet) {
                try await CourseGroupStore.setMembership(
                    userID: f.students[0], groupID: team.requireID(), in: f.set, on: app.db)
            }
        }
    }

    @Test func aSyncedSetRefusesEdits() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let synced = APICourseGroupSet(
                courseID: f.courseID, name: "LEARN labs", source: .learnSections, externalID: "123")
            try await synced.save(on: app.db)
            await #expect(throws: CourseGroupError.setNotEditable) {
                _ = try await CourseGroupStore.addGroup(named: "Lab 1", to: synced, on: app.db)
            }
            await #expect(throws: CourseGroupError.setNotEditable) {
                try await CourseGroupStore.setMembership(userID: f.students[0], groupID: nil, in: synced, on: app.db)
            }
        }
    }

    // MARK: - Import

    @Test func anImportMakesGroupsPlacesStudentsAndReportsTheRest() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            let ta = try await makeTestUser(on: app, username: "tara", role: "student").requireID()
            try await APICourseEnrollment(userID: ta, courseID: f.courseID, role: .ta).save(on: app.db)
            // alan starts in Lab 101; the file moves him, and leaves grace out.
            try await CourseGroupStore.setMembership(
                userID: f.students[1], groupID: f.labA.requireID(), in: f.set, on: app.db)

            let parsed = try GroupRosterCSV.parse(
                Data("ada,Lab 10\nalan,lab 102\nghost,Lab 9\ntara,Lab 2\n".utf8))
            let result = try await CourseGroupStore.importRoster(parsed, into: f.set, on: app.db)

            #expect(result.placed == 2)
            #expect(result.groupsCreated == ["Lab 10"], "a row of no student makes no group")
            #expect(result.unmatched == ["ghost", "tara"], "only the course's students match")
            let setID = try f.set.requireID()
            let groups = try await CourseGroupStore.groups(inSet: setID, on: app.db)
            #expect(groups.map(\.name) == ["Lab 101", "Lab 102", "Lab 10"])
            let nameByID = Dictionary(uniqueKeysWithValues: groups.compactMap { g in g.id.map { ($0, g.name) } })
            let byUser = try await CourseGroupStore.groupIDsByUser(inSet: setID, on: app.db)
            #expect(byUser.mapValues { nameByID[$0] } == [f.students[0]: "Lab 10", f.students[1]: "Lab 102"])
        }
    }

    // MARK: - Data export

    @Test func aStudentsDataExportListsTheirGroup() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            try await CourseGroupStore.setMembership(
                userID: f.students[0], groupID: f.labB.requireID(), in: f.set, on: app.db)
            let student = try #require(try await APIUser.find(f.students[0], on: app.db))
            let content = try await gatherDataExportContent(for: student, on: app.db)
            #expect(content.enrollments.first?.groups == [DataExportGroup(set: "Lab sections", group: "Lab 102")])
        }
    }
}
