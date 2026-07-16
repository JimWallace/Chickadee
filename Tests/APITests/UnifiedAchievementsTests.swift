// Tests/APITests/UnifiedAchievementsTests.swift
//
// The single /achievements endpoint round-trips the whole typed Achievement
// list (any scope) via the `achievements` field; every PUT replaces the list
// wholesale.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct UnifiedAchievementsTests {

    private func cond(
        _ signal: String, _ comparator: String, _ value: Double, testRef: String? = nil
    ) -> PublishedAssignmentRoutes.ConditionInput {
        .init(signal: signal, comparator: comparator, value: value, testRef: testRef)
    }

    private func row(
        _ name: String, scope: String, match: String = "all",
        conditions: [PublishedAssignmentRoutes.ConditionInput] = [],
        classPercent: Double? = nil, points: Int? = nil, recordDimension: String? = nil
    ) -> PublishedAssignmentRoutes.AchievementInput {
        .init(
            id: nil, name: name, detail: nil, scope: scope, match: match,
            conditions: conditions, classPercent: classPercent, points: points,
            recordDimension: recordDimension)
    }

    @Test func unifiedListRoundTripsEveryScope() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "ua_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "ua_setup", title: "UA", isOpen: true, on: app)

            let rows = [
                row(
                    "Mastery", scope: "classWide",
                    conditions: [cond("grade", "atLeast", 80)], classPercent: 75, points: 5),
                row("Sharpshooter", scope: "individual", conditions: [cond("grade", "atLeast", 90)]),
                // The ref must resolve against the fixture suite (test.sh) —
                // save-time validation rejects unknown testPass refs now.
                row(
                    "Recursion", scope: "individual",
                    conditions: [cond("testPass", "atLeast", 1, testRef: "test.sh")]),
                row("Speedy", scope: "record", recordDimension: "fastest"),
                row(
                    "Lightning", scope: "individual",
                    conditions: [cond("grade", "atLeast", 100), cond("executionTimeMs", "atMost", 500)]),
            ]

            try await app.asyncTest(
                .PUT, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(
                        PublishedAssignmentRoutes.AchievementsBody(achievements: rows),
                        as: .json)
                },
                afterResponse: { res in #expect(res.status == .ok) })

            let setup = try #require(try await APITestSetup.find("ua_setup", on: app.db))
            let props = try JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8))
            #expect(props.achievements.count == 5)
            #expect(
                props.achievements.contains {
                    $0.isClassGoal && $0.gradeThresholdFraction == 0.8 && $0.classFraction == 0.75
                        && $0.reward.points == 5
                })
            #expect(
                props.achievements.contains {
                    $0.name == "Sharpshooter" && $0.isAuthorableIndividualBadge
                        && $0.gradeThresholdFraction == 0.9
                })
            #expect(
                props.achievements.contains { a in
                    a.name == "Recursion"
                        && a.conditions.contains {
                            $0.signal == .testPass && $0.target?.ref == "test.sh"
                        }
                })
            #expect(props.achievements.contains { $0.isClassRecord && $0.recordDimension == .fastest })
            #expect(
                props.achievements.contains { a in
                    a.name == "Lightning" && a.isPerSubmissionBadge
                        && a.conditions.contains { $0.signal == .executionTimeMs && $0.value == 500 }
                })

            // GET returns the unified rows.
            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(PublishedAssignmentRoutes.AchievementsResponse.self)
                    #expect(body.achievements.count == 5)
                })
        }
    }

    @Test func putReplacesTheWholeList() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "ur_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "ur_setup", title: "UR", isOpen: true, on: app)

            // Seed a goal + a badge.
            try await app.asyncTest(
                .PUT, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(
                        PublishedAssignmentRoutes.AchievementsBody(achievements: [
                            row(
                                "Goal", scope: "classWide",
                                conditions: [cond("grade", "atLeast", 80)], classPercent: 80, points: 3),
                            row("Badge", scope: "individual", conditions: [cond("grade", "atLeast", 90)]),
                        ]), as: .json)
                },
                afterResponse: { res in #expect(res.status == .ok) })

            // A second PUT replaces the entire list — nothing merges in.
            try await app.asyncTest(
                .PUT, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(
                        PublishedAssignmentRoutes.AchievementsBody(achievements: [
                            row(
                                "Goal2", scope: "classWide",
                                conditions: [cond("grade", "atLeast", 70)], classPercent: 60, points: 2)
                        ]), as: .json)
                },
                afterResponse: { res in #expect(res.status == .ok) })

            let setup = try #require(try await APITestSetup.find("ur_setup", on: app.db))
            let props = try JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8))
            #expect(props.achievements.map(\.name) == ["Goal2"])
        }
    }
}
