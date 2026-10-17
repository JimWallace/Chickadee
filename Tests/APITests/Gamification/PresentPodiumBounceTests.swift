// Tests/APITests/Gamification/PresentPodiumBounceTests.swift
//
// The Present-mode podium bounces when the board first shows and when the top
// three change (#2591). The podium carries its three handles as a key, which
// present-podium.js compares across refreshes; the page and the refreshed
// fragment must both carry it.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct PresentPodiumBounceTests {

    private func manifest() throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            language: nil,
            activity: ClassActivity(kind: .bestMetric, leaderboardVisibility: .visible))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// Five ranked students and a logged-in instructor enrolled as staff.
    /// Returns the cookie and the students, best first.
    private func seed(on app: Application, id: String) async throws -> (String, [APIUser]) {
        _ = try await wrLoginAsStudent(on: app)
        let setup = try await wrInsertSetup(id: id, manifest: try manifest(), on: app)
        _ = try await makeTestAssignment(
            on: app, testSetupID: id, courseID: setup.courseID, title: "Race \(id)")
        var students: [APIUser] = []
        for index in 0..<5 {
            let user = try await makeTestUser(on: app, username: "\(id)_s\(index)", role: "student")
            try await wrEnrollUser(user, on: app)
            try await APILeaderboardEntry(
                testSetupID: id, userID: try user.requireID(), submissionID: "\(id)_\(index)",
                metric: Double(100 - index), reachedAt: Date()
            ).save(on: app.db)
            students.append(user)
        }
        let cookie = try await wrLoginAsInstructor(on: app)
        let instructor = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
        try await wrEnrollUser(instructor, on: app)
        return (cookie, students)
    }

    /// The podium's key in `html`.
    private func podiumKey(in html: String) throws -> String {
        let start = try #require(html.range(of: "class=\"podium\" data-podium-key=\""), "no podium key")
        let end = try #require(html[start.upperBound...].firstIndex(of: "\""))
        return String(html[start.upperBound..<end])
    }

    /// The three podium handles in `html`, in podium order.
    private func podiumHandles(in html: String) -> [String] {
        html.components(separatedBy: "class=\"podium-handle\" data-avatar-handle>").dropFirst().compactMap {
            $0.components(separatedBy: "<").first
        }
    }

    @Test func thePodiumCarriesItsThreeHandlesAndThePageLoadsTheScript() async throws {
        try await withWebRoutesApp { app in
            let (cookie, _) = try await seed(on: app, id: "pb_a")
            let html = try await getHTML("/testsetups/pb_a/leaderboard?present=1", cookie: cookie, on: app)
            #expect(html.contains("/present-podium.js"))
            let handles = podiumHandles(in: html)
            #expect(handles.count == 3)
            #expect(try podiumKey(in: html) == handles.joined(separator: "|"))
        }
    }

    @Test func theRefreshedFragmentKeepsTheKeyUntilTheTopThreeChange() async throws {
        try await withWebRoutesApp { app in
            let (cookie, students) = try await seed(on: app, id: "pb_b")
            let fragment = "/testsetups/pb_b/leaderboard?present=1&fragment=present"
            let first = try podiumKey(in: try await getHTML(fragment, cookie: cookie, on: app))

            // Fourth place improves but stays fourth: the key holds.
            let fourth = try #require(
                try await APILeaderboardEntry.query(on: app.db)
                    .filter(\.$userID == students[3].requireID()).first())
            fourth.metric = 97.5
            try await fourth.save(on: app.db)
            #expect(try podiumKey(in: try await getHTML(fragment, cookie: cookie, on: app)) == first)

            // Fifth place takes the lead: the key changes.
            let fifth = try #require(
                try await APILeaderboardEntry.query(on: app.db)
                    .filter(\.$userID == students[4].requireID()).first())
            fifth.metric = 1000
            try await fifth.save(on: app.db)
            #expect(try podiumKey(in: try await getHTML(fragment, cookie: cookie, on: app)) != first)
        }
    }
}
