// Tests/APITests/WorkerPollWriteReductionTests.swift
//
// 2026-07 audit: the worker poll previously wrote to the DB on every poll —
// a RunnerProfile UPDATE and a RunnerSnapshot INSERT per check-in, at up to
// 1/s per runner. These tests pin the two write-reduction behaviours:
// unchanged check-ins inside the debounce/sample window persist nothing,
// while any real change (capabilities, reactivation, load shape) or an
// elapsed window persists immediately.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) final class WorkerPollWriteReductionTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-pollwrites")
    }

    private func makeProfile(capability: String = "numpy") -> RunnerCapabilityProfile {
        RunnerCapabilityProfile(
            platform: "linux",
            architecture: "x86_64",
            languageVersions: [LanguageVersion(language: "python", version: "3.11.8")],
            capabilities: [RunnerCapability(name: capability)]
        )
    }

    private func storedLastSeenAt(runnerID: String) async throws -> Date {
        let row = try #require(
            try await RunnerProfile.query(on: app.db)
                .filter(\.$runnerID == runnerID).first())
        return row.lastSeenAt
    }

    // MARK: - RunnerProfile lastSeenAt debounce

    @Test func unchangedCheckInWithinDebounceWindowSkipsWrite() async throws {
        try await withApp(app) { _ in
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let service = app.runnerProfiles

            _ = try await service.registerOrUpdate(
                runnerID: "runner-db1", displayName: "host-a",
                profile: makeProfile(), seenAt: t0, on: app.db)
            let persisted = try await storedLastSeenAt(runnerID: "runner-db1")
            #expect(persisted == t0)

            // 5 s later, identical payload: no write.
            _ = try await service.registerOrUpdate(
                runnerID: "runner-db1", displayName: "host-a",
                profile: makeProfile(), seenAt: t0.addingTimeInterval(5), on: app.db)
            let afterSecond = try await storedLastSeenAt(runnerID: "runner-db1")
            #expect(afterSecond == t0)
        }
    }

    @Test func unchangedCheckInAfterDebounceWindowPersists() async throws {
        try await withApp(app) { _ in
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let service = app.runnerProfiles

            _ = try await service.registerOrUpdate(
                runnerID: "runner-db2", displayName: "host-a",
                profile: makeProfile(), seenAt: t0, on: app.db)

            let late = t0.addingTimeInterval(RunnerProfileService.lastSeenPersistInterval + 1)
            _ = try await service.registerOrUpdate(
                runnerID: "runner-db2", displayName: "host-a",
                profile: makeProfile(), seenAt: late, on: app.db)
            let persisted = try await storedLastSeenAt(runnerID: "runner-db2")
            #expect(persisted == late)
        }
    }

    @Test func changedProfilePersistsImmediatelyDespiteDebounce() async throws {
        try await withApp(app) { _ in
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let service = app.runnerProfiles

            _ = try await service.registerOrUpdate(
                runnerID: "runner-db3", displayName: "host-a",
                profile: makeProfile(capability: "numpy"), seenAt: t0, on: app.db)

            let result = try await service.registerOrUpdate(
                runnerID: "runner-db3", displayName: "host-a",
                profile: makeProfile(capability: "pandas"),
                seenAt: t0.addingTimeInterval(2), on: app.db)
            #expect(result.event == .updated)
            let persisted = try await storedLastSeenAt(runnerID: "runner-db3")
            #expect(persisted == t0.addingTimeInterval(2))

            let row = try #require(
                try await RunnerProfile.query(on: app.db)
                    .filter(\.$runnerID == "runner-db3").first())
            #expect(row.capabilityProfile.capabilities.map(\.name) == ["pandas"])
        }
    }

    @Test func inactiveProfileReactivatesImmediately() async throws {
        try await withApp(app) { _ in
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            let service = app.runnerProfiles

            _ = try await service.registerOrUpdate(
                runnerID: "runner-db4", displayName: "host-a",
                profile: makeProfile(), seenAt: t0, on: app.db)
            let row = try #require(
                try await RunnerProfile.query(on: app.db)
                    .filter(\.$runnerID == "runner-db4").first())
            row.isActive = false
            try await row.save(on: app.db)

            // Within the debounce window, but the runner needs reactivating —
            // must write.
            _ = try await service.registerOrUpdate(
                runnerID: "runner-db4", displayName: "host-a",
                profile: makeProfile(), seenAt: t0.addingTimeInterval(2), on: app.db)
            let reloaded = try #require(
                try await RunnerProfile.query(on: app.db)
                    .filter(\.$runnerID == "runner-db4").first())
            #expect(reloaded.isActive == true)
            #expect(reloaded.lastSeenAt == t0.addingTimeInterval(2))
        }
    }

    // MARK: - RunnerSnapshot sampling

    private func makeSnapshot(
        workerID: String, at date: Date, activeJobs: Int, maxJobs: Int = 4
    ) -> WorkerActivitySnapshot {
        WorkerActivitySnapshot(
            workerID: workerID,
            lastActive: date,
            hostname: "host-a",
            runnerVersion: "runner/1.0",
            maxConcurrentJobs: maxJobs,
            activeJobs: activeJobs,
            lastPollAt: date,
            lastHeartbeatAt: nil,
            serverAssignedJobCountSinceStart: 0
        )
    }

    private func snapshotCount(runnerID: String) async throws -> Int {
        try await RunnerSnapshot.query(on: app.db)
            .filter(\.$runnerID == runnerID)
            .count()
    }

    // Snapshot tests use near-now timestamps: rows dated older than the
    // 30-day snapshot retention get deleted by the prune sweep that runs on
    // the first check-in, which would silently swallow the inserts.
    @Test func identicalCheckInsWithinSampleIntervalPersistOneRow() async throws {
        try await withApp(app) { _ in
            let t0 = Date().addingTimeInterval(-120)
            for offset in [0.0, 1.0, 2.0, 3.0] {
                await app.diagnostics.recordRunnerCheckIn(
                    snapshot: makeSnapshot(workerID: "runner-s1", at: t0.addingTimeInterval(offset), activeJobs: 0),
                    reason: .poll, on: app.db, logger: app.logger)
            }
            let rows = try await snapshotCount(runnerID: "runner-s1")
            #expect(rows == 1)
        }
    }

    @Test func loadShapeChangePersistsImmediately() async throws {
        try await withApp(app) { _ in
            let t0 = Date().addingTimeInterval(-120)
            await app.diagnostics.recordRunnerCheckIn(
                snapshot: makeSnapshot(workerID: "runner-s2", at: t0, activeJobs: 0),
                reason: .poll, on: app.db, logger: app.logger)
            // 1 s later a job is running — must persist despite the interval.
            await app.diagnostics.recordRunnerCheckIn(
                snapshot: makeSnapshot(workerID: "runner-s2", at: t0.addingTimeInterval(1), activeJobs: 1),
                reason: .poll, on: app.db, logger: app.logger)
            let rows = try await snapshotCount(runnerID: "runner-s2")
            #expect(rows == 2)
        }
    }

    @Test func elapsedSampleIntervalPersistsFreshRow() async throws {
        try await withApp(app) { _ in
            let t0 = Date().addingTimeInterval(-120)
            await app.diagnostics.recordRunnerCheckIn(
                snapshot: makeSnapshot(workerID: "runner-s3", at: t0, activeJobs: 0),
                reason: .poll, on: app.db, logger: app.logger)
            let later = t0.addingTimeInterval(RunnerSnapshotSampleStore.defaultSampleInterval + 1)
            await app.diagnostics.recordRunnerCheckIn(
                snapshot: makeSnapshot(workerID: "runner-s3", at: later, activeJobs: 0),
                reason: .poll, on: app.db, logger: app.logger)
            let rows = try await snapshotCount(runnerID: "runner-s3")
            #expect(rows == 2)
        }
    }
}
