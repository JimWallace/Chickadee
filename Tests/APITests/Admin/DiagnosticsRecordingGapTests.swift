// Tests/APITests/Admin/DiagnosticsRecordingGapTests.swift
//
// The failure paths of the diagnostics recorder and the queue-depth
// queries: a write that fails leaves one warning that names the job and
// the error and nothing else (no student identifier), the store-agnostic
// fallbacks count what the SQL path counts, and the timeline counts the
// jobs already waiting when its window opens.

import Fluent
import Foundation
import Logging
import NIOCore
import Synchronization
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized, .timeLimit(.minutes(10))) final class DiagnosticsRecordingGapTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-diag-gap")
    }

    // MARK: - Recording: a failed write is one warning, and redacted

    @Test func aFailedSubmissionCreateLogsOneRedactedWarning() async throws {
        try await withApp(app) { _ in
            let (submission, userID) = try await makeStudentSubmission(id: "sub_dgap_create")
            let (logger, sink) = makeLogger()
            let db = DiagnosticsGapDatabase(base: app.db) {
                $0.schema == APISubmissionDiagnostics.schema && Self.isCreate($0)
            }

            await app.diagnostics.recordSubmissionCreated(submission: submission, on: db, logger: logger)

            let warning = try #require(sink.single(message: "diagnostics_submission_create_failed"))
            #expect(warning.level == .warning)
            #expect(Set(warning.metadata.keys) == ["submission_id", "error"])
            #expect(warning.metadata["submission_id"] == "sub_dgap_create")
            #expect(!sink.anyValueContains(userID.uuidString))
            #expect(sink.events.isEmpty)
            #expect(try await APISubmissionDiagnostics.find("sub_dgap_create", on: app.db) == nil)
        }
    }

    @Test func aFailedRunnerSnapshotLogsTheRunnerAndTheReason() async throws {
        try await withApp(app) { _ in
            let (logger, sink) = makeLogger()
            let db = DiagnosticsGapDatabase(base: app.db) {
                $0.schema == RunnerSnapshot.schema && Self.isCreate($0)
            }
            let snapshot = WorkerActivitySnapshot(
                workerID: "runner-dgap", lastActive: Date(), hostname: "host-dgap", runnerVersion: "runner/1.0",
                maxConcurrentJobs: 4, activeJobs: 1, lastPollAt: Date(), lastHeartbeatAt: nil,
                serverAssignedJobCountSinceStart: 0)

            await app.diagnostics.recordRunnerCheckIn(snapshot: snapshot, reason: .poll, on: db, logger: logger)

            let warning = try #require(sink.single(message: "diagnostics_runner_snapshot_failed"))
            #expect(Set(warning.metadata.keys) == ["runner_id", "reason", "error"])
            #expect(warning.metadata["runner_id"] == "runner-dgap")
            #expect(warning.metadata["reason"] == "poll")
            // The check-in line is not logged for a check-in that failed.
            #expect(sink.events.isEmpty)
            #expect(try await RunnerSnapshot.query(on: app.db).filter(\.$runnerID == "runner-dgap").count() == 0)
        }
    }

    @Test func aFailedJobAssignmentLogsOneRedactedWarning() async throws {
        try await withApp(app) { _ in
            let (submission, userID) = try await makeStudentSubmission(id: "sub_dgap_assign")
            submission.workerID = "runner-dgap-assign"
            submission.assignedAt = Date()
            submission.status = SubmissionStatus.assigned.rawValue
            try await submission.update(on: app.db)
            let (logger, sink) = makeLogger()
            let db = DiagnosticsGapDatabase(base: app.db) {
                $0.schema == APISubmissionDiagnostics.schema && Self.isCreate($0)
            }

            await app.diagnostics.recordJobAssigned(submission: submission, on: db, logger: logger)

            let warning = try #require(sink.single(message: "diagnostics_job_assign_failed"))
            #expect(Set(warning.metadata.keys) == ["submission_id", "error"])
            #expect(warning.metadata["submission_id"] == "sub_dgap_assign")
            #expect(!sink.anyValueContains(userID.uuidString))
            #expect(sink.events.isEmpty)
        }
    }

    @Test func aReportForAnUnknownSubmissionWritesNothing() async throws {
        try await withApp(app) { _ in
            let (logger, sink) = makeLogger()

            await app.diagnostics.recordWorkerExecutionReport(
                collection: collection(submissionID: "sub_dgap_ghost", setupID: "setup_dgap_ghost"),
                diagnostics: nil, on: app.db, logger: logger)

            let warning = try #require(sink.single(message: "diagnostics_missing_submission"))
            #expect(warning.metadata == ["submission_id": "sub_dgap_ghost"])
            #expect(sink.events.isEmpty)
            #expect(try await APISubmissionDiagnostics.find("sub_dgap_ghost", on: app.db) == nil)
            #expect(
                try await JobExecutionMetric.query(on: app.db).filter(\.$submissionID == "sub_dgap_ghost").count()
                    == 0)
        }
    }

    @Test func aFailedExecutionReportLogsOneRedactedWarning() async throws {
        try await withApp(app) { _ in
            let (submission, userID) = try await makeStudentSubmission(id: "sub_dgap_finish")
            let (logger, sink) = makeLogger()
            let db = DiagnosticsGapDatabase(base: app.db) {
                $0.schema == APISubmissionDiagnostics.schema && Self.isCreate($0)
            }

            await app.diagnostics.recordWorkerExecutionReport(
                collection: collection(submissionID: "sub_dgap_finish", setupID: submission.testSetupID),
                diagnostics: nil, submission: submission, on: db, logger: logger)

            let warning = try #require(sink.single(message: "diagnostics_job_finish_failed"))
            #expect(Set(warning.metadata.keys) == ["submission_id", "error"])
            #expect(warning.metadata["submission_id"] == "sub_dgap_finish")
            #expect(!sink.anyValueContains(userID.uuidString))
            #expect(sink.events.isEmpty)
            #expect(
                try await JobExecutionMetric.query(on: app.db).filter(\.$submissionID == "sub_dgap_finish").count()
                    == 0)
        }
    }

    // MARK: - Queries

    /// A store that is not SQL takes the per-row fallback. It must count what
    /// the grouped SQL count does: validations on any setup, student work
    /// only on a worker-graded setup.
    @Test func theFallbackPendingCountMatchesTheSQLCount() async throws {
        try await withApp(app) { _ in
            let worker = try await makeSetup(id: "setup_dgap_worker", gradingMode: "worker")
            let browser = try await makeSetup(id: "setup_dgap_browser", gradingMode: "browser")
            try await makeRow(id: "sub_dgap_w1", setup: worker, status: "pending")
            try await makeRow(id: "sub_dgap_w2", setup: worker, status: "pending")
            try await makeRow(id: "sub_dgap_b1", setup: browser, status: "pending")
            try await makeRow(
                id: "sub_dgap_v1", setup: browser, status: "pending", kind: APISubmission.Kind.validation)
            try await makeRow(
                id: "sub_dgap_s1", setup: worker, status: "pending", kind: APISubmission.Kind.starterValidation)
            try await makeRow(id: "sub_dgap_done", setup: worker, status: "complete")

            let plain = DiagnosticsGapDatabase(base: app.db) { _ in false }
            let sqlDepth = try await app.diagnostics.pendingQueueDepth(on: app.db)
            #expect(sqlDepth == 4)
            #expect(try await app.diagnostics.pendingQueueDepth(on: plain) == sqlDepth)
        }
    }

    /// Jobs submitted before the window opened and not assigned until after
    /// it are the depth the window opens at; a submission and an assignment
    /// at one instant put the +1 first, so the peak counts both.
    @Test func theTimelineOpensAtTheWaitingDepthAndPutsArrivalsFirst() async throws {
        try await withApp(app) { _ in
            let worker = try await makeSetup(id: "setup_dgap_timeline", gradingMode: "worker")
            let windowStart = Date(timeIntervalSince1970: 1_800_000_000)
            let tick = windowStart.addingTimeInterval(10)
            let now = windowStart.addingTimeInterval(100)
            try await makeRow(
                id: "sub_dgap_waiting", setup: worker, status: "pending",
                submittedAt: windowStart.addingTimeInterval(-100))
            try await makeRow(
                id: "sub_dgap_late", setup: worker, status: "assigned",
                submittedAt: windowStart.addingTimeInterval(-50), assignedAt: tick)
            try await makeRow(id: "sub_dgap_tie", setup: worker, status: "pending", submittedAt: tick)
            try await makeRow(
                id: "sub_dgap_old", setup: worker, status: "complete",
                submittedAt: windowStart.addingTimeInterval(-200), assignedAt: windowStart.addingTimeInterval(-150))

            let timeline = try await app.diagnostics.queueDepthTimeline(windowStart: windowStart, now: now, on: app.db)
            #expect(timeline.initialDepth == 2)
            #expect(timeline.events == [QueueDepthEvent(date: tick, delta: 1), QueueDepthEvent(date: tick, delta: -1)])
            #expect(try await app.diagnostics.maxQueueDepthSince(windowStart: windowStart, now: now, on: app.db) == 3)
        }
    }

    @Test func aTestClassPrefixesTheTestID() async throws {
        try await withApp(app) { _ in
            let service = app.diagnostics
            #expect(service.normalizedTestID(for: outcome(name: "case", testClass: "  Suite \n")) == "Suite.case")
            #expect(service.normalizedTestID(for: outcome(name: "case", testClass: "   ")) == "case")
            #expect(service.normalizedTestID(for: outcome(name: "case", testClass: nil)) == "case")
        }
    }

    /// A prune that fails stops, keeps the rows it had not reached, and
    /// logs a warning in place of the completion line.
    @Test func aFailedPruneLogsAWarningAndKeepsTheRows() async throws {
        try await withApp(app) { _ in
            let old = Date(timeIntervalSince1970: 1_000_000)
            try await RunnerSnapshot(
                runnerID: "runner-dgap-prune", recordedAt: old, activeJobs: 0, maxJobs: 1, availableCapacity: 1,
                hostname: nil, runnerVersion: nil, lastPollAt: nil, lastHeartbeatAt: nil,
                serverAssignedJobCountSinceStart: 0
            ).save(on: app.db)
            let (logger, sink) = makeLogger()
            let db = DiagnosticsGapDatabase(base: app.db) {
                if case .delete = $0.action { return $0.schema == JobExecutionMetric.schema }
                return false
            }

            await app.diagnostics.performPrune(on: db, logger: logger, now: Date())

            let warning = try #require(sink.single(message: "observability_prune_failed"))
            #expect(warning.level == .warning)
            #expect(Set(warning.metadata.keys) == ["error"])
            #expect(sink.single(message: "observability_prune_complete") == nil)
            #expect(
                try await RunnerSnapshot.query(on: app.db).filter(\.$runnerID == "runner-dgap-prune").count() == 1)
        }
    }

    // MARK: - Fixtures

    private static func isCreate(_ query: DatabaseQuery) -> Bool {
        if case .create = query.action { return true }
        return false
    }

    private func makeLogger() -> (Logger, DiagnosticsGapLogSink) {
        let sink = DiagnosticsGapLogSink()
        var logger = Logger(label: "diagnostics-recording-gap.test")
        logger.handler = DiagnosticsGapLogHandler(sink: sink)
        return (logger, sink)
    }

    private func makeSetup(id: String, gradingMode: String) async throws -> APITestSetup {
        let course = APICourse(code: "DG_\(id)", name: "Diagnostics gaps", enrollmentMode: .closed)
        try await course.save(on: app.db)
        let manifest =
            #"{"schemaVersion":1,"gradingMode":"\#(gradingMode)","requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}"#
        return try await makeTestSetup(
            on: app, id: id, courseID: try course.requireID(), manifest: manifest,
            withNotebook: false, withZip: false)
    }

    private func makeStudentSubmission(id: String) async throws -> (APISubmission, UUID) {
        let setup = try await makeSetup(id: "setup_\(id)", gradingMode: "worker")
        let user = try await makeTestUser(on: app, username: "dgap_\(id)")
        let userID = try user.requireID()
        let submission = APISubmission(
            id: id, testSetupID: try setup.requireID(), zipPath: "/tmp/\(id).zip", attemptNumber: 1,
            status: "pending", userID: userID, kind: APISubmission.Kind.student)
        try await submission.save(on: app.db)
        return (submission, userID)
    }

    @discardableResult
    private func makeRow(
        id: String, setup: APITestSetup, status: String, kind: String = APISubmission.Kind.student,
        submittedAt: Date? = nil, assignedAt: Date? = nil
    ) async throws -> APISubmission {
        let submission = APISubmission(
            id: id, testSetupID: try setup.requireID(), zipPath: "/tmp/\(id).zip", attemptNumber: 1,
            status: status, kind: kind)
        try await submission.save(on: app.db)
        if submittedAt != nil || assignedAt != nil {
            submission.submittedAt = submittedAt
            submission.assignedAt = assignedAt
            try await submission.update(on: app.db)
        }
        return submission
    }

    private func outcome(name: String, testClass: String?) -> TestOutcome {
        TestOutcome(
            testName: name, testClass: testClass, tier: .pub, status: .pass, shortResult: "passed",
            longResult: nil, executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1,
            isFirstPassSuccess: false)
    }

    private func collection(submissionID: String, setupID: String) -> TestOutcomeCollection {
        TestOutcomeCollection(
            submissionID: submissionID, testSetupID: setupID, attemptNumber: 1, buildStatus: .passed,
            compilerOutput: nil, outcomes: [], totalTests: 0, passCount: 0, failCount: 0, errorCount: 0,
            timeoutCount: 0, executionTimeMs: 10, jobStartedAt: Date(timeIntervalSince1970: 1_800_000_000),
            runnerVersion: "runner-test/1.0", timestamp: Date(timeIntervalSince1970: 1_800_000_001))
    }
}

// MARK: - A store that is not SQL and can refuse queries

/// Forwards every query to `base`, except those `refuse` names, which fail.
/// It does not conform to `SQLDatabase`, so code under test takes its
/// store-agnostic path.
private struct DiagnosticsGapDatabase: Database {
    struct Refused: Error {}

    let base: any Database
    let refuse: @Sendable (DatabaseQuery) -> Bool

    init(base: any Database, refuse: @escaping @Sendable (DatabaseQuery) -> Bool) {
        self.base = base
        self.refuse = refuse
    }

    var context: DatabaseContext { base.context }
    var inTransaction: Bool { base.inTransaction }

    func execute(
        query: DatabaseQuery, onOutput: @escaping @Sendable (any DatabaseOutput) -> Void
    ) -> EventLoopFuture<Void> {
        if refuse(query) { return base.eventLoop.makeFailedFuture(Refused()) }
        return base.execute(query: query, onOutput: onOutput)
    }

    func execute(schema: DatabaseSchema) -> EventLoopFuture<Void> { base.execute(schema: schema) }

    func execute(enum: DatabaseEnum) -> EventLoopFuture<Void> { base.execute(enum: `enum`) }

    func transaction<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        base.transaction(closure)
    }

    func withConnection<T>(_ closure: @escaping @Sendable (any Database) -> EventLoopFuture<T>) -> EventLoopFuture<T> {
        base.withConnection(closure)
    }
}

// MARK: - Capturing log handler

private struct DiagnosticsGapLogRecord: Sendable {
    let level: Logger.Level
    let message: String
    let metadata: [String: String]
}

private final class DiagnosticsGapLogSink: Sendable {
    private let stored = Mutex<[DiagnosticsGapLogRecord]>([])

    func append(_ record: DiagnosticsGapLogRecord) {
        stored.withLock { $0.append(record) }
    }

    /// The one record with `message`, or nil when there is none or more than one.
    func single(message: String) -> DiagnosticsGapLogRecord? {
        let matches = stored.withLock { $0.filter { $0.message == message } }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The structured `observability` lines.
    var events: [DiagnosticsGapLogRecord] {
        stored.withLock { $0.filter { $0.message == "observability" } }
    }

    func anyValueContains(_ text: String) -> Bool {
        stored.withLock { records in
            records.contains { $0.metadata.values.contains { $0.contains(text) } }
        }
    }
}

private struct DiagnosticsGapLogHandler: LogHandler {
    let sink: DiagnosticsGapLogSink

    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let merged = metadata.merging(event.metadata ?? [:]) { _, new in new }
        sink.append(
            DiagnosticsGapLogRecord(
                level: event.level, message: event.message.description, metadata: merged.mapValues { "\($0)" }))
    }
}
