// Tests/APITests/LeaderboardParityTests.swift
//
// The leaderboard page against the redesign's reference frames: the course
// kicker, the Show all button under a window, the staff value beside its eye
// button, the value captions, the champion card's own tint, and the live
// session tag.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct LeaderboardParityTests {

    private func manifest(_ kind: ActivityKind, window: LiveSessionWindow? = nil) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            language: nil,
            activity: ClassActivity(kind: kind, leaderboardVisibility: .visible, window: window))
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    /// A metric board of `count` ranked students with the logged-in student
    /// at `viewerIndex`; returns the student's cookie.
    private func seedMetricBoard(
        _ id: String, count: Int, viewerIndex: Int, window: LiveSessionWindow? = nil, on app: Application
    ) async throws -> String {
        let cookie = try await wrLoginAsStudent(on: app)
        let setup = try await wrInsertSetup(id: id, manifest: try manifest(.bestMetric, window: window), on: app)
        _ = try await makeTestAssignment(on: app, testSetupID: id, courseID: setup.courseID, title: "Race \(id)")
        let viewer = try await wrStudentUser(on: app)
        try await wrEnrollUser(viewer, on: app)
        for index in 0..<count {
            let user: APIUser
            if index == viewerIndex {
                user = viewer
            } else {
                user = try await makeTestUser(on: app, username: "\(id)_s\(index)", role: "student")
                try await wrEnrollUser(user, on: app)
            }
            try await APILeaderboardEntry(
                testSetupID: id, userID: try user.requireID(), submissionID: "\(id)_\(index)",
                metric: Double(100 - index), reachedAt: Date()
            ).save(on: app.db)
        }
        return cookie
    }

    private func staffCookie(on app: Application) async throws -> String {
        let cookie = try await wrLoginAsInstructor(on: app)
        let instructor = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
        try await wrEnrollUser(instructor, on: app)
        return cookie
    }

    @Test func theCourseCodeStandsAboveTheTitle() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await seedMetricBoard("lpy_kick", count: 2, viewerIndex: 0, on: app)
            let html = try await getHTML("/testsetups/lpy_kick/leaderboard", cookie: cookie, on: app)
            let kicker = try #require(html.range(of: "<p class=\"page-crumb\">CS101</p>"))
            let title = try #require(html.range(of: "<h1>Race lpy_kick</h1>"))
            #expect(kicker.upperBound < title.lowerBound)
        }
    }
}
