// Tests/APITests/UnifiedAchievementsTests.swift
//
// Unification B: the single /achievements endpoint round-trips the whole typed
// Achievement list (any kind) via the `achievements` field, while the legacy
// `goals` shape still works for back-compat.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct UnifiedAchievementsTests {

    private func row(
        _ name: String, _ kind: String,
        thresholdPercent: Double? = nil, classPercent: Double? = nil, points: Int? = nil,
        testName: String? = nil, recordDimension: String? = nil, timeThresholdMs: Int? = nil
    ) -> PublishedAssignmentRoutes.AchievementInput {
        .init(
            id: nil, name: name, kind: kind, detail: nil,
            thresholdPercent: thresholdPercent, classPercent: classPercent, points: points,
            testName: testName, recordDimension: recordDimension, attemptThreshold: nil,
            timeThresholdMs: timeThresholdMs, jumpThresholdPercent: nil)
    }

    @Test func unifiedListRoundTripsEveryKind() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "ua_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "ua_setup", title: "UA", isOpen: true, on: app)

            let rows = [
                row("Mastery", "classGoal", thresholdPercent: 80, classPercent: 75, points: 5),
                row("Sharpshooter", "thresholdBadge", thresholdPercent: 90),
                row("Recursion", "testBadge", testName: "secrettest_rec.py"),
                row("Speedy", "classRecord", recordDimension: "fastest"),
                row("Lightning", "speedRun", thresholdPercent: 100, timeThresholdMs: 500),
            ]

            try await app.asyncTest(
                .PUT, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(
                        PublishedAssignmentRoutes.AchievementsBody(goals: nil, achievements: rows),
                        as: .json)
                },
                afterResponse: { res in #expect(res.status == .ok) })

            let setup = try #require(try await APITestSetup.find("ua_setup", on: app.db))
            let props = try JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8))
            #expect(props.achievements.count == 5)
            #expect(
                props.achievements.contains {
                    $0.kind == .classGoal && $0.threshold == 0.8 && $0.classFraction == 0.75
                        && $0.reward.points == 5
                })
            #expect(props.achievements.contains { $0.kind == .thresholdBadge && $0.threshold == 0.9 })
            #expect(props.achievements.contains { $0.kind == .testBadge && $0.target.ref == "secrettest_rec.py" })
            #expect(props.achievements.contains { $0.kind == .classRecord && $0.recordDimension == .fastest })
            #expect(props.achievements.contains { $0.kind == .speedRun && $0.timeThresholdMs == 500 })

            // GET returns the unified rows AND the legacy class-goal projection.
            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(PublishedAssignmentRoutes.AchievementsResponse.self)
                    #expect(body.achievements.count == 5)
                    #expect(body.goals.count == 1, "Legacy goals projection still works")
                })
        }
    }

    @Test func unifiedReplacesWholeListLegacyGoalsPreserveOthers() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "ur_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "ur_setup", title: "UR", isOpen: true, on: app)

            // Seed a badge + a goal via the unified PUT.
            try await app.asyncTest(
                .PUT, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(
                        PublishedAssignmentRoutes.AchievementsBody(
                            goals: nil,
                            achievements: [
                                row("Goal", "classGoal", thresholdPercent: 80, classPercent: 80, points: 3),
                                row("Badge", "thresholdBadge", thresholdPercent: 90),
                            ]), as: .json)
                },
                afterResponse: { res in #expect(res.status == .ok) })

            // A legacy goals-only PUT replaces just the class goals, preserving the badge.
            try await app.asyncTest(
                .PUT, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(
                        PublishedAssignmentRoutes.AchievementsBody(
                            goals: [
                                .init(id: nil, name: "Goal2", thresholdPercent: 70, classPercent: 60, bonusPoints: 2)
                            ],
                            achievements: nil), as: .json)
                },
                afterResponse: { res in #expect(res.status == .ok) })

            let setup = try #require(try await APITestSetup.find("ur_setup", on: app.db))
            let props = try JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8))
            #expect(props.achievements.contains { $0.kind == .thresholdBadge }, "Badge preserved")
            #expect(props.achievements.filter { $0.kind == .classGoal }.map(\.name) == ["Goal2"])
        }
    }
}
