// Tests/APITests/AchievementBadgeTests.swift
//
// Phase 4: instructor-authorable individual badges (thresholdBadge / testBadge).
// PUT/GET /instructor/:id/badges round-trips through the manifest, and the
// per-student evaluation (earnedIndividualBadges) awards a badge from the
// student's own result — including one keyed to a secret test.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct AchievementBadgeTests {

    @Test func putAndGetBadgesRoundTrip() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "badge_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "badge_setup", title: "Badges", isOpen: true, on: app)

            try await app.asyncTest(
                .PUT, "/instructor/\(assignment.publicID)/badges",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(
                        PublishedAssignmentRoutes.BadgesBody(badges: [
                            .init(
                                id: nil, name: "Sharpshooter", kind: "thresholdBadge",
                                icon: "🌟", thresholdPercent: 90, testName: nil),
                            .init(
                                id: nil, name: "Recursion Master", kind: "testBadge",
                                icon: "🌀", thresholdPercent: nil, testName: "secrettest_rec.py"),
                        ]), as: .json)
                },
                afterResponse: { res in #expect(res.status == .ok) })

            let setup = try #require(try await APITestSetup.find("badge_setup", on: app.db))
            let props = try JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8))

            let threshold = try #require(props.achievements.first { $0.kind == .thresholdBadge })
            #expect(threshold.scope == .individual)
            #expect(threshold.reward.type == .badge)
            #expect(threshold.reward.icon == "🌟")
            #expect(threshold.threshold == 0.9)

            let test = try #require(props.achievements.first { $0.kind == .testBadge })
            #expect(test.target.kind == .testPass)
            #expect(test.target.ref == "secrettest_rec.py")

            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/badges",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("Sharpshooter"))
                    #expect(body.contains("secrettest_rec.py"))
                })
        }
    }

    @Test func badgesPutRejectsTestRowWithoutFilename() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "badge_bad_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "badge_bad_setup", title: "Bad Badges", isOpen: true, on: app)

            try await app.asyncTest(
                .PUT, "/instructor/\(assignment.publicID)/badges",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(
                        PublishedAssignmentRoutes.BadgesBody(badges: [
                            .init(
                                id: nil, name: "No Test", kind: "testBadge",
                                icon: nil, thresholdPercent: nil, testName: "  ")
                        ]), as: .json)
                },
                afterResponse: { res in #expect(res.status != .ok) })

            let setup = try #require(try await APITestSetup.find("badge_bad_setup", on: app.db))
            let props = try JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8))
            #expect(props.achievements.isEmpty, "Invalid badge must not be written")
        }
    }

    @Test func earnedIndividualBadgesEvaluatesThresholdAndTest() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let props = TestProperties(achievements: [
                Achievement(
                    id: "b_thr", name: "Sharpshooter", kind: .thresholdBadge, scope: .individual,
                    reward: AchievementReward(type: .badge, label: "Sharpshooter", icon: "🌟"),
                    target: AchievementTarget(kind: .assignmentGrade), threshold: 0.8),
                Achievement(
                    id: "b_test", name: "Recursion Master", kind: .testBadge, scope: .individual,
                    reward: AchievementReward(type: .badge, label: "Recursion Master", icon: "🌀"),
                    target: AchievementTarget(kind: .testPass, ref: "secrettest_rec.py")),
            ])
            let manifest = try #require(String(bytes: try JSONEncoder().encode(props), encoding: .utf8))
            let setup = APITestSetup(
                id: "badge_eval_setup", manifest: manifest,
                zipPath: app.testSetupsDirectory + "badge_eval_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)

            let passing = TestOutcome(
                testName: "secrettest_rec.py", testClass: nil, tier: .secret, status: .pass,
                shortResult: "passed", longResult: nil, executionTimeMs: 1, memoryUsageBytes: nil,
                attemptNumber: 1, isFirstPassSuccess: true)

            // 90% + the secret test passing → both badges (the secret test is
            // readable here even though the student never sees it).
            let both = try await earnedIndividualBadges(
                testSetupID: "badge_eval_setup", gradePercent: 90, outcomes: [passing], on: app.db)
            #expect(Set(both.map(\.label)) == ["🌟 Sharpshooter", "🌀 Recursion Master"])

            // 70% + the test failing → neither.
            let failing = TestOutcome(
                testName: "secrettest_rec.py", testClass: nil, tier: .secret, status: .fail,
                shortResult: "failed", longResult: nil, executionTimeMs: 1, memoryUsageBytes: nil,
                attemptNumber: 1, isFirstPassSuccess: false)
            let none = try await earnedIndividualBadges(
                testSetupID: "badge_eval_setup", gradePercent: 70, outcomes: [failing], on: app.db)
            #expect(none.isEmpty)
        }
    }
}
