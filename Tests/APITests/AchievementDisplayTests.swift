// Tests/APITests/AchievementDisplayTests.swift
//
// Phase 3a display: the student submission page renders an "Achievements"
// section with a live progress bar for each class goal, reading the manifest
// spec joined with the latest `APIAchievementResult` snapshot.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct AchievementDisplayTests {

    @Test func submissionPageShowsClassGoalProgress() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrEnrollUser(student, on: app)
            try await wrInsertSetup(id: "cg_setup", on: app)

            // Replace the default manifest with one carrying a class goal.
            let props = TestProperties(
                achievements: [
                    Achievement(
                        id: "goalX", name: "Mastery Goal", scope: .classWide,
                        conditions: [
                            AchievementCondition(signal: .grade, comparator: .atLeast, value: 80)
                        ],
                        reward: AchievementReward(type: .points, label: "Mastery", points: 5),
                        classFraction: 0.8)
                ])
            let setup = try #require(try await APITestSetup.find("cg_setup", on: app.db))
            let data = try JSONEncoder().encode(props)
            setup.manifest = try #require(String(bytes: data, encoding: .utf8))
            try await setup.save(on: app.db)

            // The sweep's snapshot: 41 of 64 students, 80% of the goal.
            try await APIAchievementResult(
                testSetupID: "cg_setup", achievementID: "goalX",
                studentsMeeting: 41, denominator: 64, progress: 0.8, locked: false,
                evaluatedAt: Date()
            ).save(on: app.db)

            _ = try await wrInsertAssignment(
                testSetupID: "cg_setup", title: "Goals", isOpen: true, on: app)
            _ = try await wrInsertSubmission(
                id: "cg_sub", testSetupID: "cg_setup", userID: try student.requireID(), on: app)
            _ = try await wrInsertResult(
                submissionID: "cg_sub", outcomes: [wrMakeOutcome(name: "t1", status: .pass)], on: app)

            try await app.asyncTest(
                .GET, "/submissions/cg_sub",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("Class goals"))
                    #expect(body.contains("Mastery Goal"))
                    #expect(body.contains("80% of the way"))
                    #expect(body.contains("41 / 64 students"))
                    #expect(body.contains("+5 pts"))
                    #expect(body.contains(#"<progress class="class-goal-progress" max="100" value="80">"#))
                })
        }
    }
}
