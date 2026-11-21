// Tests/APITests/Groups/GroupsRoutesRefusalTests.swift
//
// The Groups tab routes (`InstructorDashboardRoutes+Groups.swift`) on the
// paths that `GroupsRoutesTests` does not take: the success banners, a
// second set, a blank name, a removed group, an import with no file or a bad
// file, a malformed membership form, a person who is not enrolled, a set from
// LEARN, and an instructor of another course on each write that names a row.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class GroupsRoutesRefusalTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-groups-refusal")
    }

    private struct Actor {
        let cookie: String
        let csrf: String
    }

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

    private struct Reply {
        let status: HTTPStatus
        let location: String?
        let body: String
    }

    private func post(_ path: String, as actor: Actor, fields: [String: String]) async throws -> Reply {
        let response = try await app.asyncSendRequest(.POST, path) { req in
            req.headers.add(name: .cookie, value: actor.cookie)
            var form = fields
            form["_csrf"] = actor.csrf
            try req.content.encode(form, as: .urlEncodedForm)
        }
        return Reply(
            status: response.status, location: response.headers.first(name: .location), body: response.body.string)
    }

    private func importFile(_ data: Data?, setID: String, as actor: Actor) async throws -> Reply {
        let boundary = "groups-refusal-boundary"
        let fields = [("_csrf", actor.csrf), ("setID", setID)]
        let body =
            if let data {
                arMultipartBody(
                    boundary: boundary, fields: fields,
                    files: [(name: "file", filename: "groups.csv", contentType: "text/csv", data: data)])
            } else {
                arMultipartBody(boundary: boundary, fields: fields)
            }
        let response = try await app.asyncSendRequest(.POST, "/instructor/groups/import") { req in
            req.headers.add(name: .cookie, value: actor.cookie)
            req.headers.contentType = HTTPMediaType(
                type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
            req.body = body
        }
        return Reply(
            status: response.status, location: response.headers.first(name: .location), body: response.body.string)
    }

    // MARK: - The page

    @Test(arguments: [
        ("set", "Group set created."),
        ("added", "Group added."),
        ("removed", "Group removed, and its students are in no group."),
        ("learn", "The groups were read from LEARN."),
        ("manual", "These groups are no longer read from LEARN. You can edit them here."),
    ])
    func eachNoticeCodeShowsItsOwnSentence(code: String, sentence: String) async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRN1")
            let instructor = try await actor("grn_notice", role: .instructor, courseID: courseID)
            let page = try await getHTML("/instructor/groups?notice=\(code)", cookie: instructor.cookie, on: app)
            #expect(page.contains(sentence))
        }
    }

    @Test func anUnknownNoticeCodeShowsNoBanner() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRN2")
            let instructor = try await actor("grn_unknown", role: .instructor, courseID: courseID)
            let page = try await getHTML(
                "/instructor/groups?notice=Your+account+is+locked", cookie: instructor.cookie, on: app)
            #expect(!page.contains("Your account is locked"), "a crafted link cannot put words in the banner")
            #expect(!page.contains("Group set created."))
        }
    }

    // MARK: - Making the set

    @Test func aSecondSetIsNotMadeAndTheRedirectNamesNoNotice() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRN4")
            let instructor = try await actor("grn_second", role: .instructor, courseID: courseID)
            _ = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let reply = try await post("/instructor/groups/sets", as: instructor, fields: ["name": "Teams"])
            #expect(reply.status == .seeOther)
            #expect(reply.location == "/instructor/groups")
            let sets = try await CourseGroupStore.sets(courseID: courseID, on: app.db)
            #expect(sets.map(\.name) == ["Lab sections"])
        }
    }

    @Test func aBlankSetNameIsShownOnThePageAndNoSetIsMade() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRN5")
            let instructor = try await actor("grn_blank", role: .instructor, courseID: courseID)
            let reply = try await post("/instructor/groups/sets", as: instructor, fields: ["name": "   "])
            #expect(reply.status == .ok)
            #expect(reply.body.contains("Enter a name."))
            #expect(try await CourseGroupStore.sets(courseID: courseID, on: app.db).isEmpty)
        }
    }

    // MARK: - Removing a group

    @Test func anInstructorRemovesAGroupAndItsStudentsAreInNoGroup() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRN6")
            let instructor = try await actor("grn_remove", role: .instructor, courseID: courseID)
            let ada = try await student("grn_ada6", in: courseID)
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let group = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db)
            try await CourseGroupStore.setMembership(userID: ada, groupID: group.requireID(), in: set, on: app.db)

            let reply = try await post(
                "/instructor/groups/remove", as: instructor, fields: ["groupID": try group.requireID().uuidString])
            #expect(reply.status == .seeOther)
            #expect(reply.location == "/instructor/groups?notice=removed")
            let stored = try #require(try await APICourseGroup.find(group.requireID(), on: app.db))
            #expect(stored.removedAt != nil, "the row stays, marked removed")
            #expect(try await CourseGroupStore.groupIDsByUser(inSet: set.requireID(), on: app.db)[ada] == nil)
        }
    }

    @Test(arguments: ["", "not-a-uuid", "8E2A2C1C-4A7B-4F55-9D7E-111111111111"])
    func removingAGroupThatDoesNotExistIsNotFound(groupID: String) async throws {
        try await withApp(app) { _ in
            let courseID = try await course("GRN7")
            let instructor = try await actor("grn_missing", role: .instructor, courseID: courseID)
            let reply = try await post("/instructor/groups/remove", as: instructor, fields: ["groupID": groupID])
            #expect(reply.status == .notFound)
        }
    }

    @Test func aGroupOfALearnSetCannotBeRemovedHere() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRN8")
            let instructor = try await actor("grn_learn", role: .instructor, courseID: courseID)
            let set = APICourseGroupSet(courseID: courseID, name: "LEARN sections", source: .learnSections)
            try await set.save(on: app.db)
            let group = APICourseGroup(setID: try set.requireID(), name: "Section 001", sortOrder: 1)
            try await group.save(on: app.db)

            let reply = try await post(
                "/instructor/groups/remove", as: instructor, fields: ["groupID": try group.requireID().uuidString])
            #expect(reply.status == .ok)
            #expect(reply.body.contains("This group set comes from LEARN, so change its groups in LEARN."))
            let stored = try #require(try await APICourseGroup.find(group.requireID(), on: app.db))
            #expect(stored.removedAt == nil)
        }
    }

    // MARK: - Import

    @Test func anImportWithNoFileAsksForOne() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRN9")
            let instructor = try await actor("grn_nofile", role: .instructor, courseID: courseID)
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let missing = try await importFile(nil, setID: try set.requireID().uuidString, as: instructor)
            #expect(missing.status == .ok)
            #expect(missing.body.contains("Choose a CSV file to import."))
            let empty = try await importFile(Data(), setID: try set.requireID().uuidString, as: instructor)
            #expect(empty.status == .ok)
            #expect(empty.body.contains("Choose a CSV file to import."))
        }
    }

    @Test func anImportWithoutTheTwoColumnsNamesWhatIsMissing() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRN10")
            let instructor = try await actor("grn_badcsv", role: .instructor, courseID: courseID)
            _ = try await student("grn_ada10", in: courseID)
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let reply = try await importFile(
                Data("username\ngrn_ada10\n".utf8), setID: try set.requireID().uuidString, as: instructor)
            #expect(reply.status == .ok)
            #expect(reply.body.contains("The file needs a username column and a group column."))
            #expect(try await CourseGroupStore.groups(inSet: set.requireID(), on: app.db).isEmpty)
        }
    }

    // MARK: - Membership

    @Test(arguments: ["", "not-a-uuid"])
    func aMalformedUserIDIsABadRequest(userID: String) async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRN11")
            let instructor = try await actor("grn_baduser", role: .instructor, courseID: courseID)
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let reply = try await post(
                "/instructor/groups/membership", as: instructor,
                fields: ["setID": try set.requireID().uuidString, "userID": userID, "groupID": ""])
            #expect(reply.status == .badRequest)
        }
    }

    @Test func aMalformedGroupIDIsABadRequestAndChangesNothing() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRN12")
            let instructor = try await actor("grn_badgroup", role: .instructor, courseID: courseID)
            let ada = try await student("grn_ada12", in: courseID)
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let group = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db)
            try await CourseGroupStore.setMembership(userID: ada, groupID: group.requireID(), in: set, on: app.db)

            let reply = try await post(
                "/instructor/groups/membership", as: instructor,
                fields: ["setID": try set.requireID().uuidString, "userID": ada.uuidString, "groupID": "lab-101"])
            #expect(reply.status == .badRequest)
            #expect(try await CourseGroupStore.groupIDsByUser(inSet: set.requireID(), on: app.db)[ada] == group.id)
        }
    }

    @Test func anEmptyGroupIDTakesTheStudentOutOfEveryGroup() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRN13")
            let instructor = try await actor("grn_nogroup", role: .instructor, courseID: courseID)
            let ada = try await student("grn_ada13", in: courseID)
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let group = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db)
            try await CourseGroupStore.setMembership(userID: ada, groupID: group.requireID(), in: set, on: app.db)

            let reply = try await post(
                "/instructor/groups/membership", as: instructor,
                fields: ["setID": try set.requireID().uuidString, "userID": ada.uuidString, "groupID": ""])
            #expect(reply.status == .seeOther)
            #expect(reply.location == "/instructor/students")
            #expect(try await CourseGroupStore.groupIDsByUser(inSet: set.requireID(), on: app.db)[ada] == nil)
        }
    }

    @Test func aPersonNotEnrolledInTheCourseGoesBackWithAnError() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRN14")
            let otherID = try await course("GRN14B")
            let instructor = try await actor("grn_outsider", role: .instructor, courseID: courseID)
            let stranger = try await student("grn_stranger", in: otherID)
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let group = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db)

            let reply = try await post(
                "/instructor/groups/membership", as: instructor,
                fields: [
                    "setID": try set.requireID().uuidString, "userID": stranger.uuidString,
                    "groupID": try group.requireID().uuidString,
                ])
            #expect(reply.status == .seeOther)
            #expect(reply.location == "/instructor/students?groupError=1")
            #expect(try await CourseGroupStore.groupIDsByUser(inSet: set.requireID(), on: app.db).isEmpty)
        }
    }

    @Test(arguments: ["", "not-a-uuid", "8E2A2C1C-4A7B-4F55-9D7E-222222222222"])
    func aSetThatDoesNotExistIsNotFound(setID: String) async throws {
        try await withApp(app) { _ in
            let courseID = try await course("GRN15")
            let instructor = try await actor("grn_noset", role: .instructor, courseID: courseID)
            let reply = try await post(
                "/instructor/groups/add", as: instructor, fields: ["setID": setID, "name": "Lab 101"])
            #expect(reply.status == .notFound)
        }
    }

    // MARK: - Another course

    @Test func anInstructorOfAnotherCourseCannotRemoveImportOrMove() async throws {
        try await withApp(app) { app in
            let courseA = try await course("GRN16A")
            let courseB = try await course("GRN16B")
            let outsider = try await actor("grn_cross", role: .instructor, courseID: courseB)
            let ada = try await student("grn_ada16", in: courseA)
            let set = try await CourseGroupStore.createSet(courseID: courseA, name: "Lab sections", on: app.db)
            let group = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db)
            let setID = try set.requireID().uuidString

            let remove = try await post(
                "/instructor/groups/remove", as: outsider, fields: ["groupID": try group.requireID().uuidString])
            #expect(remove.status == .forbidden)
            let move = try await post(
                "/instructor/groups/membership", as: outsider,
                fields: ["setID": setID, "userID": ada.uuidString, "groupID": try group.requireID().uuidString])
            #expect(move.status == .forbidden)
            let imported = try await importFile(
                Data("username,group\ngrn_ada16,Lab 999\n".utf8), setID: setID, as: outsider)
            #expect(imported.status == .forbidden)

            let stored = try #require(try await APICourseGroup.find(group.requireID(), on: app.db))
            #expect(stored.removedAt == nil)
            #expect(try await CourseGroupStore.groups(inSet: set.requireID(), on: app.db).map(\.name) == ["Lab 101"])
            #expect(try await CourseGroupStore.groupIDsByUser(inSet: set.requireID(), on: app.db).isEmpty)
        }
    }

    @Test func aTACannotImportAFile() async throws {
        try await withApp(app) { app in
            let courseID = try await course("GRN17")
            let ta = try await actor("grn_ta", role: .ta, courseID: courseID)
            _ = try await student("grn_ada17", in: courseID)
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let reply = try await importFile(
                Data("username,group\ngrn_ada17,Lab 1\n".utf8), setID: try set.requireID().uuidString, as: ta)
            #expect(reply.status == .forbidden)
            #expect(try await CourseGroupStore.groups(inSet: set.requireID(), on: app.db).isEmpty)
        }
    }
}
