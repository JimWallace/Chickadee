// Tests/APITests/ActivityEditPageTests.swift
//
// The instructor edit page's class-activity surface: the "Class activity"
// select (derived from `ActivityKind.allCases`, disabled once a student has
// submitted), the Activity section that renders only when a block is set, and
// the leaderboard-visibility POST that publishes a board without closing or
// re-validating the assignment.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ActivityEditPageTests {

    private func activityManifest(visible: Bool = false) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(
                kind: .beatTheInstructor, leaderboardVisibility: visible ? .visible : .hidden))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private func staff(on app: Application) async throws -> String {
        let cookie = try await wrLoginAsInstructor(on: app)
        let instructor = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
        try await wrEnrollUser(instructor, on: app)
        return cookie
    }

    @Test func ordinaryAssignmentShowsTheSelectAndNoActivitySection() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_ae1", on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_ae1", title: "Plain Lab", isOpen: false, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/edit",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("name=\"activityKind\""))
                    for kind in ActivityKind.allCases {
                        #expect(html.contains("value=\"\(kind.rawValue)\""), "\(kind.rawValue)")
                        #expect(html.contains(kind.displayName))
                    }
                    #expect(!html.contains("Save leaderboard setting"))
                    #expect(!html.contains("id=\"activityKindSelect\" disabled"))
                })
        }
    }

    @Test func activityAssignmentShowsTheSectionAndLocksTheSelectAfterASubmission() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_ae2", manifest: try activityManifest(), on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_ae2", title: "Bot Lab", isOpen: true, on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/edit",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    let html = res.body.string
                    #expect(html.contains("Save leaderboard setting"))
                    #expect(html.contains("/testsetups/setup_ae2/leaderboard"))
                    #expect(html.contains(ActivityKind.beatTheInstructor.displayName))
                    #expect(!html.contains("id=\"activityKindSelect\" disabled"))
                })

            let student = try await makeTestStudent(on: app, username: "ae2_student")
            try await wrEnrollUser(student, on: app)
            try await wrInsertSubmission(
                id: "sub_ae2", testSetupID: "setup_ae2", userID: try student.requireID(), on: app)

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/edit",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    let html = res.body.string
                    #expect(html.contains("id=\"activityKindSelect\" disabled"))
                    #expect(html.contains("locked"))
                })
        }
    }

    @Test func visibilityToggleSetsAndClearsWithoutTouchingTheKind() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_ae3", manifest: try activityManifest(), on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_ae3", title: "Toggle Lab", isOpen: false, on: app)
            let editPath = "/instructor/\(assignment.publicID)/edit"
            let (csrf, cookie) = try await csrfFields(for: editPath, cookie: instructorCookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/activity",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(["_csrf": csrf, "visible": "on"], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            var props = try #require(try await APITestSetup.find("setup_ae3", on: app.db)?.decodedManifest())
            #expect(props.activity == ClassActivity(kind: .beatTheInstructor, leaderboardVisibility: .visible))

            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/activity",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(["_csrf": csrf], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            props = try #require(try await APITestSetup.find("setup_ae3", on: app.db)?.decodedManifest())
            #expect(props.activity == ClassActivity(kind: .beatTheInstructor, leaderboardVisibility: .hidden))
        }
    }

    @Test func visibilityToggleBouncesOnAnOrdinaryAssignment() async throws {
        try await withWebRoutesApp { app in
            let instructorCookie = try await staff(on: app)
            try await wrInsertSetup(id: "setup_ae4", on: app)
            let assignment = try await wrInsertAssignment(
                testSetupID: "setup_ae4", title: "Plain Lab", isOpen: false, on: app)
            let (csrf, cookie) = try await csrfFields(
                for: "/instructor/\(assignment.publicID)/edit", cookie: instructorCookie, on: app)
            try await app.asyncTest(
                .POST, "/instructor/\(assignment.publicID)/activity",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(["_csrf": csrf, "visible": "on"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location)?.contains("error=") == true)
                })
            let props = try #require(try await APITestSetup.find("setup_ae4", on: app.db)?.decodedManifest())
            #expect(props.activity == nil)
        }
    }
}
