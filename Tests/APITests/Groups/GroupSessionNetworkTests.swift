// Tests/APITests/Groups/GroupSessionNetworkTests.swift
//
// The network flag on "Who joined" (docs/lab-groups.md, "Presence"), end to
// end: Start records the presenter's network, each join records its own (the
// network part only, never the address, and from the address the proxy saw,
// not one the client named), the staff page marks the join from another
// network, only the presenter moves the presenter's network, and the
// student's data export lists the network.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class GroupSessionNetworkTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-session-networks")
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

    private func post(
        _ path: String, as actor: Actor, from address: String, fields: [String: String], expecting status: HTTPStatus,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: actor.cookie)
                req.headers.add(name: "X-Forwarded-For", value: address)
                var form = fields
                form["_csrf"] = actor.csrf
                try req.content.encode(form, as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == status, "POST \(path): \(res.body.string)", sourceLocation: sourceLocation)
            })
    }

    @Test func aJoinFromAnotherNetworkIsMarkedForStaff() async throws {
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "NET1", mode: .closed)
            let courseID = try course.requireID()
            let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
            let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
            let props = TestProperties(
                testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")], language: nil,
                activity: ClassActivity(kind: .bestMetric, runsPerGroup: true))
            let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
            try await makeTestSetup(on: app, id: "net1_setup", courseID: courseID, manifest: manifest)
            let assignment = try await makeTestAssignment(on: app, testSetupID: "net1_setup", courseID: courseID)

            let ta = try await actor("net_ta", role: .ta, courseID: courseID)
            try await post(
                "/testsetups/net1_setup/sessions/start", as: ta, from: "129.97.12.5",
                fields: ["groupID": labA.uuidString], expecting: .seeOther)
            let session = try #require(
                try await ActivitySessionStore.session(
                    assignmentID: assignment.requireID(), groupID: labA, on: app.db))
            #expect(session.presenterNetwork == "129.97.12.0/24")

            // Six students in the room, and one at home who names the room's
            // network first in the header; the proxy appends the real address.
            let room = (1...6).map { ("net_student\($0)", "129.97.12.\(40 + $0)") }
            let joins = room + [("net_grace", "129.97.12.9, 99.1.2.3")]
            for (username, address) in joins {
                let student = try await actor(username, role: .student, courseID: courseID)
                let code = ActivitySessionCode.code(secret: session.codeSecret, at: Date())
                try await post("/join", as: student, from: address, fields: ["code": code], expecting: .seeOther)
            }
            let networks = try await APIActivitySessionAttendance.query(on: app.db).all().compactMap(\.joinNetwork)
            #expect(Set(networks) == ["129.97.12.0/24", "99.1.2.0/24"], "the network part, never the address")

            let page = try await getHTML(
                "/testsetups/net1_setup/sessions/attendance?group=\(labA.uuidString)", cookie: ta.cookie, on: app)
            #expect(page.components(separatedBy: "Other network").count - 1 == 1, "one join is from another network")

            let grace = try #require(try await APIUser.query(on: app.db).filter(\.$username == "net_grace").first())
            let export = try await gatherDataExportContent(for: grace, on: app.db)
            #expect(export.enrollments.first?.sessionsJoined.first?.network == "99.1.2.0/24")

            // A colleague who opens the present page on another network does
            // not move the presenter's network; the TA who started it does.
            let colleague = try await actor("net_colleague", role: .ta, courseID: courseID)
            let present = "/testsetups/net1_setup/leaderboard?present=1&fragment=join&group=\(labA.uuidString)"
            for (viewer, address) in [(colleague, "10.9.8.7"), (ta, "129.97.13.5")] {
                try await app.asyncTest(
                    .GET, present,
                    beforeRequest: { req in
                        req.headers.add(name: .cookie, value: viewer.cookie)
                        req.headers.add(name: "X-Forwarded-For", value: address)
                    },
                    afterResponse: { res in #expect(res.status == .ok) })
            }
            let moved = try await ActivitySessionStore.session(
                assignmentID: assignment.requireID(), groupID: labA, on: app.db)
            #expect(moved?.presenterNetwork == "129.97.13.0/24")
        }
    }
}
