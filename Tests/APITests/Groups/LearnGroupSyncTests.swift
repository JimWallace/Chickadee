// Tests/APITests/Groups/LearnGroupSyncTests.swift
//
// The LEARN group sync (docs/lab-groups.md, slice 6), against an in-memory
// LEARN: a first sync makes the course's Sections and places its students; a
// renamed section keeps its group; a student who moves changes group; a
// section that disappears is removed, closes its session, and comes back as
// the same group; a student the classlist cannot match is in no group; a
// group-category set reads its own category; a manual set is not synced; the
// sweep reads only a bound course that is not archived; and the migration
// makes a set from the old section category.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// LEARN as the sync reads it: the classlist, the course's Sections, and the
/// groups of one category.
private struct FakeLearn: BrightSpaceGrading {
    var classlist: [BrightSpaceClasslistEntry] = []
    var sections: [BrightSpaceGroup] = []
    var groupsByCategory: [String: [BrightSpaceGroup]] = [:]

    func lookupUserID(orgDefinedId: String, on application: Application) async throws -> String? { nil }
    func fetchClasslist(
        orgUnitID: String, on application: Application
    ) async throws -> [BrightSpaceClasslistEntry] { classlist }
    func pushGrade(
        orgUnitID: String, gradeObjectID: String, bsUserID: String, earnedPoints: Double,
        on application: Application
    ) async throws {}
    func fetchGradeObject(
        orgUnitID: String, gradeObjectID: String, on application: Application
    ) async throws -> BrightSpaceGradeObject? { nil }
    func clearGrade(
        orgUnitID: String, gradeObjectID: String, bsUserID: String, on application: Application
    ) async throws {}
    func fetchGroups(
        orgUnitID: String, categoryID: String, on application: Application
    ) async throws -> [BrightSpaceGroup] { groupsByCategory[categoryID] ?? [] }
    func fetchSections(
        orgUnitID: String, on application: Application
    ) async throws -> [BrightSpaceGroup] { sections }
}

@Suite(.serialized) final class LearnGroupSyncTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-learn-sync")
    }

    private struct Fixture {
        let course: APICourse
        let set: APICourseGroupSet
        let ada: UUID
        let alan: UUID
        let grace: UUID
    }

    /// A course bound to LEARN org unit 900, with a set of `source`, and
    /// three students. The classlist has ada (D2L 501) and alan (D2L 502),
    /// and not grace.
    private func fixture(
        source: CourseGroupSource = .learnSections, externalID: String? = nil
    ) async throws
        -> Fixture
    {
        let course = try await makeTestCourse(on: app, code: "LSY1", mode: .closed)
        course.brightspaceOrgUnitID = "900"
        try await course.save(on: app.db)
        let courseID = try course.requireID()
        let set = APICourseGroupSet(courseID: courseID, name: "Labs", source: source, externalID: externalID)
        try await set.save(on: app.db)
        var students: [UUID] = []
        for name in ["lsync_ada", "lsync_alan", "lsync_grace"] {
            let id = try await makeTestStudent(on: app, username: name).requireID()
            try await makeTestEnrollment(on: app, userID: id, courseID: courseID)
            students.append(id)
        }
        return Fixture(course: course, set: set, ada: students[0], alan: students[1], grace: students[2])
    }

    private let classlist = [
        BrightSpaceClasslistEntry(orgDefinedID: nil, username: "lsync_ada", userID: "501"),
        BrightSpaceClasslistEntry(orgDefinedID: nil, username: "lsync_alan", userID: "502"),
    ]

    private func learn(_ sections: [BrightSpaceGroup]) -> FakeLearn {
        FakeLearn(classlist: classlist, sections: sections)
    }

    @discardableResult
    private func sync(_ f: Fixture, _ client: FakeLearn) async throws -> CourseGroupStore.SyncResult? {
        try await syncLearnGroupSet(f.set, orgUnitID: "900", client: client, on: app.db, application: app)
    }

    /// Each group of the set by external id, removed ones included.
    private func groups(_ f: Fixture) async throws -> [String: APICourseGroup] {
        let rows = try await CourseGroupStore.groups(inSet: try f.set.requireID(), includingRemoved: true, on: app.db)
        return Dictionary(
            rows.compactMap { group in group.externalID.map { ($0, group) } }, uniquingKeysWith: { a, _ in a })
    }

    private func members(_ f: Fixture) async throws -> [UUID: UUID] {
        try await CourseGroupStore.groupIDsByUser(inSet: try f.set.requireID(), on: app.db)
    }

    @Test func aFirstSyncMakesTheSectionsAndPlacesTheStudents() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            let result = try await sync(
                f,
                learn([
                    BrightSpaceGroup(groupID: "71", name: "Lab 102", enrollments: ["502"]),
                    BrightSpaceGroup(groupID: "70", name: "Lab 101", enrollments: ["501", "999"]),
                ]))
            #expect(result == CourseGroupStore.SyncResult(placed: 2, added: 2, renamed: 0, removed: 0))

            let rows = try await CourseGroupStore.groups(inSet: try f.set.requireID(), on: app.db)
            #expect(rows.map(\.name) == ["Lab 101", "Lab 102"], "in natural order")
            #expect(rows.map(\.externalID) == ["70", "71"])
            let labs = try await members(f)
            #expect(labs[f.ada] == rows[0].id)
            #expect(labs[f.alan] == rows[1].id)
            #expect(try await APICourseGroupSet.find(f.set.id, on: app.db)?.lastSyncedAt != nil)
        }
    }

    @Test func aRenamedSectionKeepsItsGroup() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            try await sync(f, learn([BrightSpaceGroup(groupID: "70", name: "Lab 101", enrollments: ["501"])]))
            let before = try #require(try await groups(f)["70"]?.id)

            let result = try await sync(
                f, learn([BrightSpaceGroup(groupID: "70", name: "Lab 101 (Mon)", enrollments: ["501"])]))
            #expect(result?.renamed == 1)
            #expect(result?.added == 0)
            let after = try #require(try await groups(f)["70"])
            #expect(after.id == before)
            #expect(after.name == "Lab 101 (Mon)")
            #expect(try await members(f)[f.ada] == before)
        }
    }

    @Test func aStudentWhoMovesChangesGroup() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            let lab101 = BrightSpaceGroup(groupID: "70", name: "Lab 101", enrollments: ["501"])
            try await sync(f, learn([lab101, BrightSpaceGroup(groupID: "71", name: "Lab 102", enrollments: [])]))
            try await sync(
                f,
                learn([
                    BrightSpaceGroup(groupID: "70", name: "Lab 101", enrollments: []),
                    BrightSpaceGroup(groupID: "71", name: "Lab 102", enrollments: ["501"]),
                ]))
            let rows = try await groups(f)
            #expect(try await members(f)[f.ada] == rows["71"]?.id)
        }
    }

    @Test func aSectionThatDisappearsIsRemovedAndComesBackAsTheSameGroup() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            let lab101 = BrightSpaceGroup(groupID: "70", name: "Lab 101", enrollments: ["501"])
            let lab102 = BrightSpaceGroup(groupID: "71", name: "Lab 102", enrollments: ["502"])
            try await sync(f, learn([lab101, lab102]))
            let lab102ID = try #require(try await groups(f)["71"]?.id)
            let courseID = try f.course.requireID()
            try await makeTestSetup(on: app, id: "lsync_setup", courseID: courseID)
            let assignment = try await makeTestAssignment(on: app, testSetupID: "lsync_setup", courseID: courseID)
            let session = try await ActivitySessionStore.open(
                assignmentID: try assignment.requireID(), groupID: lab102ID, by: nil, now: Date(), on: app.db)

            let result = try await sync(f, learn([lab101]))
            #expect(result?.removed == 1)
            #expect(try await groups(f)["71"]?.removedAt != nil)
            #expect(try await members(f)[f.alan] == nil)
            #expect(try await APIActivitySession.find(session.id, on: app.db)?.closedAt != nil, "its session ends")

            let back = try await sync(f, learn([lab101, lab102]))
            #expect(back?.added == 1)
            let restored = try #require(try await groups(f)["71"])
            #expect(restored.id == lab102ID)
            #expect(restored.removedAt == nil)
            #expect(try await members(f)[f.alan] == lab102ID)
        }
    }

    @Test func aStudentTheClasslistCannotMatchIsInNoGroup() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            // 503 is grace's D2L id, but the classlist does not list her.
            try await sync(
                f, learn([BrightSpaceGroup(groupID: "70", name: "Lab 101", enrollments: ["501", "503"])]))
            let labs = try await members(f)
            #expect(labs[f.ada] != nil)
            #expect(labs[f.grace] == nil)
        }
    }

    @Test func aGroupCategorySetReadsItsOwnCategory() async throws {
        try await withApp(app) { _ in
            let f = try await fixture(source: .learnGroups, externalID: "77")
            let client = FakeLearn(
                classlist: classlist,
                sections: [BrightSpaceGroup(groupID: "70", name: "Section", enrollments: ["501"])],
                groupsByCategory: [
                    "77": [BrightSpaceGroup(groupID: "300", name: "Team A", enrollments: ["502"])],
                    "78": [BrightSpaceGroup(groupID: "301", name: "Other", enrollments: ["501"])],
                ])
            try await sync(f, client)
            let rows = try await groups(f)
            #expect(Set(rows.keys) == ["300"])
            #expect(try await members(f) == [f.alan: try #require(rows["300"]?.id)])
        }
    }

    @Test func aManualSetIsNotSynced() async throws {
        try await withApp(app) { _ in
            let f = try await fixture(source: .manual)
            let client = learn([BrightSpaceGroup(groupID: "70", name: "Lab 101", enrollments: ["501"])])
            #expect(try await sync(f, client) == nil)
            await #expect(throws: CourseGroupError.setNotSynced) {
                try await CourseGroupStore.applySync([], members: [:], to: f.set, now: Date(), on: app.db)
            }
            #expect(try await groups(f).isEmpty)
        }
    }

    @Test func theSweepReadsOnlyABoundCourseThatIsNotArchived() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            let archived = try await makeTestCourse(on: app, code: "LSY2", archived: true)
            archived.brightspaceOrgUnitID = "901"
            try await archived.save(on: app.db)
            try await APICourseGroupSet(courseID: try archived.requireID(), name: "Labs", source: .learnSections)
                .save(on: app.db)
            let unbound = try await makeTestCourse(on: app, code: "LSY3")
            try await APICourseGroupSet(courseID: try unbound.requireID(), name: "Labs", source: .learnSections)
                .save(on: app.db)

            let client = learn([BrightSpaceGroup(groupID: "70", name: "Lab 101", enrollments: ["501"])])
            let synced = try await sweepLearnGroups(
                on: app.db, resolveClient: { _ in client }, logger: app.logger, application: app)
            #expect(synced == 1)
            #expect(try await groups(f)["70"] != nil)
            #expect(try await APICourseGroup.query(on: app.db).count() == 1)
        }
    }

    @Test func theMigrationMakesASetFromTheOldSectionCategory() async throws {
        try await withApp(app) { _ in
            let withCategory = try await makeTestCourse(on: app, code: "LSY4")
            withCategory.brightspaceSectionCategoryID = "55"
            try await withCategory.save(on: app.db)
            let withSet = try await makeTestCourse(on: app, code: "LSY5")
            withSet.brightspaceSectionCategoryID = "56"
            try await withSet.save(on: app.db)
            _ = try await CourseGroupStore.createSet(courseID: try withSet.requireID(), name: "Labs", on: app.db)
            let student = try await makeTestStudent(on: app, username: "lsync_old").requireID()
            try await makeTestEnrollment(on: app, userID: student, courseID: try withCategory.requireID())
            let enrollment = try #require(
                try await APICourseEnrollment.query(on: app.db).filter(\.$userID == student).first())
            enrollment.brightspaceSection = "Lab 3"
            try await enrollment.save(on: app.db)

            try await MoveLearnSectionCategoryToGroupSet().prepare(on: app.db)

            let made = try await CourseGroupStore.sets(courseID: try withCategory.requireID(), on: app.db)
            #expect(made.map(\.source) == [.learnGroups])
            #expect(made.map(\.externalID) == ["55"])
            let kept = try await CourseGroupStore.sets(courseID: try withSet.requireID(), on: app.db)
            #expect(kept.map(\.source) == [.manual], "a course with a set keeps it")
            #expect(try await APICourseEnrollment.find(enrollment.id, on: app.db)?.brightspaceSection == nil)
        }
    }
}
