import Fluent
import Vapor

final class RunnerSnapshot: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "runner_snapshots"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "runner_id")
    var runnerID: String

    @Field(key: "recorded_at")
    var recordedAt: Date

    @Field(key: "active_jobs")
    var activeJobs: Int

    @Field(key: "max_jobs")
    var maxJobs: Int

    @Field(key: "available_capacity")
    var availableCapacity: Int

    @OptionalField(key: "hostname")
    var hostname: String?

    @OptionalField(key: "runner_version")
    var runnerVersion: String?

    @OptionalField(key: "last_poll_at")
    var lastPollAt: Date?

    @OptionalField(key: "last_heartbeat_at")
    var lastHeartbeatAt: Date?

    @OptionalField(key: "server_assigned_job_count_since_start")
    var serverAssignedJobCountSinceStart: Int?

    init() {}

    init(
        runnerID: String,
        recordedAt: Date,
        activeJobs: Int,
        maxJobs: Int,
        availableCapacity: Int,
        hostname: String?,
        runnerVersion: String?,
        lastPollAt: Date?,
        lastHeartbeatAt: Date?,
        serverAssignedJobCountSinceStart: Int?
    ) {
        self.runnerID = runnerID
        self.recordedAt = recordedAt
        self.activeJobs = activeJobs
        self.maxJobs = maxJobs
        self.availableCapacity = availableCapacity
        self.hostname = hostname
        self.runnerVersion = runnerVersion
        self.lastPollAt = lastPollAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.serverAssignedJobCountSinceStart = serverAssignedJobCountSinceStart
    }
}
