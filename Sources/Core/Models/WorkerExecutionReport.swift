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
    /// Whether the runner-side `TestSetupCache` hit (true) or had to populate
    /// from a fresh download (false) when staging this job's test setup.
    /// Nil when older runners that predate this field report results.
    public let testSetupCacheHit: Bool?

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
        testExecutionMs: Int? = nil,
        testSetupCacheHit: Bool? = nil
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
        self.testSetupCacheHit = testSetupCacheHit
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
    /// Free space on the runner's temp filesystem at the moment the job
    /// was accepted, before any download or unpack happened. Compare with
    /// `freeDiskMBAtEnd` to see net disk consumed by the job (with other
    /// concurrent jobs as confounders).
    public let freeDiskMBAtStart: Int?
    /// Free space measured after `workDir` was removed in cleanup. Useful
    /// for detecting cache growth and persistent leftovers.
    public let freeDiskMBAtEnd: Int?
    /// Size of the per-job `workDir` (bytes) measured just before cleanup
    /// — a usable proxy for the job's peak working-set on disk, since
    /// `workDir` accumulates downloads + unpacks monotonically.
    public let workdirPeakBytes: Int?

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
        stageTimings: WorkerExecutionStageTimings? = nil,
        freeDiskMBAtStart: Int? = nil,
        freeDiskMBAtEnd: Int? = nil,
        workdirPeakBytes: Int? = nil
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
        self.freeDiskMBAtStart = freeDiskMBAtStart
        self.freeDiskMBAtEnd = freeDiskMBAtEnd
        self.workdirPeakBytes = workdirPeakBytes
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
