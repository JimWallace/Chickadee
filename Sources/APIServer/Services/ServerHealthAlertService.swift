import Fluent
import SQLKit
import Vapor
import Foundation

struct RuleEvaluation: Sendable {
    let isFiring: Bool
    let summary: String
    let details: [String: String]

    static let ok = RuleEvaluation(isFiring: false, summary: "ok", details: [:])
}

@discardableResult
func evaluateHealthRules(
    on application: Application,
    configuration: ServerHealthAlertConfiguration,
    now: Date = Date()
) async -> [HealthRule: RuleEvaluation] {
    var results: [HealthRule: RuleEvaluation] = [:]
    for rule in HealthRule.allCases { results[rule] = .ok }

    let dbResult = await evaluateDatabaseUnreachable(on: application)
    results[.databaseUnreachable] = dbResult
    if dbResult.isFiring {
        // Skip DB-dependent rules when the database is down.
        return results
    }

    let pendingState = (try? await loadPendingQueueState(on: application, now: now)) ?? PendingQueueState.empty
    results[.runnerOffline] = await evaluateRunnerOffline(
        on: application,
        pending: pendingState,
        threshold: configuration.runnerOfflineSeconds,
        now: now
    )
    results[.queueBackedUp] = evaluateQueueBackedUp(
        pending: pendingState,
        depthThreshold: configuration.queueDepthThreshold,
        oldestPendingSeconds: configuration.oldestPendingSeconds
    )
    results[.errorRateSpike] = (try? await evaluateErrorRateSpike(
        on: application,
        configuration: configuration,
        now: now
    )) ?? .ok

    return results
}

// MARK: - Per-rule evaluators

private struct PendingQueueState: Sendable {
    let pendingCount: Int
    let oldestPendingAge: TimeInterval?
    static let empty = PendingQueueState(pendingCount: 0, oldestPendingAge: nil)
}

private func loadPendingQueueState(on application: Application, now: Date) async throws -> PendingQueueState {
    let pending = try await APISubmission.query(on: application.db)
        .filter(\.$status == "pending")
        .all()
    let pendingCount = pending.count
    let oldestSubmittedAt = pending.compactMap(\.submittedAt).min()
    let oldestAge = oldestSubmittedAt.map { now.timeIntervalSince($0) }
    return PendingQueueState(pendingCount: pendingCount, oldestPendingAge: oldestAge)
}

private func evaluateRunnerOffline(
    on application: Application,
    pending: PendingQueueState,
    threshold: TimeInterval,
    now: Date
) async -> RuleEvaluation {
    guard pending.pendingCount > 0 else { return .ok }
    let hasRecentRunner = await application.workerActivityStore.hasRecentActivity(
        within: threshold,
        now: now
    )
    if hasRecentRunner { return .ok }
    return RuleEvaluation(
        isFiring: true,
        summary: "No runner heartbeat in \(Int(threshold))s; \(pending.pendingCount) submission(s) pending",
        details: [
            "pending_count": String(pending.pendingCount),
            "runner_offline_threshold_seconds": String(Int(threshold)),
            "oldest_pending_age_seconds": pending.oldestPendingAge.map { String(Int($0)) } ?? "n/a",
        ]
    )
}

private func evaluateQueueBackedUp(
    pending: PendingQueueState,
    depthThreshold: Int,
    oldestPendingSeconds: TimeInterval
) -> RuleEvaluation {
    let depthBreached = pending.pendingCount >= depthThreshold
    let ageBreached = (pending.oldestPendingAge ?? 0) >= oldestPendingSeconds
    guard depthBreached || ageBreached else { return .ok }

    var reasons: [String] = []
    if depthBreached { reasons.append("\(pending.pendingCount) pending (>= \(depthThreshold))") }
    if ageBreached, let age = pending.oldestPendingAge {
        reasons.append("oldest pending \(Int(age))s old (>= \(Int(oldestPendingSeconds))s)")
    }

    return RuleEvaluation(
        isFiring: true,
        summary: "Queue backed up: \(reasons.joined(separator: "; "))",
        details: [
            "pending_count": String(pending.pendingCount),
            "queue_depth_threshold": String(depthThreshold),
            "oldest_pending_age_seconds": pending.oldestPendingAge.map { String(Int($0)) } ?? "n/a",
            "oldest_pending_threshold_seconds": String(Int(oldestPendingSeconds)),
        ]
    )
}

private func evaluateErrorRateSpike(
    on application: Application,
    configuration: ServerHealthAlertConfiguration,
    now: Date
) async throws -> RuleEvaluation {
    // 7-day window matches diagnostics retention; the descending sort + limit picks
    // the most recent N jobs.  The date filter implicitly excludes rows where
    // `completedAt` is still null (job not yet finalised).
    let windowStart = now.addingTimeInterval(-7 * 86400)
    let recent = try await JobExecutionMetric.query(on: application.db)
        .filter(\.$completedAt >= windowStart)
        .sort(\.$completedAt, .descending)
        .limit(configuration.errorRateWindowSize)
        .all()

    guard recent.count >= configuration.errorRateMinimumSamples else { return .ok }

    let bad = recent.filter {
        $0.finalStatus == JobFinalStatus.error.rawValue
            || $0.finalStatus == JobFinalStatus.timeout.rawValue
    }.count
    let ratio = Double(bad) / Double(recent.count)
    guard ratio >= configuration.errorRateThreshold else { return .ok }

    let percent = Int((ratio * 100).rounded())
    return RuleEvaluation(
        isFiring: true,
        summary: "\(bad)/\(recent.count) recent jobs errored or timed out (\(percent)%)",
        details: [
            "error_count": String(bad),
            "sample_size": String(recent.count),
            "error_rate_percent": String(percent),
            "threshold_percent": String(Int((configuration.errorRateThreshold * 100).rounded())),
        ]
    )
}

private func evaluateDatabaseUnreachable(on application: Application) async -> RuleEvaluation {
    do {
        guard let sql = application.db as? SQLDatabase else {
            return RuleEvaluation(
                isFiring: true,
                summary: "Database does not expose SQL interface",
                details: ["error": "not_sql_database"]
            )
        }
        _ = try await sql.raw("SELECT 1").all()
        return .ok
    } catch {
        return RuleEvaluation(
            isFiring: true,
            summary: "Database unreachable: \(error.localizedDescription)",
            details: ["error": String(describing: error)]
        )
    }
}

// MARK: - Cooldown state machine (pure, testable)

struct AlertRuleState: Sendable, Equatable {
    var isFiring: Bool
    var lastFiredAt: Date?

    static let initial = AlertRuleState(isFiring: false, lastFiredAt: nil)
}

struct AlertTransition: Sendable {
    let rule: HealthRule
    let evaluation: RuleEvaluation
    let resolved: Bool
}

/// Compares previous rule states to fresh evaluations and returns the messages to
/// dispatch plus the new state map.  Pure function — kept outside the actor so it
/// can be tested without spinning up a Vapor app.
func transitionAlerts(
    states: [HealthRule: AlertRuleState],
    evaluations: [HealthRule: RuleEvaluation],
    cooldown: TimeInterval,
    now: Date
) -> (newStates: [HealthRule: AlertRuleState], transitions: [AlertTransition]) {
    var newStates = states
    var transitions: [AlertTransition] = []

    for rule in HealthRule.allCases {
        let evaluation = evaluations[rule] ?? .ok
        var state = states[rule] ?? .initial

        if evaluation.isFiring {
            let elapsedSinceLastFire = state.lastFiredAt.map { now.timeIntervalSince($0) }
            let shouldEmit = state.lastFiredAt == nil
                || (elapsedSinceLastFire ?? .infinity) >= cooldown
            if shouldEmit {
                transitions.append(AlertTransition(rule: rule, evaluation: evaluation, resolved: false))
                state.lastFiredAt = now
            }
            state.isFiring = true
        } else if state.isFiring {
            transitions.append(AlertTransition(rule: rule, evaluation: evaluation, resolved: true))
            state.isFiring = false
        }
        newStates[rule] = state
    }

    return (newStates, transitions)
}

// MARK: - Recent firings buffer

struct AlertFiringRecord: Encodable, Sendable {
    let rule: String
    let resolved: Bool
    let summary: String
    let firedAt: String
    let delivered: Bool
    let deliveryError: String?
}

// MARK: - Monitor actor

actor ServerHealthAlertMonitor {
    static let recentFiringsCap = 50

    private var task: Task<Void, Never>?
    private var ruleStates: [HealthRule: AlertRuleState] = [:]
    private var recentFirings: [AlertFiringRecord] = []
    private var webhookURLOverride: String?
    private let configuration: ServerHealthAlertConfiguration
    private let webhookURLFilePath: String

    init(configuration: ServerHealthAlertConfiguration, webhookURLFilePath: String) {
        self.configuration = configuration
        self.webhookURLFilePath = webhookURLFilePath
    }

    /// Effective webhook URL — admin-set runtime override beats the disk-persisted
    /// value beats the env var.
    func effectiveWebhookURL() -> String? {
        if let override = webhookURLOverride, !override.isEmpty { return override }
        if let disk = readAlertWebhookURLFromDisk(filePath: webhookURLFilePath), !disk.isEmpty {
            return disk
        }
        return configuration.webhookURLFromEnvironment
    }

    func setWebhookURL(_ url: String?) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        webhookURLOverride = trimmed.isEmpty ? nil : trimmed
        writeAlertWebhookURLToDisk(value: trimmed, filePath: webhookURLFilePath)
    }

    func recentFiringsSnapshot() -> [AlertFiringRecord] {
        recentFirings
    }

    func currentRuleStates() -> [HealthRule: AlertRuleState] {
        ruleStates
    }

    func resetForTesting() {
        ruleStates = [:]
        recentFirings = []
    }

    private func notifier(for application: Application) -> any AlertNotifier {
        guard let url = effectiveWebhookURL(), !url.isEmpty else {
            return NoopNotifier()
        }
        return WebhookNotifier(webhookURL: url)
    }

    func dispatchTestAlert(application: Application) async throws -> AlertFiringRecord {
        let now = Date()
        let alert = makeAlertMessage(
            rule: .runnerOffline,
            evaluation: RuleEvaluation(
                isFiring: true,
                summary: "Test alert from /admin/alerts (no real outage detected)",
                details: ["test": "true"]
            ),
            resolved: false,
            firedAt: now,
            application: application
        )
        var record = AlertFiringRecord(
            rule: alert.rule,
            resolved: false,
            summary: alert.summary,
            firedAt: alert.firedAt,
            delivered: false,
            deliveryError: nil
        )
        do {
            try await notifier(for: application).send(alert, on: application)
            record = AlertFiringRecord(
                rule: alert.rule,
                resolved: false,
                summary: alert.summary,
                firedAt: alert.firedAt,
                delivered: true,
                deliveryError: nil
            )
        } catch {
            record = AlertFiringRecord(
                rule: alert.rule,
                resolved: false,
                summary: alert.summary,
                firedAt: alert.firedAt,
                delivered: false,
                deliveryError: String(describing: error)
            )
            appendFiring(record)
            throw error
        }
        appendFiring(record)
        return record
    }

    /// Run a single sweep — public so the lifecycle handler can run an initial sweep
    /// and tests can drive the monitor synchronously.
    func sweep(application: Application, now: Date = Date()) async {
        let evaluations = await evaluateHealthRules(
            on: application,
            configuration: configuration,
            now: now
        )
        let (newStates, transitions) = transitionAlerts(
            states: ruleStates,
            evaluations: evaluations,
            cooldown: configuration.cooldownSeconds,
            now: now
        )
        ruleStates = newStates

        let activeNotifier = notifier(for: application)
        for transition in transitions {
            let alert = makeAlertMessage(
                rule: transition.rule,
                evaluation: transition.evaluation,
                resolved: transition.resolved,
                firedAt: now,
                application: application
            )
            var delivered = false
            var deliveryError: String?
            do {
                try await activeNotifier.send(alert, on: application)
                delivered = true
            } catch {
                deliveryError = String(describing: error)
                application.logger.warning("alert_delivery_failed", metadata: [
                    "rule": .string(alert.rule),
                    "resolved": .stringConvertible(alert.resolved),
                    "error": .string(deliveryError ?? "unknown"),
                ])
            }
            application.logger.info("alert_emitted", metadata: [
                "rule": .string(alert.rule),
                "resolved": .stringConvertible(alert.resolved),
                "summary": .string(alert.summary),
                "delivered": .stringConvertible(delivered),
            ])
            appendFiring(AlertFiringRecord(
                rule: alert.rule,
                resolved: alert.resolved,
                summary: alert.summary,
                firedAt: alert.firedAt,
                delivered: delivered,
                deliveryError: deliveryError
            ))
        }
    }

    func start(application: Application) {
        guard task == nil else { return }
        guard configuration.enabled else {
            application.logger.info("server_health_alerts_disabled")
            return
        }
        let intervalNs = UInt64(max(configuration.checkIntervalSeconds, 5) * 1_000_000_000)
        task = Task {
            while !Task.isCancelled {
                await self.sweep(application: application)
                do {
                    try await Task.sleep(nanoseconds: intervalNs)
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func appendFiring(_ record: AlertFiringRecord) {
        recentFirings.insert(record, at: 0)
        if recentFirings.count > Self.recentFiringsCap {
            recentFirings.removeLast(recentFirings.count - Self.recentFiringsCap)
        }
    }

    private func makeAlertMessage(
        rule: HealthRule,
        evaluation: RuleEvaluation,
        resolved: Bool,
        firedAt: Date,
        application: Application
    ) -> AlertMessage {
        let summary = resolved
            ? "RESOLVED: \(rule.humanReadable)"
            : evaluation.summary
        let serverURL = application.securityConfiguration.publicBaseURL?.absoluteString ?? ""
        var details = evaluation.details
        details["rule_human"] = rule.humanReadable
        return AlertMessage(
            rule: rule.rawValue,
            severity: rule.severity,
            firedAt: formatAlertTimestamp(firedAt),
            resolved: resolved,
            summary: summary,
            details: details,
            serverURL: serverURL,
            text: "[Chickadee] \(summary)"
        )
    }
}

private func formatAlertTimestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

// MARK: - Webhook URL persistence

func readAlertWebhookURLFromDisk(filePath: String) -> String? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
          let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else {
        return nil
    }
    return text
}

func writeAlertWebhookURLToDisk(value: String, filePath: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = URL(fileURLWithPath: filePath)
    if trimmed.isEmpty {
        try? FileManager.default.removeItem(at: url)
        return
    }
    try? trimmed.write(to: url, atomically: true, encoding: .utf8)
}

// MARK: - Lifecycle handler + Application accessors

struct ServerHealthAlertLifecycleHandler: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        let monitor = application.serverHealthAlertMonitor
        Task {
            await monitor.start(application: application)
        }
    }

    func shutdown(_ application: Application) {
        let monitor = application.serverHealthAlertMonitor
        Task {
            await monitor.stop()
        }
    }
}

struct ServerHealthAlertMonitorKey: StorageKey {
    typealias Value = ServerHealthAlertMonitor
}

struct ServerHealthAlertWebhookURLFilePathKey: StorageKey {
    typealias Value = String
}

extension Application {
    var serverHealthAlertMonitor: ServerHealthAlertMonitor {
        get {
            if let existing = storage[ServerHealthAlertMonitorKey.self] { return existing }
            let created = ServerHealthAlertMonitor(
                configuration: serverHealthAlertConfiguration,
                webhookURLFilePath: alertWebhookURLFilePath
            )
            storage[ServerHealthAlertMonitorKey.self] = created
            return created
        }
        set { storage[ServerHealthAlertMonitorKey.self] = newValue }
    }

    var alertWebhookURLFilePath: String {
        get {
            storage[ServerHealthAlertWebhookURLFilePathKey.self]
                ?? (DirectoryConfiguration.detect().workingDirectory + ".alert-webhook-url")
        }
        set { storage[ServerHealthAlertWebhookURLFilePathKey.self] = newValue }
    }
}
