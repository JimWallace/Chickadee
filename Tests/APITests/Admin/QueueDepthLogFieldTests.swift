import Fluent
import Foundation
import Logging
import Synchronization
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

/// The `queue_depth` log field goes through `queueDepthForLog(on:)`, which
/// may reuse a recent count while the backlog is large. These pin that it
/// reports what `pendingQueueDepth(on:)` reports below that size, and that
/// the exact depth (`GetQueueStateTool`) never reads the reused count.
@Suite(.serialized) final class QueueDepthLogFieldTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-qdepth-log")
    }

    /// A small queue costs under a millisecond to count, so each event counts
    /// again and the log moves with the queue. The rules are those of the
    /// exact depth: validations count on any setup, browser-graded student
    /// work does not, and a manifest that does not decode counts as
    /// worker-graded.
    @Test func aSmallQueueIsCountedAgainForEveryEvent() async throws {
        try await withApp(app) { _ in
            let worker = try await makeSetup(id: "setup_qdepth_worker", manifest: manifest(gradingMode: "worker"))
            let browser = try await makeSetup(id: "setup_qdepth_browser", manifest: manifest(gradingMode: "browser"))
            let undecodable = try await makeSetup(id: "setup_qdepth_undecodable", manifest: "{not json")

            try await makePending(id: "sub_qdepth_w1", setup: worker, kind: APISubmission.Kind.student)
            try await makePending(id: "sub_qdepth_b1", setup: browser, kind: APISubmission.Kind.student)
            try await makePending(id: "sub_qdepth_v1", setup: browser, kind: APISubmission.Kind.validation)
            try await makePending(id: "sub_qdepth_u1", setup: undecodable, kind: APISubmission.Kind.student)

            #expect(try await app.diagnostics.queueDepthForLog(on: app.db) == 3)
            #expect(try await app.diagnostics.pendingQueueDepth(on: app.db) == 3)

            try await makePending(id: "sub_qdepth_w2", setup: worker, kind: APISubmission.Kind.student)

            #expect(try await app.diagnostics.queueDepthForLog(on: app.db) == 4)
            #expect(try await app.diagnostics.pendingQueueDepth(on: app.db) == 4)
        }
    }

    /// A large count from the last few seconds is logged again; the exact
    /// depth still counts.
    @Test func aLargeRecentCountReachesTheLogButNotTheExactDepth() async throws {
        try await withApp(app) { _ in
            let worker = try await makeSetup(id: "setup_qdepth_large", manifest: manifest(gradingMode: "worker"))
            try await makePending(id: "sub_qdepth_large", setup: worker, kind: APISubmission.Kind.student)

            await app.diagnostics.queueDepthLogSampler.record(
                depth: 25_000, countedRows: QueueDepthLogSampleStore.minimumCountedRows, takenAt: .now)

            #expect(try await app.diagnostics.queueDepthForLog(on: app.db) == 25_000)
            #expect(try await app.diagnostics.pendingQueueDepth(on: app.db) == 1)
        }
    }

    /// The field on the `job_enqueued` line is the log-path depth: exact for
    /// a small queue, the recent count once a large one is recorded.
    @Test func theJobEnqueuedLineCarriesTheLogPathDepth() async throws {
        try await withApp(app) { _ in
            let worker = try await makeSetup(id: "setup_qdepth_line", manifest: manifest(gradingMode: "worker"))
            let first = try await makePending(id: "sub_qdepth_line1", setup: worker, kind: APISubmission.Kind.student)

            let sink = QueueDepthRecordSink()
            var logger = Logger(label: "queue-depth-log-field.test")
            logger.handler = QueueDepthCapturingLogHandler(sink: sink)

            await app.diagnostics.recordSubmissionCreated(submission: first, on: app.db, logger: logger)
            #expect(sink.queueDepths(event: "job_enqueued") == ["1"])

            await app.diagnostics.queueDepthLogSampler.record(
                depth: 25_000, countedRows: QueueDepthLogSampleStore.minimumCountedRows, takenAt: .now)
            let second = try await makePending(id: "sub_qdepth_line2", setup: worker, kind: APISubmission.Kind.student)

            await app.diagnostics.recordSubmissionCreated(submission: second, on: app.db, logger: logger)
            #expect(sink.queueDepths(event: "job_enqueued") == ["1", "25000"])
        }
    }

    private func manifest(gradingMode: String) -> String {
        #"{"schemaVersion":1,"gradingMode":"\#(gradingMode)","requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}"#
    }

    private func makeSetup(id: String, manifest: String) async throws -> APITestSetup {
        let course = APICourse(code: "QD_\(id)", name: "Queue depth", enrollmentMode: .closed)
        try await course.save(on: app.db)
        return try await makeTestSetup(
            on: app, id: id, courseID: try course.requireID(), manifest: manifest,
            withNotebook: false, withZip: false)
    }

    @discardableResult
    private func makePending(id: String, setup: APITestSetup, kind: String) async throws -> APISubmission {
        let submission = APISubmission(
            id: id,
            testSetupID: try setup.requireID(),
            zipPath: "/tmp/\(id).zip",
            attemptNumber: 1,
            status: "pending",
            kind: kind
        )
        try await submission.save(on: app.db)
        return submission
    }
}

// MARK: - Capturing log handler

private final class QueueDepthRecordSink: Sendable {
    // A LogHandler is a value type copied into the Logger, so the shared
    // store has to sit behind a reference the handler captures.
    private let stored = Mutex<[[String: String]]>([])

    func append(_ metadata: Logger.Metadata) {
        let record = metadata.mapValues { "\($0)" }
        stored.withLock { $0.append(record) }
    }

    func queueDepths(event: String) -> [String] {
        stored.withLock { records in
            records.filter { $0["event"] == event }.compactMap { $0["queue_depth"] }
        }
    }
}

private struct QueueDepthCapturingLogHandler: LogHandler {
    let sink: QueueDepthRecordSink

    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        sink.append(event.metadata ?? [:])
    }
}
