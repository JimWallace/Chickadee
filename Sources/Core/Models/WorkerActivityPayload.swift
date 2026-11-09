import Foundation

public struct WorkerActivityPayload: Codable, Sendable {
    public let workerID: String
    public let hostname: String
    public let runnerVersion: String
    public let maxConcurrentJobs: Int
    public let activeJobs: Int
    public let profile: RunnerCapabilityProfile?
    /// How long the runner asks the server to hold this poll open when no job
    /// is claimable (`WorkerLongPoll`). Nil, from a heartbeat or an older
    /// runner, asks for an immediate answer. An older server ignores the key.
    public let longPollSeconds: Int?

    public init(
        workerID: String,
        hostname: String,
        runnerVersion: String,
        maxConcurrentJobs: Int,
        activeJobs: Int,
        profile: RunnerCapabilityProfile? = nil,
        longPollSeconds: Int? = nil
    ) {
        self.workerID = workerID
        self.hostname = hostname
        self.runnerVersion = runnerVersion
        self.maxConcurrentJobs = maxConcurrentJobs
        self.activeJobs = activeJobs
        self.profile = profile
        self.longPollSeconds = longPollSeconds
    }
}
