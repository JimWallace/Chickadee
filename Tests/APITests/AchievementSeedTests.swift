// Tests/APITests/AchievementSeedTests.swift
//
// Unification C1: the unified GET merges the built-in defaults into the editor
// rows until the instructor first saves the table (builtInAchievementsSeeded),
// after which the manifest is authoritative — so a removed built-in stays gone.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct AchievementSeedTests {

    @Test func defaultsMergeUntilSeededThenManifestIsAuthoritative() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "seed_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "seed_setup", title: "Seed", isOpen: true, on: app)

            // Before any save: the 8 built-in defaults appear as editable rows.
            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(PublishedAssignmentRoutes.AchievementsResponse.self)
                    #expect(body.achievements.count == 8)
                    #expect(body.achievements.contains { $0.id == "first_try_perfect" })
                    #expect(body.achievements.contains { $0.id == "trailblazer" })
                })

            // A unified save with a single custom achievement removes all built-ins.
            try await app.asyncTest(
                .PUT, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(
                        PublishedAssignmentRoutes.AchievementsBody(
                            achievements: [
                                .init(
                                    id: nil, name: "Solo", kind: "thresholdBadge", detail: nil,
                                    thresholdPercent: 90, classPercent: nil, points: nil,
                                    testName: nil, recordDimension: nil, attemptThreshold: nil,
                                    timeThresholdMs: nil, jumpThresholdPercent: nil)
                            ]), as: .json)
                },
                afterResponse: { res in #expect(res.status == .ok) })

            // After seeding: only the curated row — the built-ins stay removed.
            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = try res.content.decode(PublishedAssignmentRoutes.AchievementsResponse.self)
                    #expect(body.achievements.map(\.name) == ["Solo"])
                    #expect(!body.achievements.contains { $0.id == "first_try_perfect" })
                })

            let setup = try #require(try await APITestSetup.find("seed_setup", on: app.db))
            let props = try JSONDecoder().decode(TestProperties.self, from: Data(setup.manifest.utf8))
            #expect(props.builtInAchievementsSeeded)
        }
    }
}
