// Tests/APITests/Groups/GroupSourceRoutesTests.swift
//
// Where the Groups tab's groups come from (docs/lab-groups.md, slice 6b): an
// instructor of a course linked to LEARN reads its groups from the LEARN
// Sections, syncs them again, and stops the sync, which keeps the groups and
// makes them editable; a failed first read puts the set back; a lab made in
// Chickadee keeps its row and its session when the set switches to LEARN, and
// a removed one stays removed; a
// source change ends the join placements, and a failed read keeps them;
// "Sync now" refuses a manual set; a
// course not linked to LEARN is refused; a TA may not change the source; and
// the tab shows each state's controls. LEARN is a stubbed `app.client` that
// answers the Sections and the classlist routes of org unit 900 only.

import Core
import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// A `Client` stub that answers each request with the body of the first route
/// its path contains, and 404 for any other path (the version negotiation then
/// falls back to the pinned version).
private final class LearnStub: Client, Sendable {
    let eventLoop: any EventLoop
    let routes: [(path: String, body: String)]

    init(eventLoop: any EventLoop, routes: [(path: String, body: String)]) {
        self.eventLoop = eventLoop
        self.routes = routes
    }

    func delegating(to eventLoop: any EventLoop) -> any Client {
        LearnStub(eventLoop: eventLoop, routes: routes)
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        guard let route = routes.first(where: { request.url.string.contains($0.path) }) else {
            return eventLoop.makeSucceededFuture(ClientResponse(status: .notFound, headers: [:], body: nil))
        }
        let headers = HTTPHeaders([("Content-Type", "application/json")])
        return eventLoop.makeSucceededFuture(
            ClientResponse(status: .ok, headers: headers, body: ByteBuffer(string: route.body)))
    }
}

@Suite struct GroupSourceRoutesTests {

    private static let credentials = BrightSpaceAppCredentials(
        baseURL: "https://learn.test", appID: "a", appKey: "k", debounceSecs: 90)

    /// LEARN for org unit 900: Lab 101 holds D2L user 501, the classlist's
    /// `gsrc_ada`.
    private static let routes: [(path: String, body: String)] = [
        (
            "/900/sections/",
            #"[{"SectionId": 70, "Name": "Lab 101", "Code": "L101", "Description": {"Text": "", "Html": ""}, "Enrollments": [501]}]"#
        ),
        (
            "/900/classlist/paged/",
            #"{"Objects": [{"Identifier": "501", "Username": "gsrc_ada", "OrgDefinedId": null}], "Next": null}"#
        ),
    ]

    /// Connects the deployment to the stubbed LEARN and links the shared
    /// course to `orgUnit`, unless `linked` is false. Only org unit 900 has
    /// routes. Returns the course.
    private func connect(_ app: Application, linked: Bool = true, orgUnit: String = "900") async throws -> APICourse {
        app.brightSpaceAppCredentials = Self.credentials
        app.brightSpaceSyncConfig = BrightSpaceSyncConfig(app: Self.credentials, userID: "svc", userKey: "svc-key")
        let routes = Self.routes
        app.clients.use { app in LearnStub(eventLoop: app.eventLoopGroup.next(), routes: routes) }
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let course = try #require(try await APICourse.find(courseID, on: app.db))
        if linked {
            course.brightspaceOrgUnitID = orgUnit
            try await course.save(on: app.db)
        }
        let ada = try await arInsertStudent(username: "gsrc_ada", on: app)
        try await arEnrollStudentInTestCourse(ada, on: app)
        return course
    }

    private func post(
        _ path: String, fields: [String: String], cookie: String, on app: Application
    ) async throws -> (status: HTTPStatus, location: String?, body: String) {
        let (token, boundCookie) = try await csrfFields(for: "/instructor/groups", cookie: cookie, on: app)
        var result: (HTTPStatus, String?, String) = (.ok, nil, "")
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(fields.merging(["_csrf": token]) { first, _ in first }, as: .urlEncodedForm)
            },
            afterResponse: { res in
                result = (res.status, res.headers.first(name: .location), res.body.string)
            })
        return result
    }

    private func labSet(_ course: APICourse, on app: Application) async throws -> APICourseGroupSet? {
        try await CourseGroupStore.sets(courseID: try course.requireID(), on: app.db).first
    }

    @Test func aLinkedCourseReadsItsGroupsFromTheLearnSections() async throws {
        try await withAssignmentRoutesApp { app in
            let course = try await connect(app)
            let cookie = try await arLoginAsInstructor(on: app)

            let response = try await post(
                "/instructor/groups/source", fields: ["source": "learnSections"], cookie: cookie, on: app)
            #expect(response.status == .seeOther)
            #expect(response.location == "/instructor/groups?notice=learn")

            let set = try #require(try await labSet(course, on: app))
            #expect(set.source == .learnSections)
            #expect(set.lastSyncedAt != nil)
            let groups = try await CourseGroupStore.groups(inSet: try set.requireID(), on: app.db)
            #expect(groups.map(\.name) == ["Lab 101"])
            let ada = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gsrc_ada").first())
            let members = try await CourseGroupStore.groupIDsByUser(inSet: try set.requireID(), on: app.db)
            #expect(members[try ada.requireID()] == groups.first?.id)

            let html = try await getHTML("/instructor/groups", cookie: cookie, on: app)
            #expect(html.contains("Read from the LEARN Sections of this course"))
            #expect(html.contains("/instructor/groups/sync"))
            #expect(html.contains("Stop syncing"))
        }
    }

    @Test func syncNowReadsTheLearnSectionsAgain() async throws {
        try await withAssignmentRoutesApp { app in
            let course = try await connect(app)
            let cookie = try await arLoginAsInstructor(on: app)
            try await CourseGroupStore.setSource(.learnSections, courseID: try course.requireID(), on: app.db)

            let response = try await post("/instructor/groups/sync", fields: [:], cookie: cookie, on: app)
            #expect(response.location == "/instructor/groups?notice=learn")
            let set = try #require(try await labSet(course, on: app))
            #expect(
                try await CourseGroupStore.groups(inSet: try set.requireID(), on: app.db).map(\.name) == ["Lab 101"])
        }
    }

    @Test func stopSyncingKeepsTheGroupsAndMakesThemEditable() async throws {
        try await withAssignmentRoutesApp { app in
            let course = try await connect(app)
            let cookie = try await arLoginAsInstructor(on: app)
            _ = try await post(
                "/instructor/groups/source", fields: ["source": "learnSections"], cookie: cookie, on: app)

            let response = try await post(
                "/instructor/groups/source", fields: ["source": "manual"], cookie: cookie, on: app)
            #expect(response.location == "/instructor/groups?notice=manual")
            let set = try #require(try await labSet(course, on: app))
            #expect(set.source == .manual)
            #expect(
                try await CourseGroupStore.groups(inSet: try set.requireID(), on: app.db).map(\.name) == ["Lab 101"])

            let html = try await getHTML("/instructor/groups", cookie: cookie, on: app)
            #expect(html.contains("/instructor/groups/add"), "the groups are editable again")
            #expect(html.contains("Read from LEARN"), "the course can read them from LEARN again")
        }
    }

    @Test func aCourseNotLinkedToLearnIsRefused() async throws {
        try await withAssignmentRoutesApp { app in
            let course = try await connect(app, linked: false)
            let cookie = try await arLoginAsInstructor(on: app)

            let response = try await post(
                "/instructor/groups/source", fields: ["source": "learnSections"], cookie: cookie, on: app)
            #expect(response.status == .ok)
            #expect(response.body.contains("Link this course to LEARN on the LEARN tab first."))
            #expect(try await labSet(course, on: app) == nil)
            #expect(!(try await getHTML("/instructor/groups", cookie: cookie, on: app)).contains("Read from LEARN"))
        }
    }

    @Test func aTAMayNotChangeTheSource() async throws {
        try await withAssignmentRoutesApp { app in
            let course = try await connect(app)
            let cookie = try await loginAsCourseTA("gsrc_ta", on: app)

            let response = try await post(
                "/instructor/groups/source", fields: ["source": "learnSections"], cookie: cookie, on: app)
            #expect(response.status == .forbidden)
            #expect(try await labSet(course, on: app) == nil)
        }
    }

    @Test func aFailedFirstReadPutsTheSetBack() async throws {
        try await withAssignmentRoutesApp { app in
            // LEARN answers nothing for org unit 901, so the read fails.
            let course = try await connect(app, orgUnit: "901")
            let cookie = try await arLoginAsInstructor(on: app)

            let response = try await post(
                "/instructor/groups/source", fields: ["source": "learnSections"], cookie: cookie, on: app)
            #expect(response.body.contains("The groups could not be read from LEARN."))
            #expect(try await labSet(course, on: app) == nil, "a set made for the read goes")

            let made = try await CourseGroupStore.createSet(courseID: try course.requireID(), name: "Labs", on: app.db)
            _ = try await post(
                "/instructor/groups/source", fields: ["source": "learnSections"], cookie: cookie, on: app)
            let kept = try await APICourseGroupSet.find(made.id, on: app.db)
            #expect(kept?.source == .manual, "a manual set stays manual")
        }
    }

    @Test func aLabMadeHereKeepsItsSessionWhenTheSetSwitchesToLearn() async throws {
        try await withAssignmentRoutesApp { app in
            let course = try await connect(app)
            let cookie = try await arLoginAsInstructor(on: app)
            let courseID = try course.requireID()
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Labs", on: app.db)
            let lab = try await CourseGroupStore.addGroup(named: "lab 101", to: set, on: app.db)
            try await makeTestSetup(on: app, id: "gsrc_setup", courseID: courseID)
            let assignment = try await makeTestAssignment(on: app, testSetupID: "gsrc_setup", courseID: courseID)
            _ = try await ActivitySessionStore.open(
                assignmentID: try assignment.requireID(), groupID: try lab.requireID(), by: nil, now: Date(),
                on: app.db)

            _ = try await post(
                "/instructor/groups/source", fields: ["source": "learnSections"], cookie: cookie, on: app)
            let groups = try await CourseGroupStore.groups(inSet: try set.requireID(), on: app.db)
            #expect(groups.map(\.id) == [lab.id], "no second Lab 101")
            #expect(groups.first?.externalID == "70")
            #expect(groups.first?.name == "Lab 101")
        }
    }

    @Test func aRemovedLabMadeHereStaysRemovedWhenTheSetSwitchesToLearn() async throws {
        try await withAssignmentRoutesApp { app in
            let course = try await connect(app)
            let cookie = try await arLoginAsInstructor(on: app)
            let set = try await CourseGroupStore.createSet(courseID: try course.requireID(), name: "Labs", on: app.db)
            let lab = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db)
            try await CourseGroupStore.removeGroup(lab, of: set, on: app.db)

            _ = try await post(
                "/instructor/groups/source", fields: ["source": "learnSections"], cookie: cookie, on: app)
            let removed = try #require(try await APICourseGroup.find(lab.id, on: app.db))
            #expect(removed.removedAt != nil, "a removed lab counts for nobody")
            #expect(removed.externalID == nil)
            let active = try await CourseGroupStore.groups(inSet: try set.requireID(), on: app.db)
            #expect(active.map(\.externalID) == ["70"], "LEARN gets a new group")
            #expect(active.first?.id != lab.id)
        }
    }

    /// A manual set with "Lab 101", an open per-group session for it, and
    /// ada placed in it by her join. Returns the set.
    private func joinPlacement(_ app: Application, course: APICourse) async throws -> APICourseGroupSet {
        let courseID = try course.requireID()
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Labs", on: app.db)
        let lab = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db)
        // The join places a student only for an activity run per group.
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "t.py")], language: .python,
            activity: ClassActivity(kind: .bestMetric, runsPerGroup: true))
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        try await makeTestSetup(on: app, id: "gsrc_setup", courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(on: app, testSetupID: "gsrc_setup", courseID: courseID)
        let ada = try #require(try await APIUser.query(on: app.db).filter(\.$username == "gsrc_ada").first())
        try await joinSession(
            assignmentID: try assignment.requireID(), groupID: try lab.requireID(), userID: try ada.requireID(),
            on: app.db)
        #expect(try await placed(app) == [true], "the join placed ada in the manual set")
        return set
    }

    private func placed(_ app: Application) async throws -> [Bool] {
        try await APIActivitySessionAttendance.query(on: app.db).all().map(\.placedInGroup)
    }

    @Test func aSourceChangeEndsTheJoinPlacements() async throws {
        try await withAssignmentRoutesApp { app in
            let course = try await connect(app)
            let cookie = try await arLoginAsInstructor(on: app)
            _ = try await joinPlacement(app, course: course)

            _ = try await post(
                "/instructor/groups/source", fields: ["source": "learnSections"], cookie: cookie, on: app)
            #expect(try await placed(app) == [false])
        }
    }

    @Test func aFailedReadKeepsTheJoinPlacements() async throws {
        try await withAssignmentRoutesApp { app in
            let course = try await connect(app, orgUnit: "901")
            let cookie = try await arLoginAsInstructor(on: app)
            let set = try await joinPlacement(app, course: course)

            _ = try await post(
                "/instructor/groups/source", fields: ["source": "learnSections"], cookie: cookie, on: app)
            #expect(try await APICourseGroupSet.find(set.id, on: app.db)?.source == .manual)
            #expect(try await placed(app) == [true], "Remove can still undo the join's placement")
        }
    }

    @Test func syncNowRefusesAManualSet() async throws {
        try await withAssignmentRoutesApp { app in
            let course = try await connect(app)
            let cookie = try await arLoginAsInstructor(on: app)
            _ = try await CourseGroupStore.createSet(courseID: try course.requireID(), name: "Labs", on: app.db)

            let response = try await post("/instructor/groups/sync", fields: [:], cookie: cookie, on: app)
            #expect(response.body.contains("These groups are not read from LEARN"))
        }
    }
}
