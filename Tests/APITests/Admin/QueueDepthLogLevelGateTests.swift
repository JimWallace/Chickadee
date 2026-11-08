import Fluent
import Foundation
import Logging
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

/// Only info lines carry `queue_depth`, so a logger that drops them needs no
/// count. A logger that writes them still gets the exact depth.
@Suite(.serialized) final class QueueDepthLogLevelGateTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-qdepth-level")
    }

    @Test(arguments: [Logger.Level.notice, .warning, .error, .critical])
    func aLoggerAboveInfoSkipsTheCount(level: Logger.Level) async throws {
        try await withApp(app) { _ in
            try await makePendingWorkerSubmission(suffix: "skip_\(level.rawValue)")

            #expect(try await app.diagnostics.queueDepthForLog(on: app.db, logger: logger(at: level)) == nil)
        }
    }

    @Test(arguments: [Logger.Level.trace, .debug, .info])
    func aLoggerThatWritesInfoGetsTheDepth(level: Logger.Level) async throws {
        try await withApp(app) { _ in
            try await makePendingWorkerSubmission(suffix: "count_\(level.rawValue)")

            #expect(try await app.diagnostics.queueDepthForLog(on: app.db, logger: logger(at: level)) == 1)
        }
    }

    private func logger(at level: Logger.Level) -> Logger {
        var logger = Logger(label: "queue-depth-level.test")
        logger.logLevel = level
        return logger
    }

    private func makePendingWorkerSubmission(suffix: String) async throws {
        let course = APICourse(code: "QDL_\(suffix)", name: "Queue depth level", enrollmentMode: .closed)
        try await course.save(on: app.db)
        let setup = try await makeTestSetup(
            on: app, id: "setup_qdl_\(suffix)", courseID: try course.requireID(),
            manifest:
                #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}"#,
            withNotebook: false, withZip: false)
        let submission = APISubmission(
            id: "sub_qdl_\(suffix)",
            testSetupID: try setup.requireID(),
            zipPath: "/tmp/sub_qdl_\(suffix).zip",
            attemptNumber: 1,
            status: "pending",
            kind: APISubmission.Kind.student
        )
        try await submission.save(on: app.db)
    }
}
