// Tests/APITests/ValidationRunnerAvailabilityTests.swift
//
// Regression tests for the validation pre-check's runner-liveness window.
// `RunnerProfile.lastSeenAt` is debounced (2026-07 poll-write audit): an
// unchanged runner check-in persists freshness at most once per
// `RunnerProfileService.lastSeenPersistInterval`, so a live runner's
// persisted timestamp lags real time by up to ~90 s (debounce + heartbeat
// gap). The pre-check used to probe that column with a 20 s window, so for
// most of every debounce cycle a healthy fleet looked stale and a
// metadata-only assignment save (e.g. a due-date edit) landed on
// `validationStatus = "no-runner"` with runners online.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer
@testable import Core

/// App-less invariant suite: the pre-check window must out-wait
/// persisted-freshness lag — the `lastSeenAt` debounce plus the runner's
/// worst-case check-in gap (~30 s heartbeat). Guards the window against
/// being re-tightened below the debounce, which is what produced the
/// spurious "no-runner".
@Suite struct ValidationRunnerWindowInvariantTests {
    @Test func defaultWindowExceedsPersistDebouncePlusHeartbeat() {
        #expect(
            validationRunnerActiveWindowSeconds
                > RunnerProfileService.lastSeenPersistInterval + 30)
    }
}

@Suite(.serialized) final class ValidationRunnerAvailabilityTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-valrunner")
    }

    private func makeProfile() -> RunnerCapabilityProfile {
        RunnerCapabilityProfile(
            platform: "linux",
            architecture: "x86_64",
            languageVersions: [LanguageVersion(language: "python", version: "3.11.8")],
            capabilities: [RunnerCapability(name: "numpy")]
        )
    }

    /// A runner whose *persisted* freshness is as stale as the debounce
    /// allows for a live, polling runner must still count as available
    /// under the default pre-check window.
    @Test func liveRunnerWithDebouncedLastSeenCountsAsAvailable() async throws {
        try await withApp(app) { _ in
            // 85 s ago: past the 60 s debounce — a healthy runner's stored
            // timestamp really does get this old — and well past the old
            // 20 s window that spuriously failed here. 35 s of slack to the
            // 120 s default keeps the test tolerant of a slow CI host.
            let staleSeenAt = Date().addingTimeInterval(
                -(RunnerProfileService.lastSeenPersistInterval + 25))
            _ = try await app.runnerProfiles.registerOrUpdate(
                runnerID: "val-live", displayName: "host-a",
                profile: makeProfile(), seenAt: staleSeenAt, on: app.db)

            let req = Request(application: app, on: app.eventLoopGroup.next())
            let available = try await hasCompatibleValidationRunner(
                req: req, requirements: nil)
            #expect(available == true)

            // The probe must not knock the live runner's profile inactive
            // either — the pre-fix refresh flipped the whole fleet off as a
            // side effect of every save.
            let row = try #require(
                try await RunnerProfile.query(on: app.db)
                    .filter(\.$runnerID == "val-live").first())
            #expect(row.isActive == true)
        }
    }

    /// A genuinely dead runner — silent for far longer than the debounce
    /// can explain — is still filtered out, so the pre-check keeps
    /// catching real no-runner deployments.
    @Test func longSilentRunnerStillCountsAsUnavailable() async throws {
        try await withApp(app) { _ in
            let deadSeenAt = Date().addingTimeInterval(-600)
            _ = try await app.runnerProfiles.registerOrUpdate(
                runnerID: "val-dead", displayName: "host-b",
                profile: makeProfile(), seenAt: deadSeenAt, on: app.db)

            let req = Request(application: app, on: app.eventLoopGroup.next())
            let available = try await hasCompatibleValidationRunner(
                req: req, requirements: nil)
            #expect(available == false)
        }
    }
}
