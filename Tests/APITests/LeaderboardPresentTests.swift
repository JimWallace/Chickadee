// Tests/APITests/LeaderboardPresentTests.swift
//
// Present mode: the leaderboard for a projector. Staff only, never a name, dark
// whatever the viewer prefers, and refreshed through its own fragment.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct LeaderboardPresentTests {

    private func manifest() throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            activity: ClassActivity(kind: .bestMetric, leaderboardVisibility: .visible))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private func get(_ path: String, cookie: String, on app: Application) async throws -> TestingHTTPResponse {
        var captured: TestingHTTPResponse?
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in captured = res })
        return try #require(captured)
    }

    /// Twelve ranked students and a logged-in instructor enrolled as staff.
    private func seed(on app: Application, id: String) async throws -> String {
        _ = try await wrLoginAsStudent(on: app)
        let setup = try await wrInsertSetup(id: id, manifest: try manifest(), on: app)
        _ = try await makeTestAssignment(
            on: app, testSetupID: id, courseID: setup.courseID, title: "Race \(id)")
        for index in 0..<12 {
            let user = try await makeTestUser(on: app, username: "\(id)_s\(index)", role: "student")
            try await wrEnrollUser(user, on: app)
            try await APILeaderboardEntry(
                testSetupID: id, userID: try user.requireID(), submissionID: "\(id)_\(index)",
                metric: Double(100 - index), reachedAt: Date()
            ).save(on: app.db)
        }
        let cookie = try await wrLoginAsInstructor(on: app)
        let instructor = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
        try await wrEnrollUser(instructor, on: app)
        return cookie
    }

    @Test func aStudentCannotOpenPresentMode() async throws {
        try await withWebRoutesApp { app in
            let studentCookie = try await wrLoginAsStudent(on: app)
            let setup = try await wrInsertSetup(id: "lp_stu", manifest: try manifest(), on: app)
            _ = try await makeTestAssignment(
                on: app, testSetupID: "lp_stu", courseID: setup.courseID, title: "Race")
            try await wrEnrollUser(try await wrStudentUser(on: app), on: app)
            let res = try await get(
                "/testsetups/lp_stu/leaderboard?present=1", cookie: studentCookie, on: app)
            #expect(res.status == .notFound)
        }
    }

    @Test func staffGetADarkPodiumPageWithNoSiteChromeAndNoNames() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await seed(on: app, id: "lp_a")
            let res = try await get("/testsetups/lp_a/leaderboard?present=1", cookie: cookie, on: app)
            #expect(res.status == .ok)
            let html = res.body.string
            #expect(html.contains("data-theme=\"dark\""))
            #expect(!html.contains("class=\"nav\""))
            #expect(html.contains("class=\"podium\""))
            #expect(html.components(separatedBy: "class=\"podium-place\"").count - 1 == 3)
            // Places four to ten: seven rows; the eleventh and twelfth are off the wall.
            #expect(html.components(separatedBy: "class=\"present-row\"").count - 1 == 7)
            #expect(html.contains("12 on the board"))
            #expect(html.contains("data-poll-url=\"/testsetups/lp_a/leaderboard?present=1&amp;fragment=present\""))
            // No name and no username, though the viewer is staff.
            #expect(!html.contains("lp_a_s0"))
            #expect(!html.contains("Student One"))
        }
    }

    @Test func thePodiumStandsSecondFirstThird() {
        func place(_ rank: Int) -> PresentPlace {
            PresentPlace(
                rank: rank, rankText: "\(rank)", rankTier: "\(rank)", handle: "h\(rank)",
                valueText: "0",
                avatar: AvatarPresentation(
                    for: AvatarSpec.drawn(fromSeed: UInt64(rank)), size: .podium, accessibility: .decorative))
        }
        #expect(PresentPlace.podiumOrder([place(1), place(2), place(3), place(4)]).map(\.rank) == [2, 1, 3])
        #expect(PresentPlace.podiumOrder([place(1), place(2)]).map(\.rank) == [2, 1])
        #expect(PresentPlace.podiumOrder([place(1)]).map(\.rank) == [1])
        #expect(PresentPlace.podiumOrder([]).isEmpty)
    }

    @Test func theRefreshFragmentIsTheBodyAloneAndAlsoNameless() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await seed(on: app, id: "lp_f")
            let res = try await get(
                "/testsetups/lp_f/leaderboard?present=1&fragment=present", cookie: cookie, on: app)
            #expect(res.status == .ok)
            let html = res.body.string
            #expect(!html.contains("<html"))
            #expect(html.contains("class=\"podium\""))
            #expect(!html.contains("lp_f_s0"))
        }
    }

    @Test func theStaffPageOffersPresentInANewTab() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await seed(on: app, id: "lp_b")
            let html = try await get("/testsetups/lp_b/leaderboard", cookie: cookie, on: app).body.string
            #expect(html.contains("href=\"/testsetups/lp_b/leaderboard?present=1\""))
            #expect(html.contains("target=\"_blank\""))
        }
    }

    @Test func theAttributeDarkBlockMatchesTheMediaQueryBlock() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let css = try String(
            contentsOf: root.appendingPathComponent("Public/styles.css"), encoding: .utf8)
        func declarations(after marker: String) throws -> [String] {
            let start = try #require(css.range(of: marker)).upperBound
            let end = try #require(
                css.range(of: "\n    }\n", range: start..<css.endIndex)
                    ?? css.range(of: "\n}\n", range: start..<css.endIndex)
            ).lowerBound
            return css[start..<end].split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("--") || $0.hasPrefix("color-scheme") }
        }
        let media = try declarations(after: "@media (prefers-color-scheme: dark) {\n    :root {")
        let attribute = try declarations(after: ":root[data-theme=\"dark\"] {")
        #expect(media.count > 30)
        #expect(media == attribute)
    }
}
