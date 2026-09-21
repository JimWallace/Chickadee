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

    // MARK: - The hill (king of the hill, slice 3)

    private func hillManifest() throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(kind: .kingOfTheHill, leaderboardVisibility: .visible, opponentFile: "bot.py"))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// The page names the hill's holder by handle with the streak, and says
    /// so when no student holds it yet; a student viewer never sees a name.
    @Test func theHillsHolderIsShownByHandleWithTheStreak() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let setup = try await wrInsertSetup(id: "lb_hill", manifest: try hillManifest(), on: app)
            _ = try await makeTestAssignment(
                on: app, testSetupID: "lb_hill", courseID: setup.courseID, title: "Hill")
            let viewer = try await wrStudentUser(on: app)
            try await wrEnrollUser(viewer, on: app)
            let holder = try await makeTestUser(on: app, username: "lb_hill_holder", role: "student")
            try await wrEnrollUser(holder, on: app)

            let empty = try await get("/testsetups/lb_hill/leaderboard", cookie: cookie, on: app)
            #expect(empty.status == .ok)
            #expect(empty.body.string.contains("No student holds the hill yet"))

            try await APIActivityChampion(
                testSetupID: "lb_hill", userID: try holder.requireID(), submissionID: "lb_hill_h",
                crownedAt: Date(), defences: 3
            ).save(on: app.db)
            let res = try await get("/testsetups/lb_hill/leaderboard", cookie: cookie, on: app)
            #expect(res.status == .ok)
            let html = res.body.string
            #expect(html.contains("Champion:"))
            #expect(html.contains("3 defences"))
            #expect(html.contains("took the hill"))
            #expect(html.contains("js-relative-time"))
            let enrollment = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == (try holder.requireID())).first())
            #expect(html.contains(try #require(enrollment.avatarHandle)))
            #expect(!html.contains("lb_hill_holder"))
            #expect(!html.contains("No student holds the hill yet"))
        }
    }

    // MARK: - The standings (round robin, slice 4)

    private func robinManifest() throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(kind: .roundRobin, leaderboardVisibility: .visible))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// A round robin's page shows the standings — played, won, drawn, lost,
    /// average — by handle, best first, with the viewer's row marked; a
    /// student viewer never sees a name.
    @Test func aRoundRobinShowsTheStandingsByHandle() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let setup = try await wrInsertSetup(id: "lb_robin", manifest: try robinManifest(), on: app)
            _ = try await makeTestAssignment(
                on: app, testSetupID: "lb_robin", courseID: setup.courseID, title: "Robin")
            let viewer = try await wrStudentUser(on: app)
            try await wrEnrollUser(viewer, on: app)
            let mate = try await makeTestUser(on: app, username: "lb_robin_mate", role: "student")
            try await wrEnrollUser(mate, on: app)

            let empty = try await get("/testsetups/lb_robin/leaderboard", cookie: cookie, on: app)
            #expect(empty.status == .ok)
            #expect(empty.body.string.contains("No submission has played a match yet"))
            #expect(!empty.body.string.contains("ranking metric"))

            try await APIActivityStanding(
                testSetupID: "lb_robin", userID: try mate.requireID(), submissionID: "lb_robin_m",
                played: 4, wins: 3, draws: 1, losses: 0, scoreSum: 3.5, updatedAt: Date()
            ).save(on: app.db)
            try await APIActivityStanding(
                testSetupID: "lb_robin", userID: try viewer.requireID(), submissionID: "lb_robin_v",
                played: 4, wins: 1, draws: 0, losses: 3, scoreSum: 1, updatedAt: Date()
            ).save(on: app.db)
            let res = try await get("/testsetups/lb_robin/leaderboard", cookie: cookie, on: app)
            #expect(res.status == .ok)
            let html = res.body.string
            #expect(html.contains("<th class=\"time\">Played</th>"))
            #expect(html.contains("Highest average match score first"))
            let mateEnrollment = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == (try mate.requireID())).first())
            let mateHandle = try #require(mateEnrollment.avatarHandle)
            let viewerEnrollment = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == (try viewer.requireID())).first())
            let viewerHandle = try #require(viewerEnrollment.avatarHandle)
            let mateAt = try #require(html.range(of: mateHandle)?.lowerBound)
            let viewerAt = try #require(html.range(of: viewerHandle)?.lowerBound)
            #expect(mateAt < viewerAt)
            #expect(html.contains("0.875"))
            #expect(html.contains("<span class=\"chip\">you</span>"))
            #expect(!html.contains("lb_robin_mate"))
        }
    }
}
