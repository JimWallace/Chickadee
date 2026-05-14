import Fluent
import Vapor

final class APISubmissionDiagnostics: Model, Content, @unchecked Sendable {
    static let schema = "submission_diagnostics"

    @ID(custom: "submission_id", generatedBy: .user)
    var id: String?

    @Field(key: "test_setup_id")
    var testSetupID: String

    @OptionalField(key: "course_id")
    var courseID: UUID?

    @OptionalField(key: "assignment_id")
    var assignmentID: UUID?

    @Field(key: "kind")
    var kind: String

    @OptionalField(key: "submitted_at")
    var submittedAt: Date?

    @OptionalField(key: "assigned_at")
    var assignedAt: Date?

    @OptionalField(key: "started_at")
    var startedAt: Date?

    @OptionalField(key: "finished_at")
    var finishedAt: Date?

    @OptionalField(key: "queue_wait_ms")
    var queueWaitMs: Int?

    @OptionalField(key: "execution_ms")
    var executionMs: Int?

    @OptionalField(key: "turnaround_ms")
    var turnaroundMs: Int?

    @OptionalField(key: "final_status")
    var finalStatus: String?

    @OptionalField(key: "runner_id")
    var runnerID: String?

    @OptionalField(key: "timed_out")
    var timedOut: Bool?

    @OptionalField(key: "exit_code")
    var exitCode: Int?

    @OptionalField(key: "termination_reason")
    var terminationReason: String?

    @OptionalField(key: "peak_rss_bytes")
    var peakRSSBytes: Int?

    @OptionalField(key: "wall_clock_ms")
    var wallClockMs: Int?

    @OptionalField(key: "child_process_count")
    var childProcessCount: Int?

    @OptionalField(key: "stdout_bytes")
    var stdoutBytes: Int?

    @OptionalField(key: "stderr_bytes")
    var stderrBytes: Int?

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
        testSetupID: String,
        courseID: UUID?,
        assignmentID: UUID?,
        kind: String,
        submittedAt: Date?
    ) {
        self.id = submissionID
        self.testSetupID = testSetupID
        self.courseID = courseID
        self.assignmentID = assignmentID
        self.kind = kind
        self.submittedAt = submittedAt
    }
}
