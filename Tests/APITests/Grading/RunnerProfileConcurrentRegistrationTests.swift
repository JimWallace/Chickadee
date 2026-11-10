// Tests/APITests/Grading/RunnerProfileConcurrentRegistrationTests.swift
//
// A new runner polls from every job slot at once, so its first check-ins
// reach `registerOrUpdate` concurrently. Each one read "no profile row" and
// inserted one; every insert after the first hit the unique constraint on
// `runner_profiles.runner_id`, and that poll answered HTTP 500. These tests
// pin the fix: concurrent first check-ins all succeed and leave one row.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) final class RunnerProfileConcurrentRegistrationTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-profile-race")
    }

    private func makeProfile() -> RunnerCapabilityProfile {
        RunnerCapabilityProfile(
            platform: "linux",
            architecture: "arm64",
            languageVersions: [LanguageVersion(language: "python", version: "3.14.4")],
            capabilities: [RunnerCapability(name: "numpy")]
        )
    }

    @Test func concurrentFirstCheckInsAllSucceedWithOneRow() async throws {
        try await withApp(app) { app in
            let service = app.runnerProfiles
            let db = app.db
            let profile = makeProfile()
            let seenAt = Date()

            let events = try await withThrowingTaskGroup(
                of: RunnerProfileRegistrationEvent?.self,
                returning: [RunnerProfileRegistrationEvent?].self
            ) { group in
                for _ in 0..<8 {
                    group.addTask {
                        try await service.registerOrUpdate(
                            runnerID: "runner-race", displayName: "race-host",
                            profile: profile, seenAt: seenAt, on: db
                        ).event
                    }
                }
                var collected: [RunnerProfileRegistrationEvent?] = []
                for try await event in group { collected.append(event) }
                return collected
            }

            let rows = try await RunnerProfile.query(on: db)
                .filter(\.$runnerID == "runner-race")
                .count()
            #expect(rows == 1)
            #expect(events.count == 8)
            // Exactly one check-in created the row; a check-in that lost the
            // race found the same profile and reports no event.
            #expect(events.filter { $0 == .registered }.count == 1)
        }
    }
}
