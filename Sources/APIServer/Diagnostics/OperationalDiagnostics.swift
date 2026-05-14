import Core
import Fluent
import Foundation
import Vapor

enum JobFinalStatus: String, CaseIterable, Codable, Sendable {
    case passed
    case failed
    case error
    case timeout
}

enum RunnerCheckInReason: String, Sendable {
    case poll
    case heartbeat
    case auth
}

enum ObservabilityEvent: String, Sendable {
    case submissionAccepted = "submission_accepted"
    case jobEnqueued = "job_enqueued"
    case runnerPolled = "runner_polled"
    case runnerHeartbeat = "runner_heartbeat"
    case runnerProfileRegistered = "runner_profile_registered"
    case runnerProfileUpdated = "runner_profile_updated"
    case assignmentRequirementsLoaded = "assignment_requirements_loaded"
    case compatibilityCheckPassed = "compatibility_check_passed"
    case compatibilityCheckFailed = "compatibility_check_failed"
    case noCompatibleRunnerAvailable = "no_compatible_runner_available"
    case jobAssignedToCompatibleRunner = "job_assigned_to_compatible_runner"
    case jobAssigned = "job_assigned"
    case resultReceived = "result_received"
    case jobFinalised = "job_finalised"
    case assignmentResultSummary = "assignment_result_summary"
    case testResultSummary = "test_result_summary"
    case jobRecovery = "job_recovery"
}

struct RunnerAverages: Sendable {
    let avgExecutionMs: Int?
    let avgQueueWaitMs: Int?
}

struct DiagnosticsConfiguration: Sendable {
    let enabled: Bool
    let verboseRequestTiming: Bool
    let jobMetricRetentionDays: Int
    let runnerSnapshotRetentionDays: Int
    let activeRunnerWindowSeconds: TimeInterval
    let recentMetricsWindowHours: Int
    let pruneIntervalHours: Int

    static func fromEnvironment() -> Self {
        Self(
            enabled: environmentBool("ENABLE_DIAGNOSTICS_COLLECTION") ?? true,
            verboseRequestTiming: environmentBool("VERBOSE_REQUEST_TIMING") ?? false,
            jobMetricRetentionDays: environmentInt("JOB_METRIC_RETENTION_DAYS") ?? 30,
            runnerSnapshotRetentionDays: environmentInt("RUNNER_SNAPSHOT_RETENTION_DAYS") ?? 14,
            activeRunnerWindowSeconds: TimeInterval(environmentInt("RUNNER_ACTIVE_WINDOW_SECONDS") ?? 120),
            recentMetricsWindowHours: environmentInt("METRICS_RECENT_WINDOW_HOURS") ?? 24,
            pruneIntervalHours: environmentInt("OBSERVABILITY_PRUNE_INTERVAL_HOURS") ?? 24
        )
    }
}

struct InternalMetricsResponse: Content, Sendable {
    let generatedAt: Date
    let maxQueueDepth: Int
    let jobsProcessed24h: Int
    let peakUtilizationPercent: Int?
    let maxLoadActiveJobs: Int?
    let maxLoadCapacity: Int?
    let activeRunners: Int
    let runnerLoads: [RunnerLoadResponse]
    let recentWindowHours: Int
    let jobStatusCounts: [StatusCountResponse]
    let queueWait: DurationSummaryResponse
    let execution: DurationSummaryResponse
    let compatibility: CompatibilityCountersResponse
}

struct InternalMetricsTimeSeriesResponse: Content, Sendable {
    let generatedAt: Date
    let windowHours: Int
    let bucketMinutes: Int
    let buckets: [InternalMetricsBucketResponse]
}

struct InternalMetricsBucketResponse: Content, Sendable {
    let bucketStart: Date
    let avgRunnerUtilizationPercent: Int?
    let maxRunnerUtilizationPercent: Int?
    let avgActiveRunners: Int
    let requestCount: Int
    let requestP95Ms: Int?
    let completedJobs: Int
    let passedCount: Int
    let failedCount: Int
    let errorCount: Int
    let timeoutCount: Int
    let queueWaitP95Ms: Int?
    let executionP95Ms: Int?
}

struct RunnerLoadResponse: Content, Sendable {
    let runnerID: String
    let hostname: String
    let activeJobs: Int
    let maxJobs: Int
    let availableCapacity: Int
    let lastSeenAt: Date
    let lastPollAt: Date?
    let lastHeartbeatAt: Date?
    let assignedJobsSinceStart: Int
}

struct StatusCountResponse: Content, Sendable {
    let status: String
    let count: Int
}

struct DurationSummaryResponse: Content, Sendable {
    let averageMs: Int?
    let p50Ms: Int?
    let p95Ms: Int?
}

struct CompatibilityCountersResponse: Content, Sendable {
    let compatibleAssignmentAttempts: Int
    let incompatibleAssignmentAttempts: Int
    let jobsBlockedNoCompatibleRunner: Int
}

actor DiagnosticsMaintenanceStore {
    private var lastPrunedAt: Date?

    func shouldPrune(now: Date, intervalHours: Int) -> Bool {
        guard intervalHours > 0 else { return false }
        guard let lastPrunedAt else { return true }
        return now.timeIntervalSince(lastPrunedAt) >= Double(intervalHours) * 3600
    }

    func markPruned(at date: Date) {
        lastPrunedAt = date
    }
}

actor CompatibilityCounterStore {
    private var compatibleAssignmentAttempts = 0
    private var incompatibleAssignmentAttempts = 0
    private var jobsBlockedNoCompatibleRunner = 0

    func incrementCompatibleAssignmentAttempts() {
        compatibleAssignmentAttempts += 1
    }

    func incrementIncompatibleAssignmentAttempts() {
        incompatibleAssignmentAttempts += 1
    }

    func incrementJobsBlockedNoCompatibleRunner() {
        jobsBlockedNoCompatibleRunner += 1
    }

    func snapshot() -> CompatibilityCountersResponse {
        CompatibilityCountersResponse(
            compatibleAssignmentAttempts: compatibleAssignmentAttempts,
            incompatibleAssignmentAttempts: incompatibleAssignmentAttempts,
            jobsBlockedNoCompatibleRunner: jobsBlockedNoCompatibleRunner
        )
    }
}

/// Internal context loaded once per submission and threaded through the
/// diagnostics extensions in this directory.
struct SubmissionDiagnosticsContext {
    let courseID: UUID?
    let assignmentID: UUID?
}

final class OperationalDiagnosticsService: @unchecked Sendable {
    let configuration: DiagnosticsConfiguration
    let maintenance = DiagnosticsMaintenanceStore()
    let compatibilityCounters = CompatibilityCounterStore()

    init(configuration: DiagnosticsConfiguration) {
        self.configuration = configuration
    }
}

extension OperationalDiagnosticsService {
    // Returns the set of test setup IDs from the given list that exist in the database.
    // Previously restricted to worker-mode setups; now includes browser-mode because
    // the worker serves as a backstop for pending browser submissions.
    func workerModeTestSetupIDs(for testSetupIDs: [String], on db: Database) async throws -> Set<String> {
        var result: Set<String> = []
        for testSetupID in Set(testSetupIDs) {
            guard let setup = try await APITestSetup.find(testSetupID, on: db) else { continue }
            let manifest = try? JSONDecoder().decode(
                TestProperties.self, from: Data(setup.manifest.utf8))
            // Browser-graded setups are processed by the in-browser Pyodide runner,
            // not the native worker. Exclude them from the worker queue depth metric.
            guard manifest?.gradingMode != .browser else { continue }
            result.insert(testSetupID)
        }
        return result
    }
}

func inferredFinalStatus(from collection: TestOutcomeCollection) -> JobFinalStatus {
    if collection.timeoutCount > 0 { return .timeout }
    if collection.errorCount > 0 { return .error }
    if collection.buildStatus == .failed || collection.failCount > 0 { return .failed }
    return .passed
}

func inferredTerminationReason(from collection: TestOutcomeCollection) -> String {
    if collection.timeoutCount > 0 { return "test_timeout" }
    if collection.errorCount > 0 { return "test_error" }
    if collection.failCount > 0 || collection.buildStatus == .failed { return "test_failure" }
    return "completed"
}

func millisecondsBetween(_ start: Date?, _ end: Date?) -> Int? {
    guard let start, let end else { return nil }
    guard end >= start else { return nil }
    return Int((end.timeIntervalSince(start) * 1000).rounded())
}

func iso8601Metadata(_ date: Date) -> Logger.MetadataValue {
    .string(ISO8601DateFormatter().string(from: date))
}

private func environmentInt(_ key: String) -> Int? {
    guard
        let raw = Environment.get(key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
        let value = Int(raw)
    else {
        return nil
    }
    return value
}

struct DiagnosticsConfigurationKey: StorageKey {
    typealias Value = DiagnosticsConfiguration
}

struct OperationalDiagnosticsServiceKey: StorageKey {
    typealias Value = OperationalDiagnosticsService
}

struct ObservabilityLifecycleHandler: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        Task {
            await application.diagnostics.pruneNow(on: application.db, logger: application.logger)
        }
    }
}

extension Application {
    var diagnosticsConfiguration: DiagnosticsConfiguration {
        get {
            if let existing = storage[DiagnosticsConfigurationKey.self] { return existing }
            let created = DiagnosticsConfiguration.fromEnvironment()
            storage[DiagnosticsConfigurationKey.self] = created
            return created
        }
        set { storage[DiagnosticsConfigurationKey.self] = newValue }
    }

    var diagnostics: OperationalDiagnosticsService {
        get {
            if let existing = storage[OperationalDiagnosticsServiceKey.self] { return existing }
            let created = OperationalDiagnosticsService(configuration: diagnosticsConfiguration)
            storage[OperationalDiagnosticsServiceKey.self] = created
            return created
        }
        set { storage[OperationalDiagnosticsServiceKey.self] = newValue }
    }
}
