import Core
import Fluent
import Foundation
import SQLKit
import Vapor

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
        offlineThreshold: configuration.runnerOfflineSeconds,
        now: now
    )
    results[.runnerVersionSkew] = await evaluateRunnerVersionSkew(
        on: application,
        configuration: configuration,
        now: now
    )
    results[.queueBackedUp] = evaluateQueueBackedUp(
        pending: pendingState,
        depthThreshold: configuration.queueDepthThreshold,
        oldestPendingSeconds: configuration.oldestPendingSeconds
    )
    results[.errorRateSpike] =
        (try? await evaluateErrorRateSpike(
            on: application,
            configuration: configuration,
            now: now
        )) ?? .ok
    results[.editorKernelUnrecoverable] =
        (try? await evaluateEditorKernelUnrecoverable(
            on: application,
            configuration: configuration,
            now: now
        )) ?? .ok
    results[.brightspaceSyncFailing] =
        (try? await evaluateBrightspaceSyncFailing(
            on: application,
            configuration: configuration,
            now: now
        )) ?? .ok

    return results
}

// MARK: - Per-rule evaluators

struct PendingQueueState: Sendable {
    let pendingCount: Int
    let oldestPendingAge: TimeInterval?
    static let empty = PendingQueueState(pendingCount: 0, oldestPendingAge: nil)
}

private func loadPendingQueueState(on application: Application, now: Date) async throws -> PendingQueueState {
    let pending = try await APISubmission.query(on: application.db)
        .filter(\.$status == SubmissionStatus.pending.rawValue)
        .all()
    let pendingCount = pending.count
    // Use the effective enqueue time (retestedAt ?? submittedAt) so a fresh
    // retest of an old submission doesn't look like it's been queued for days.
    // Matches the queueWaitMs baseline established in v0.4.45.
    let oldestEnqueuedAt = pending.compactMap { $0.retestedAt ?? $0.submittedAt }.min()
    let oldestAge = oldestEnqueuedAt.map { now.timeIntervalSince($0) }
    return PendingQueueState(pendingCount: pendingCount, oldestPendingAge: oldestAge)
}

/// How long a silent-but-known runner stays "remembered" by the runner-offline
/// alert. Matches `WorkerActivityStore.snapshotsSortedByRecent`'s prune cutoff,
/// so a runner is forgotten by the alert (auto-resolving it) at the same moment
/// the admin dashboard drops it.
let runnerPresenceRememberSeconds: TimeInterval = 3600

/// Runner presence as seen by the alert evaluator. Separated from the store so
/// the firing decision is a pure, table-testable function.
struct RunnerPresenceState: Sendable {
    /// A runner checked in within the offline window.
    let recentWithinOffline: Bool
    /// We've seen at least one runner this session (still within the remember
    /// window). Guards the rule so a server with no runners configured never
    /// pages, and so a long-dead runner is forgotten (auto-resolves).
    let anyKnownRunner: Bool
}

/// Decides the runner-offline rule purely from runner presence — queue state is
/// not a gate. Fire when a runner we've seen this session has not checked in
/// within `offlineSeconds`, regardless of whether jobs are waiting. The
/// `anyKnownRunner` guard keeps a runner-less deployment quiet and lets a
/// long-dead runner auto-resolve once it ages out of the remember window. The
/// pending count is surfaced as context but never decides firing.
func decideRunnerOffline(
    pending: PendingQueueState,
    presence: RunnerPresenceState,
    offlineSeconds: TimeInterval
) -> RuleEvaluation {
    guard presence.anyKnownRunner, !presence.recentWithinOffline else { return .ok }
    var details: [String: String] = [
        "pending_count": String(pending.pendingCount),
        "runner_offline_threshold_seconds": String(Int(offlineSeconds)),
    ]
    if let age = pending.oldestPendingAge {
        details["oldest_pending_age_seconds"] = String(Int(age))
    }
    let pendingNote = pending.pendingCount > 0 ? "; \(pending.pendingCount) submission(s) pending" : ""
    return RuleEvaluation(
        isFiring: true,
        summary: "No runner heartbeat in \(Int(offlineSeconds))s\(pendingNote)",
        details: details
    )
}

private func evaluateRunnerOffline(
    on application: Application,
    pending: PendingQueueState,
    offlineThreshold: TimeInterval,
    now: Date
) async -> RuleEvaluation {
    let presence = await application.workerActivityStore.runnerPresence(
        graceSeconds: offlineThreshold,
        rememberSeconds: runnerPresenceRememberSeconds,
        now: now
    )
    let state = RunnerPresenceState(
        recentWithinOffline: presence.anyRecent,
        anyKnownRunner: presence.anyKnown
    )
    return decideRunnerOffline(
        pending: pending,
        presence: state,
        offlineSeconds: offlineThreshold
    )
}

/// Decides the runner-version-skew rule purely, so the firing logic is
/// table-testable without a Vapor app. Fire when a runner still known this
/// session advertises a version *behind* `serverVersion` — but only once the
/// server has been up longer than `graceSeconds`.
///
/// The grace is the crux. A blue/green deploy flips the server before it
/// refreshes the runner (`docs/zero-downtime-deploy.md` step 8), so immediately
/// after every deploy the runner is briefly a release behind. Gating on server
/// uptime means that expected, transient skew never pages — the freshly-booted
/// server's uptime is below the grace — while a runner that stays behind past
/// the grace (a failed runner refresh, or an old runner rejoining the fleet)
/// does. Correctness during the window is already protected independently by the
/// per-assignment minimum-runner-version gate (#1210), which queues rather than
/// mis-grades, so the alert can afford to wait for genuine, persistent skew.
///
/// Runner versions that don't parse as semver (a mock or third-party runner
/// reporting e.g. `"runner/1.0"`) are skipped, never counted as behind —
/// mirroring `RunnerVersionGate`'s tolerance so the fleet's odd one out can't
/// page.
func decideRunnerVersionSkew(
    serverVersion: String,
    runnerVersions: [String],
    serverUptimeSeconds: TimeInterval,
    graceSeconds: TimeInterval
) -> RuleEvaluation {
    guard serverUptimeSeconds >= graceSeconds else { return .ok }
    let comparator = VersionComparator()
    // A server version that itself doesn't parse can't ground a comparison; stay
    // quiet rather than guess. `ChickadeeVersion.current` is always clean semver,
    // so this is purely defensive.
    guard comparator.canParse(serverVersion) else { return .ok }

    let behind = runnerVersions.filter {
        comparator.compare($0, serverVersion) == .orderedAscending
    }
    guard !behind.isEmpty else { return .ok }

    let oldest =
        behind.min { (comparator.compare($0, $1) ?? .orderedSame) == .orderedAscending } ?? behind[0]
    let distinctBehind = Set(behind).sorted()
    return RuleEvaluation(
        isFiring: true,
        summary:
            "\(behind.count) runner(s) behind server v\(serverVersion) (oldest v\(oldest)) — "
            + "grading against a stale test runtime; refresh the runner image",
        details: [
            "server_version": serverVersion,
            "behind_count": String(behind.count),
            "behind_versions": distinctBehind.joined(separator: ","),
            "oldest_runner_version": oldest,
            "grace_seconds": String(Int(graceSeconds)),
        ]
    )
}

private func evaluateRunnerVersionSkew(
    on application: Application,
    configuration: ServerHealthAlertConfiguration,
    now: Date
) async -> RuleEvaluation {
    let uptime = now.timeIntervalSince(application.serverStartedAt)
    let versions = await application.workerActivityStore.knownRunnerVersions(
        rememberSeconds: runnerPresenceRememberSeconds,
        now: now
    )
    return decideRunnerVersionSkew(
        serverVersion: ChickadeeVersion.current,
        runnerVersions: versions,
        serverUptimeSeconds: uptime,
        graceSeconds: configuration.runnerVersionSkewGraceSeconds
    )
}

func evaluateQueueBackedUp(
    pending: PendingQueueState,
    depthThreshold: Int,
    oldestPendingSeconds: TimeInterval
) -> RuleEvaluation {
    // A backup means "items are sitting around" — depth alone isn't a signal,
    // since an instructor retesting an assignment can legitimately enqueue
    // hundreds of submissions that drain in minutes.  Only fire when the
    // oldest pending item has exceeded the age threshold; depth is included
    // in the summary as extra context when it's also high.
    let ageBreached = (pending.oldestPendingAge ?? 0) >= oldestPendingSeconds
    guard ageBreached, let age = pending.oldestPendingAge else { return .ok }

    var reasons: [String] = [
        "oldest pending \(Int(age))s old (>= \(Int(oldestPendingSeconds))s)"
    ]
    if pending.pendingCount >= depthThreshold {
        reasons.append("\(pending.pendingCount) pending (>= \(depthThreshold))")
    }

    return RuleEvaluation(
        isFiring: true,
        summary: "Queue backed up: \(reasons.joined(separator: "; "))",
        details: [
            "pending_count": String(pending.pendingCount),
            "queue_depth_threshold": String(depthThreshold),
            "oldest_pending_age_seconds": String(Int(age)),
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
        JobFailureClassification.isSystemFailure(
            finalStatus: $0.finalStatus,
            testsErrored: $0.testsErrored,
            testsTimedOut: $0.testsTimedOut
        )
    }.count
    let ratio = Double(bad) / Double(recent.count)
    guard ratio >= configuration.errorRateThreshold else { return .ok }

    let percent = Int((ratio * 100).rounded())
    return RuleEvaluation(
        isFiring: true,
        summary: "\(bad)/\(recent.count) recent jobs failed at the system level (\(percent)%)",
        details: [
            "system_failure_count": String(bad),
            "sample_size": String(recent.count),
            "system_failure_rate_percent": String(percent),
            "threshold_percent": String(Int((configuration.errorRateThreshold * 100).rounded())),
        ]
    )
}

/// Decides the editor-kernel-UNRECOVERABLE rule purely from a count, so the
/// firing threshold is table-testable without a database. Fire when at least
/// `threshold` `recover_failed` reports landed inside the window — a student
/// whose kernel hung, was auto-rebooted by the editor, and hung AGAIN, so they
/// genuinely cannot proceed. Plain post-idle `exec_hang`s that auto-recover are
/// NOT counted here — this rule pages only on the students who are actually stuck.
func decideEditorKernelUnrecoverable(
    failedCount: Int,
    threshold: Int,
    windowMinutes: Int
) -> RuleEvaluation {
    guard threshold > 0, failedCount >= threshold else { return .ok }
    return RuleEvaluation(
        isFiring: true,
        summary:
            "\(failedCount) student(s) could not recover after an editor kernel reboot "
            + "in the last \(windowMinutes)m (recover_failed; threshold \(threshold))",
        details: [
            "recover_failed_count": String(failedCount),
            "window_minutes": String(windowMinutes),
            "threshold": String(threshold),
        ]
    )
}

private func evaluateEditorKernelUnrecoverable(
    on application: Application,
    configuration: ServerHealthAlertConfiguration,
    now: Date
) async throws -> RuleEvaluation {
    let windowStart = now.addingTimeInterval(-Double(configuration.editorUnrecoverableWindowMinutes) * 60)
    // recover_failed rides the free-form `source` on the `kernel_error` kind
    // (notebook.js recoverHungKernelOnce → ClientDiagnosticsRoutes): the editor
    // auto-rebooted a hung kernel and it hung AGAIN. One row per distinct
    // student-page that could not recover — the genuinely-stuck students. Plain
    // `exec_hang`s (which usually auto-recover) are intentionally not counted.
    let failedCount = try await APIClientDiagnostic.query(on: application.db)
        .filter(\.$kind == "kernel_error")
        .filter(\.$source == "recover_failed")
        .filter(\.$createdAt >= windowStart)
        .count()
    return decideEditorKernelUnrecoverable(
        failedCount: failedCount,
        threshold: configuration.editorUnrecoverableThreshold,
        windowMinutes: configuration.editorUnrecoverableWindowMinutes
    )
}

/// Distinguishes job-level (infrastructure) failures from per-test student-code
/// failures rolled up into `JobExecutionMetric.finalStatus`.
///
/// `inferredFinalStatus(from:)` marks the whole job `.error`/`.timeout` whenever
/// any individual test reports `error` or `timeout` — i.e. whenever a student's
/// own code raises or runs long.  The health alert wants the opposite: only
/// jobs whose error/timeout is *not* explained by per-test outcomes (so the
/// runner itself crashed or the worker timed out a job before it finished).
enum JobFailureClassification {
    static func isSystemFailure(
        finalStatus: String?,
        testsErrored: Int?,
        testsTimedOut: Int?
    ) -> Bool {
        switch finalStatus {
        case JobFinalStatus.timeout.rawValue:
            return (testsTimedOut ?? 0) == 0
        case JobFinalStatus.error.rawValue:
            return (testsErrored ?? 0) == 0
        default:
            return false
        }
    }
}

/// Decides the BrightSpace-sync-failing rule purely from a recent error count,
/// so the firing threshold is table-testable without a database. Fire when at
/// least `threshold` grade-push errors landed inside the window — grades have
/// stopped reaching LEARN. `lastDetail` (the most recent D2L error) is surfaced
/// as context when present.
func decideBrightspaceSyncFailing(
    errorCount: Int,
    threshold: Int,
    windowMinutes: Int,
    lastDetail: String?
) -> RuleEvaluation {
    guard threshold > 0, errorCount >= threshold else { return .ok }
    var details: [String: String] = [
        "error_count": String(errorCount),
        "window_minutes": String(windowMinutes),
        "threshold": String(threshold),
    ]
    if let lastDetail, !lastDetail.isEmpty { details["last_error"] = lastDetail }
    let suffix = (lastDetail?.isEmpty == false) ? " (latest: \(lastDetail ?? ""))" : ""
    return RuleEvaluation(
        isFiring: true,
        summary:
            "\(errorCount) BrightSpace grade push(es) failed in the last \(windowMinutes)m "
            + "(threshold \(threshold))\(suffix)",
        details: details
    )
}

private func evaluateBrightspaceSyncFailing(
    on application: Application,
    configuration: ServerHealthAlertConfiguration,
    now: Date
) async throws -> RuleEvaluation {
    let windowStart = now.addingTimeInterval(-Double(configuration.brightspaceSyncFailureWindowMinutes) * 60)
    let errored = try await APIBrightSpaceSyncLog.query(on: application.db)
        .filter(\.$status == APIBrightSpaceSyncLog.Status.error.rawValue)
        .filter(\.$attemptedAt >= windowStart)
        .sort(\.$attemptedAt, .descending)
        .all()
    return decideBrightspaceSyncFailing(
        errorCount: errored.count,
        threshold: configuration.brightspaceSyncFailureThreshold,
        windowMinutes: configuration.brightspaceSyncFailureWindowMinutes,
        lastDetail: errored.first?.detail
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
            let shouldEmit =
                state.lastFiredAt == nil
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
    /// Whether this rule pages the operator webhook at all. Advisory (`info`)
    /// rules are recorded here for the dashboard but never paged, so the view can
    /// show "advisory" rather than mistaking a deliberate non-page for a failure.
    let paged: Bool
    let delivered: Bool
    let deliveryError: String?
}

// MARK: - Monitor actor

/// Holds the alert rule state machine, recent-firings buffer, and webhook
/// override.  The periodic *driving* of `sweep` lives in a separate
/// `PeriodicSweepMonitor` (see `serverHealthAlertSweepMonitor`); this actor
/// owns only the per-sweep logic and its mutable state.
actor ServerHealthAlertMonitor {
    static let recentFiringsCap = 50

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
            paged: true,
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
                paged: true,
                delivered: true,
                deliveryError: nil
            )
        } catch {
            record = AlertFiringRecord(
                rule: alert.rule,
                resolved: false,
                summary: alert.summary,
                firedAt: alert.firedAt,
                paged: true,
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
            // Advisory (`info`-severity) rules are recorded and logged so they
            // stay visible on `/admin/alerts` and via `get_health_alerts`, but
            // they never page the operator webhook.
            let pages = transition.rule.pagesOperator
            var delivered = false
            var deliveryError: String?
            if pages {
                do {
                    try await activeNotifier.send(alert, on: application)
                    delivered = true
                } catch {
                    deliveryError = String(describing: error)
                    application.logger.warning(
                        "alert_delivery_failed",
                        metadata: [
                            "rule": .string(alert.rule),
                            "resolved": .stringConvertible(alert.resolved),
                            "error": .string(deliveryError ?? "unknown"),
                        ])
                }
            }
            application.logger.info(
                "alert_emitted",
                metadata: [
                    "rule": .string(alert.rule),
                    "resolved": .stringConvertible(alert.resolved),
                    "summary": .string(alert.summary),
                    "paged": .stringConvertible(pages),
                    "delivered": .stringConvertible(delivered),
                ])
            appendFiring(
                AlertFiringRecord(
                    rule: alert.rule,
                    resolved: alert.resolved,
                    summary: alert.summary,
                    firedAt: alert.firedAt,
                    paged: pages,
                    delivered: delivered,
                    deliveryError: deliveryError
                ))
        }
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
        let summary =
            resolved
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
        !text.isEmpty
    else {
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

/// Not the generic `PeriodicSweepLifecycleHandler`: boot is gated on the
/// alerts-enabled flag (with its own log line when disabled).
struct ServerHealthAlertLifecycleHandler: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        // Stamp the boot time unconditionally (before the enabled-guard) so the
        // runner-version-skew deploy grace is accurate even when paging is off
        // and only the read-only `get_health_alerts` view evaluates the rule.
        application.serverStartedAt = Date()
        guard application.serverHealthAlertConfiguration.enabled else {
            application.logger.info("server_health_alerts_disabled")
            return
        }
        application.serverHealthAlertSweepMonitor.start(application: application)
    }

    func shutdown(_ application: Application) {
        application.serverHealthAlertSweepMonitor.stop()
    }
}

struct ServerHealthAlertMonitorKey: StorageKey {
    typealias Value = ServerHealthAlertMonitor
}

struct ServerHealthAlertSweepMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

struct ServerHealthAlertWebhookURLFilePathKey: StorageKey {
    typealias Value = String
}

struct ServerStartedAtKey: StorageKey {
    typealias Value = Date
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

    /// Drives `serverHealthAlertMonitor.sweep` on the configured cadence.
    /// No `runImmediately` boot sweep — the loop's first iteration sweeps
    /// right away, matching the historical actor loop, and there was never
    /// an extra detached boot sweep for this service.
    var serverHealthAlertSweepMonitor: PeriodicSweepMonitor {
        get {
            if let existing = storage[ServerHealthAlertSweepMonitorKey.self] { return existing }
            let created = PeriodicSweepMonitor(
                name: "Server health alert",
                interval: serverHealthAlertConfiguration.checkIntervalSeconds,
                minimumInterval: 5,
                runImmediately: false
            ) { application in
                await application.serverHealthAlertMonitor.sweep(application: application)
            }
            storage[ServerHealthAlertSweepMonitorKey.self] = created
            return created
        }
        set { storage[ServerHealthAlertSweepMonitorKey.self] = newValue }
    }

    var alertWebhookURLFilePath: String {
        get {
            storage[ServerHealthAlertWebhookURLFilePathKey.self]
                ?? (DirectoryConfiguration.detect().workingDirectory + ".alert-webhook-url")
        }
        set { storage[ServerHealthAlertWebhookURLFilePathKey.self] = newValue }
    }

    /// When this server process booted — used by the runner-version-skew alert's
    /// deploy grace (see `decideRunnerVersionSkew`). Set explicitly at boot by
    /// `ServerHealthAlertLifecycleHandler.didBoot`; the lazy fallback captures the
    /// first read for paths that never ran the handler (e.g. a test app that
    /// evaluates rules directly), so the value is always populated and stable.
    var serverStartedAt: Date {
        get {
            if let existing = storage[ServerStartedAtKey.self] { return existing }
            let now = Date()
            storage[ServerStartedAtKey.self] = now
            return now
        }
        set { storage[ServerStartedAtKey.self] = newValue }
    }
}
