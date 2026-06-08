// Tests/APITests/AchievementAuthoringTests.swift
//
// Phase 5 authoring: the instructor edit page's "Class Goals" card persists
// class goals into the assignment manifest via PUT /instructor/:id/achievements
// (and reads them back via GET). Display-only, so the save does not retest or
// re-validate.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct AchievementAuthoringTests {

    @Test func putAndGetClassGoalsRoundTrip() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "cga_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "cga_setup", title: "Goals", isOpen: true, on: app)

            try await app.asyncTest(
                .PUT, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(
                        PublishedAssignmentRoutes.AchievementsBody(goals: [
                            .init(
                                id: nil, name: "80% Mastery",
                                thresholdPercent: 80, classPercent: 80, bonusPoints: 5)
                        ]), as: .json)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                })

            // The manifest now carries the class goal, encoded as an Achievement.
            let setup = try #require(try await APITestSetup.find("cga_setup", on: app.db))
            let props = try JSONDecoder().decode(
                TestProperties.self, from: Data(setup.manifest.utf8))
            let goal = try #require(props.achievements.first { $0.kind == .classGoal })
            #expect(goal.name == "80% Mastery")
            #expect(goal.scope == .classWide)
            #expect(goal.threshold == 0.8)
            #expect(goal.classFraction == 0.8)
            #expect(goal.reward.type == .points)
            #expect(goal.reward.points == 5)

            // GET returns it as an editable row (percent units back out).
            try await app.asyncTest(
                .GET, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(body.contains("80% Mastery"))
                    #expect(body.contains("\"thresholdPercent\":80"))
                })
        }
    }

    @Test func putRejectsOutOfRangeThreshold() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
            try await arInsertSetup(id: "cga_bad_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "cga_bad_setup", title: "Bad Goals", isOpen: true, on: app)

            try await app.asyncTest(
                .PUT, "/instructor/\(assignment.publicID)/achievements",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    try req.content.encode(
                        PublishedAssignmentRoutes.AchievementsBody(goals: [
                            .init(
                                id: nil, name: "Impossible",
                                thresholdPercent: 150, classPercent: 80, bonusPoints: 5)
                        ]), as: .json)
                },
                afterResponse: { res in
                    #expect(res.status != .ok, "Out-of-range threshold must be rejected")
                })

            let setup = try #require(try await APITestSetup.find("cga_bad_setup", on: app.db))
            let props = try JSONDecoder().decode(
                TestProperties.self, from: Data(setup.manifest.utf8))
            #expect(props.achievements.isEmpty, "Rejected goal must not be written")
        }
    }
}
