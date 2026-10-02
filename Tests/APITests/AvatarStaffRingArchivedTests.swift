// Tests/APITests/AvatarStaffRingArchivedTests.swift
//
// The staff ring on the pages that belong to no one course means "teaches
// somewhere", and somewhere means a current offering. A TA whose course is
// archived is a student now, and gets their own ring back (#1756).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AvatarStaffRingArchivedTests {

    /// A user who is a TA in one archived course and nothing else.
    private func formerTA(on app: Application) async throws -> (user: APIUser, course: APICourse) {
        let user = try await arInsertStudent(username: "ring_past_ta", displayName: "Past TA", on: app)
        let past = APICourse(code: "RINGPAST", name: "Past Offering", enrollmentMode: .closed)
        past.isArchived = true
        try await past.save(on: app.db)
        try await APICourseEnrollment(userID: try user.requireID(), courseID: try past.requireID(), role: .ta)
            .save(on: app.db)
        return (user, past)
    }

    @Test func staffInOnlyAnArchivedCourseAreNotStaff() async throws {
        try await withAssignmentRoutesApp { app in
            let (user, past) = try await formerTA(on: app)
            let userID = try user.requireID()
            #expect(try await AvatarStore.courseStaff(among: [userID], on: app.db).isEmpty)

            // Un-archiving the course makes them staff again.
            past.isArchived = false
            try await past.save(on: app.db)
            #expect(try await AvatarStore.courseStaff(among: [userID], on: app.db) == [userID])
        }
    }

    @Test func aFormerTAChoosesARingLikeAnyStudent() async throws {
        try await withAssignmentRoutesApp { app in
            let (user, _) = try await formerTA(on: app)
            let cookie = try await loginUser(
                username: user.username, password: "testpassword", role: "user", on: app)
            var html = ""
            try await app.asyncTest(
                .GET, "/account",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    html = res.body.string
                })
            #expect(!html.contains("#av-ring-staff"))
            #expect(html.contains("name=\"border\""))

            let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
            var location: String?
            try await app.asyncTest(
                .POST, "/account/avatar",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: newCookie)
                    try req.content.encode(["border": "rainbow", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in location = res.headers.first(name: .location) })
            #expect(location == "/account?avatar=saved#chickadee")
            let json = try #require(try await APIUser.find(user.requireID(), on: app.db)?.avatarSpecJSON)
            #expect(try #require(AvatarStore.decode(json)).border == .rainbow)
        }
    }
}
