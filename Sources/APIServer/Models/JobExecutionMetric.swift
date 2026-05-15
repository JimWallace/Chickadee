import Fluent
import Vapor

final class JobExecutionMetric: Model, Content, @unchecked Sendable {
    static let schema = "job_execution_metrics"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "submission_id")
    var submissionID: String

    @Field(key: "job_id")
    var jobID: String

    @Field(key: "test_setup_id")
    var testSetupID: String

    @OptionalField(key: "course_id")
    var courseID: UUID?

    @OptionalField(key: "assignment_id")
    var assignmentID: UUID?

    @OptionalField(key: "user_id")
    var userID: UUID?

    @OptionalField(key: "runner_id")
    var runnerID: String?

    @Field(key: "kind")
    var kind: String

    @OptionalField(key: "attempt_number")
    var attemptNumber: Int?

    @OptionalField(key: "enqueued_at")
    var enqueuedAt: Date?

    @OptionalField(key: "assigned_at")
    var assignedAt: Date?

    @OptionalField(key: "started_at")
    var startedAt: Date?

    @OptionalField(key: "completed_at")
    var completedAt: Date?

    @OptionalField(key: "queue_wait_ms")
    var queueWaitMs: Int?

    @OptionalField(key: "execution_ms")
    var executionMs: Int?

    @OptionalField(key: "total_processing_ms")
    var totalProcessingMs: Int?

    @OptionalField(key: "workdir_setup_ms")
    var workdirSetupMs: Int?

    @OptionalField(key: "submission_dir_setup_ms")
    var submissionDirSetupMs: Int?

    @OptionalField(key: "submission_download_ms")
    var submissionDownloadMs: Int?

    @OptionalField(key: "test_setup_acquire_ms")
    var testSetupAcquireMs: Int?

    @OptionalField(key: "submission_unpack_ms")
    var submissionUnpackMs: Int?

    @OptionalField(key: "starter_cleanup_ms")
    var starterCleanupMs: Int?

    @OptionalField(key: "submission_prepare_ms")
    var submissionPrepareMs: Int?

    @OptionalField(key: "make_step_ms")
    var makeStepMs: Int?

    @OptionalField(key: "runtime_helper_setup_ms")
    var runtimeHelperSetupMs: Int?

    @OptionalField(key: "test_execution_ms")
    var testExecutionMs: Int?

    /// Whether the runner-side TestSetupCache hit (true) for this job's
    /// test setup, or had to populate from a fresh download (false).
    /// Nil for jobs reported by runners that predate this field.
    @OptionalField(key: "test_setup_cache_hit")
    var testSetupCacheHit: Bool?

    @OptionalField(key: "final_status")
    var finalStatus: String?

    @OptionalField(key: "tests_passed")
    var testsPassed: Int?

    @OptionalField(key: "tests_failed")
    var testsFailed: Int?

    @OptionalField(key: "tests_errored")
    var testsErrored: Int?

    @OptionalField(key: "tests_timed_out")
    var testsTimedOut: Int?

    @OptionalField(key: "skipped_count")
    var skippedCount: Int?

    /// Free disk (MB) at the temp filesystem just before this job staged.
    @OptionalField(key: "free_disk_mb_at_start")
    var freeDiskMBAtStart: Int?

    /// Free disk (MB) at end of execution, before workDir cleanup —
    /// worst-case free-space reading for this job.
    @OptionalField(key: "free_disk_mb_at_end")
    var freeDiskMBAtEnd: Int?

    /// Size (bytes) of the per-job workDir at end of execution. Proxy for
    /// peak working-set on disk.
    @OptionalField(key: "workdir_peak_bytes")
    var workdirPeakBytes: Int?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        submissionID: String,
        jobID: String,
        testSetupID: String,
        courseID: UUID?,
        assignmentID: UUID?,
        userID: UUID?,
        runnerID: String?,
        kind: String,
        attemptNumber: Int?,
        enqueuedAt: Date?
    ) {
        self.submissionID = submissionID
        self.jobID = jobID
        self.testSetupID = testSetupID
        self.courseID = courseID
        self.assignmentID = assignmentID
        self.userID = userID
        self.runnerID = runnerID
        self.kind = kind
        self.attemptNumber = attemptNumber
        self.enqueuedAt = enqueuedAt
    }
}
