import Core
import Foundation

/// Pure value-type wrapper around `WorkerExecutionStageTimings` that knows how
/// to populate a `JobExecutionMetric` with stage-level timing fields.
///
/// Extracted from `OperationalDiagnosticsService.recordWorkerExecutionReport`
/// so the field-mapping is independently testable. Adding `totalKnownStageMs`
/// surfaces an aggregate the admin runner detail page can consume.
struct StageTimingAggregator: Sendable, Equatable {
    let workdirSetupMs: Int?
    let submissionDirSetupMs: Int?
    let submissionDownloadMs: Int?
    let testSetupAcquireMs: Int?
    let submissionUnpackMs: Int?
    let starterCleanupMs: Int?
    let submissionPrepareMs: Int?
    let makeStepMs: Int?
    let runtimeHelperSetupMs: Int?
    let testExecutionMs: Int?

    init(from timings: WorkerExecutionStageTimings?) {
        self.workdirSetupMs = timings?.workdirSetupMs
        self.submissionDirSetupMs = timings?.submissionDirSetupMs
        self.submissionDownloadMs = timings?.submissionDownloadMs
        self.testSetupAcquireMs = timings?.testSetupAcquireMs
        self.submissionUnpackMs = timings?.submissionUnpackMs
        self.starterCleanupMs = timings?.starterCleanupMs
        self.submissionPrepareMs = timings?.submissionPrepareMs
        self.makeStepMs = timings?.makeStepMs
        self.runtimeHelperSetupMs = timings?.runtimeHelperSetupMs
        self.testExecutionMs = timings?.testExecutionMs
    }

    func apply(to metric: JobExecutionMetric) {
        metric.workdirSetupMs = workdirSetupMs
        metric.submissionDirSetupMs = submissionDirSetupMs
        metric.submissionDownloadMs = submissionDownloadMs
        metric.testSetupAcquireMs = testSetupAcquireMs
        metric.submissionUnpackMs = submissionUnpackMs
        metric.starterCleanupMs = starterCleanupMs
        metric.submissionPrepareMs = submissionPrepareMs
        metric.makeStepMs = makeStepMs
        metric.runtimeHelperSetupMs = runtimeHelperSetupMs
        metric.testExecutionMs = testExecutionMs
    }

    /// Sum of every populated stage timing. `nil` when every stage is `nil`.
    var totalKnownStageMs: Int? {
        let stages: [Int?] = [
            workdirSetupMs,
            submissionDirSetupMs,
            submissionDownloadMs,
            testSetupAcquireMs,
            submissionUnpackMs,
            starterCleanupMs,
            submissionPrepareMs,
            makeStepMs,
            runtimeHelperSetupMs,
            testExecutionMs,
        ]
        let known = stages.compactMap { $0 }
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +)
    }
}
