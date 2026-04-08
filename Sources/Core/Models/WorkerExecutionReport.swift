import Foundation

public struct WorkerExecutionStageTimings: Codable, Sendable, Equatable {
    public let workdirSetupMs: Int?
    public let submissionDirSetupMs: Int?
    public let submissionDownloadMs: Int?
    public let testSetupAcquireMs: Int?
    public let submissionUnpackMs: Int?
    public let starterCleanupMs: Int?
    public let submissionPrepareMs: Int?
    public let makeStepMs: Int?
    public let runtimeHelperSetupMs: Int?
    public let testExecutionMs: Int?

    public init(
        workdirSetupMs: Int? = nil,
        submissionDirSetupMs: Int? = nil,
        submissionDownloadMs: Int? = nil,
        testSetupAcquireMs: Int? = nil,
        submissionUnpackMs: Int? = nil,
        starterCleanupMs: Int? = nil,
        submissionPrepareMs: Int? = nil,
        makeStepMs: Int? = nil,
        runtimeHelperSetupMs: Int? = nil,
        testExecutionMs: Int? = nil
    ) {
        self.workdirSetupMs = workdirSetupMs
        self.submissionDirSetupMs = submissionDirSetupMs
        self.submissionDownloadMs = submissionDownloadMs
        self.testSetupAcquireMs = testSetupAcquireMs
        self.submissionUnpackMs = submissionUnpackMs
        self.starterCleanupMs = starterCleanupMs
        self.submissionPrepareMs = submissionPrepareMs
        self.makeStepMs = makeStepMs
        self.runtimeHelperSetupMs = runtimeHelperSetupMs
        self.testExecutionMs = testExecutionMs
    }
}

/// Diagnostics emitted by a native worker for one job execution.
///
/// These fields are best-effort: platforms or runner modes that cannot collect
/// a metric should leave it nil instead of failing the job.
public struct WorkerExecutionDiagnostics: Codable, Sendable {
    public let runnerID: String
    public let startedAt: Date?
    public let finishedAt: Date?
    public let finalStatus: String
    public let timedOut: Bool
    public let exitCode: Int?
    public let terminationReason: String?
    public let peakRSSBytes: Int?
    public let wallClockMs: Int?
    public let childProcessCount: Int?
    public let stdoutBytes: Int?
    public let stderrBytes: Int?
    public let stageTimings: WorkerExecutionStageTimings?

    public init(
        runnerID: String,
        startedAt: Date?,
        finishedAt: Date?,
        finalStatus: String,
        timedOut: Bool,
        exitCode: Int?,
        terminationReason: String?,
        peakRSSBytes: Int?,
        wallClockMs: Int?,
        childProcessCount: Int?,
        stdoutBytes: Int?,
        stderrBytes: Int?,
        stageTimings: WorkerExecutionStageTimings? = nil
    ) {
        self.runnerID = runnerID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.finalStatus = finalStatus
        self.timedOut = timedOut
        self.exitCode = exitCode
        self.terminationReason = terminationReason
        self.peakRSSBytes = peakRSSBytes
        self.wallClockMs = wallClockMs
        self.childProcessCount = childProcessCount
        self.stdoutBytes = stdoutBytes
        self.stderrBytes = stderrBytes
        self.stageTimings = stageTimings
    }
}

/// Wrapped worker result payload sent to `/api/v1/worker/results`.
///
/// The server still accepts legacy bare `TestOutcomeCollection` payloads so
/// mixed-version deploys remain safe while runners roll forward.
public struct WorkerExecutionReport: Codable, Sendable {
    public let collection: TestOutcomeCollection
    public let diagnostics: WorkerExecutionDiagnostics?

    public init(collection: TestOutcomeCollection, diagnostics: WorkerExecutionDiagnostics?) {
        self.collection = collection
        self.diagnostics = diagnostics
    }
}
