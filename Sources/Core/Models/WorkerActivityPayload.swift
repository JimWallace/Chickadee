import Foundation

public struct WorkerActivityPayload: Codable, Sendable {
    public let workerID: String
    public let hostname: String
    public let runnerVersion: String
    public let maxConcurrentJobs: Int
    public let activeJobs: Int
    public let profile: RunnerCapabilityProfile?

    public init(
        workerID: String,
        hostname: String,
        runnerVersion: String,
        maxConcurrentJobs: Int,
        activeJobs: Int,
        profile: RunnerCapabilityProfile? = nil
    ) {
        self.workerID = workerID
        self.hostname = hostname
        self.runnerVersion = runnerVersion
        self.maxConcurrentJobs = maxConcurrentJobs
        self.activeJobs = activeJobs
        self.profile = profile
    }
}
