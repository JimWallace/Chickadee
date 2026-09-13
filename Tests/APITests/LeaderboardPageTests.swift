// Tests/APITests/LeaderboardPageTests.swift
//
// GET /testsetups/:id/leaderboard and its vanity twin. The properties that
// matter are who can open it and what a viewer is shown: a student sees
// handles and never a real name, staff see both, a hidden board is a 404 to a
// student and a chip to staff, and an ordinary assignment has no board at all.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct LeaderboardPageTests {

    private func activityManifest(visible: Bool) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(
                kind: .bestMetric, leaderboardVisibility: visible ? .visible : .hidden))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// The logged-in student plus one classmate, both ranked.
    private func seedRankedClass(
        on app: Application, setupID: String, visible: Bool
    ) async throws -> (viewer: APIUser, classmate: APIUser) {
        let setup = try await wrInsertSetup(
            id: setupID, manifest: try activityManifest(visible: visible), on: app)
        _ = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: setup.courseID, title: "Race \(setupID)")
        let viewer = try await wrStudentUser(on: app)
        try await wrEnrollUser(viewer, on: app)
        let classmate = try await makeTestUser(on: app, username: "\(setupID)_mate", role: "student")
        try await wrEnrollUser(classmate, on: app)
        // The classmate leads; the viewer trails.
        try await APILeaderboardEntry(
            testSetupID: setupID, userID: try classmate.requireID(),
            submissionID: "\(setupID)_m", metric: 42, reachedAt: Date()
        ).save(on: app.db)
        try await APILeaderboardEntry(
            testSetupID: setupID, userID: try viewer.requireID(),
            submissionID: "\(setupID)_v", metric: 7.5, reachedAt: Date()
        ).save(on: app.db)
        return (viewer, classmate)
    }

    private func get(_ path: String, cookie: String, on app: Application) async throws -> TestingHTTPResponse {
        var captured: TestingHTTPResponse?
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in captured = res })
        return try #require(captured)
    }

    @Test func studentSeesHandlesAndRanksButNoRealNames() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let seeded = try await seedRankedClass(on: app, setupID: "lb_vis", visible: true)

            let res = try await get("/testsetups/lb_vis/leaderboard", cookie: cookie, on: app)
            #expect(res.status == .ok)
            let html = res.body.string
            // Both rows appear under their handles, materialised on this view.
            let enrollments = try await APICourseEnrollment.query(on: app.db).all()
            let handles = enrollments.compactMap(\.avatarHandle)
            #expect(handles.count == 2)
            for handle in handles { #expect(html.contains(handle)) }
            // Never a real name for a student viewer.
            #expect(!html.contains(seeded.classmate.username))
            #expect(!html.contains("<th>Name</th>"))
            // The viewer's own row is marked, and the metric prints cleanly.
            #expect(html.contains(">you<"))
            #expect(html.contains(">42<"))
            #expect(html.contains(">7.5<"))
            #expect(!html.contains("Hidden from students"))
        }
    }

    @Test func hiddenLeaderboardIs404ForAStudent() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            _ = try await seedRankedClass(on: app, setupID: "lb_hid", visible: false)
            let res = try await get("/testsetups/lb_hid/leaderboard", cookie: cookie, on: app)
            #expect(res.status == .notFound)
        }
    }

    @Test func staffSeeAHiddenLeaderboardWithNamesAndTheHiddenChip() async throws {
        try await withWebRoutesApp { app in
            _ = try await wrLoginAsStudent(on: app)  // creates the student row
            let seeded = try await seedRankedClass(on: app, setupID: "lb_staff", visible: false)
            let cookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)

            let res = try await get("/testsetups/lb_staff/leaderboard", cookie: cookie, on: app)
            #expect(res.status == .ok)
            let html = res.body.string
            #expect(html.contains("Hidden from students"))
            #expect(html.contains("<th>Name</th>"))
            #expect(html.contains(seeded.classmate.username))
            #expect(html.contains(seeded.viewer.username))
        }
    }

    @Test func anOrdinaryAssignmentHasNoLeaderboard() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            try await wrEnrollUser(user, on: app)
            _ = try await wrInsertSetup(id: "lb_plain", on: app)
            let res = try await get("/testsetups/lb_plain/leaderboard", cookie: cookie, on: app)
            #expect(res.status == .notFound)
        }
    }

    @Test func vanityPathRedirectsToTheCanonicalLeaderboard() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            _ = try await seedRankedClass(on: app, setupID: "lb_van", visible: true)
            let res = try await get("/cs101/race-lb-van/leaderboard", cookie: cookie, on: app)
            #expect(res.status == .seeOther)
            #expect(res.headers.first(name: .location) == "/testsetups/lb_van/leaderboard")
        }
    }

    @Test func submissionPageLinksTheLeaderboardOnlyWhenOpenToTheViewer() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let user = try await wrStudentUser(on: app)
            let userID = try user.requireID()
            try await wrEnrollUser(user, on: app)
            _ = try await wrInsertSetup(id: "lb_link_vis", manifest: try activityManifest(visible: true), on: app)
            _ = try await wrInsertSetup(id: "lb_link_hid", manifest: try activityManifest(visible: false), on: app)
            try await wrInsertSubmission(id: "sub_lb_vis", testSetupID: "lb_link_vis", userID: userID, on: app)
            try await wrInsertSubmission(id: "sub_lb_hid", testSetupID: "lb_link_hid", userID: userID, on: app)
            try await wrInsertResult(
                submissionID: "sub_lb_vis", outcomes: [wrMakeOutcome(name: "m", status: .pass)], on: app)
            try await wrInsertResult(
                submissionID: "sub_lb_hid", outcomes: [wrMakeOutcome(name: "m", status: .pass)], on: app)

            let visible = try await get("/submissions/sub_lb_vis", cookie: cookie, on: app)
            #expect(visible.body.string.contains("/testsetups/lb_link_vis/leaderboard"))
            let hidden = try await get("/submissions/sub_lb_hid", cookie: cookie, on: app)
            #expect(!hidden.body.string.contains("/leaderboard"))
        }
    }

    @Test(arguments: [(1234.0, "1234"), (7.5, "7.5"), (0.75, "0.75"), (-7.0, "-7"), (2.0 / 3.0, "0.667")])
    func metricFormatting(metric: Double, expected: String) {
        #expect(formatLeaderboardMetric(metric) == expected)
    }
}
