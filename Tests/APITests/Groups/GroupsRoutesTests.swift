// Tests/APITests/Groups/GroupsRoutesTests.swift
//
// The Groups tab and the roster's group select (docs/lab-groups.md, slice 1),
// end to end: an instructor makes a set, adds a group, imports a file and
// moves a student; a TA reads and is refused every write; an instructor of
// another course and a write to an archived course are refused too.
//
// The routes take no path parameter, so `RouteAuthorizationMatrixTests` does
// not walk them. These tests are their authorization check.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class GroupsRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-groups-routes")
    }

    private struct Actor {
        let cookie: String
        let csrf: String
    }

    /// `username`, enrolled in `courseID` at `role` (their only course, so it
    /// is their active one), signed in.
    private func actor(_ username: String, role: CourseRole, courseID: UUID) async throws -> Actor {
        let cookie = try await loginUser(username: username, password: "pw", role: "student", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role).save(on: app.db)
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return Actor(cookie: sessionCookie, csrf: csrf)
    }

    private func course(_ code: String, archived: Bool = false) async throws -> UUID {
        try await makeTestCourse(on: app, code: code, archived: archived, mode: .closed).requireID()
    }

    private func student(_ username: String, in courseID: UUID) async throws -> UUID {
        let id = try await makeTestStudent(on: app, username: username).requireID()
        try await APICourseEnrollment(userID: id, courseID: courseID, role: .student).save(on: app.db)
        return id
    }

    @discardableResult
    private func post(
        _ path: String, as actor: Actor, fields: [String: String], expecting status: HTTPStatus,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> String {
        var body = ""
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: actor.cookie)
                var form = fields
                form["_csrf"] = actor.csrf
                try req.content.encode(form, as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == status, "POST \(path): \(res.body.string)", sourceLocation: sourceLocation)
                body = res.body.string
            })
        return body
    }

    private func onlySet(of courseID: UUID) async throws -> APICourseGroupSet {
        try #require(try await CourseGroupStore.sets(courseID: courseID, on: app.db).first)
    }

    // MARK: - An instructor

    @Test func anInstructorMakesASetAddsAGroupAndMovesAStudent() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRP1")
            let instructor = try await actor("grp_inst", role: .instructor, courseID: courseID)
            let ada = try await student("ada", in: courseID)

            let empty = try await getHTML("/instructor/groups", cookie: instructor.cookie, on: app)
            #expect(empty.contains("Create group set"))

            try await post(
                "/instructor/groups/sets", as: instructor, fields: ["name": "Lab sections"], expecting: .seeOther)
            let set = try await onlySet(of: courseID)
            let setID = try set.requireID().uuidString
            try await post(
                "/instructor/groups/add", as: instructor, fields: ["setID": setID, "name": "Lab 101"],
                expecting: .seeOther)
            let group = try #require(try await CourseGroupStore.groups(inSet: set.requireID(), on: app.db).first)

            try await post(
                "/instructor/groups/membership", as: instructor,
                fields: ["setID": setID, "userID": ada.uuidString, "groupID": try group.requireID().uuidString],
                expecting: .seeOther)
            #expect(try await CourseGroupStore.groupIDsByUser(inSet: set.requireID(), on: app.db)[ada] == group.id)

            let page = try await getHTML("/instructor/groups", cookie: instructor.cookie, on: app)
            #expect(page.contains("Lab 101"))
            #expect(page.contains("1 student"))
            let roster = try await getHTML("/instructor/students", cookie: instructor.cookie, on: app)
            #expect(roster.contains(#"data-sort-key="group""#), "the roster has a Group column")
            #expect(roster.contains("Group for "), "an instructor gets a select per student")
        }
    }

    @Test func aDuplicateGroupNameIsShownOnThePage() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRP2")
            let instructor = try await actor("grp_dup", role: .instructor, courseID: courseID)
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            _ = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db)
            let page = try await post(
                "/instructor/groups/add", as: instructor,
                fields: ["setID": try set.requireID().uuidString, "name": "lab 101"], expecting: .ok)
            #expect(page.contains("This set already has a group named lab 101."))
        }
    }

    @Test func anImportPlacesStudentsFromAFile() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRP3")
            let instructor = try await actor("grp_imp", role: .instructor, courseID: courseID)
            let ada = try await student("ada3", in: courseID)
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let boundary = "groups-boundary"
            let body = arMultipartBody(
                boundary: boundary,
                fields: [("_csrf", instructor.csrf), ("setID", try set.requireID().uuidString)],
                files: [
                    (
                        name: "file", filename: "groups.csv", contentType: "text/csv",
                        data: Data("username,group\nada3,Lab 104\nnobody,Lab 104\n".utf8)
                    )
                ])
            try await app.asyncTest(
                .POST, "/instructor/groups/import",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: instructor.cookie)
                    req.headers.contentType = HTTPMediaType(
                        type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                    req.body = body
                },
                afterResponse: { res in
                    #expect(res.status == .ok, "import: \(res.body.string)")
                    #expect(res.body.string.contains("Placed 1 student."))
                    #expect(res.body.string.contains("nobody"), "the unmatched username is named")
                })
            let groups = try await CourseGroupStore.groups(inSet: set.requireID(), on: app.db)
            #expect(groups.map(\.name) == ["Lab 104"])
            #expect(try await CourseGroupStore.groupIDsByUser(inSet: set.requireID(), on: app.db)[ada] == groups[0].id)
        }
    }

    // MARK: - Who may not write

    @Test func aTAReadsTheTabAndCannotChangeIt() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRP4")
            let ta = try await actor("grp_ta", role: .ta, courseID: courseID)
            let ada = try await student("ada4", in: courseID)
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let group = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db)
            let setID = try set.requireID().uuidString

            let page = try await getHTML("/instructor/groups", cookie: ta.cookie, on: app)
            #expect(page.contains("Lab 101"))
            #expect(page.contains("instructors can change its groups."), "a TA is told why the tab is read-only")
            #expect(!page.contains("group-add-panel"), "a TA gets no add form")

            try await post("/instructor/groups/sets", as: ta, fields: ["name": "Teams"], expecting: .forbidden)
            try await post(
                "/instructor/groups/add", as: ta, fields: ["setID": setID, "name": "Lab 102"], expecting: .forbidden)
            try await post(
                "/instructor/groups/remove", as: ta, fields: ["groupID": try group.requireID().uuidString],
                expecting: .forbidden)
            try await post(
                "/instructor/groups/membership", as: ta,
                fields: ["setID": setID, "userID": ada.uuidString, "groupID": try group.requireID().uuidString],
                expecting: .forbidden)
            #expect(try await CourseGroupStore.groupIDsByUser(inSet: set.requireID(), on: app.db).isEmpty)
        }
    }

    @Test func anInstructorOfAnotherCourseCannotChangeThisOne() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRP5")
            let otherID = try await course("GRP6")
            let outsider = try await actor("grp_out", role: .instructor, courseID: otherID)
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            try await post(
                "/instructor/groups/add", as: outsider,
                fields: ["setID": try set.requireID().uuidString, "name": "Lab 101"], expecting: .forbidden)
            #expect(try await CourseGroupStore.groups(inSet: set.requireID(), on: app.db).isEmpty)
        }
    }

    @Test func anArchivedCourseIsReadOnly() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRP7", archived: true)
            let instructor = try await actor("grp_arch", role: .instructor, courseID: courseID)
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            try await post(
                "/instructor/groups/add", as: instructor,
                fields: ["setID": try set.requireID().uuidString, "name": "Lab 101"], expecting: .forbidden)
        }
    }

    @Test func aStudentCannotOpenTheTab() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRP8")
            let student = try await actor("grp_stu", role: .student, courseID: courseID)
            let response = try await getResponse("/instructor/groups", cookie: student.cookie, on: app)
            #expect(response.status == .forbidden)
        }
    }
}
