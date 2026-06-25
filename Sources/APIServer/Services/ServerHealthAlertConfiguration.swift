import Foundation
import Vapor

struct ServerHealthAlertConfiguration: Sendable {
    let enabled: Bool
    let checkIntervalSeconds: TimeInterval
    let cooldownSeconds: TimeInterval
    /// Grace period for the runner-offline rule: fire when a runner we've seen
    /// this session has not checked in within this window, regardless of whether
    /// jobs are queued.
    let runnerOfflineSeconds: TimeInterval
    let queueDepthThreshold: Int
    let oldestPendingSeconds: TimeInterval
    let errorRateThreshold: Double
    let errorRateWindowSize: Int
    let errorRateMinimumSamples: Int
    /// Editor kernel-UNRECOVERABLE rule: fire when at least
    /// `editorUnrecoverableThreshold` distinct `recover_failed` reports land
    /// within the last `editorUnrecoverableWindowMinutes`. `recover_failed`
    /// means a student's kernel hung, the editor auto-rebooted it, and it hung
    /// AGAIN — the student genuinely cannot proceed. Plain post-idle `exec_hang`s
    /// that auto-recover are deliberately NOT alerted on (they stay in
    /// client-diagnostics telemetry for analysis); this rule pages only on the
    /// students who are actually stuck.
    let editorUnrecoverableThreshold: Int
    let editorUnrecoverableWindowMinutes: Int
    let webhookURLFromEnvironment: String?

    static let `default` = ServerHealthAlertConfiguration(
        enabled: false,
        checkIntervalSeconds: 60,
        cooldownSeconds: 1800,
        runnerOfflineSeconds: 300,
        queueDepthThreshold: 25,
        oldestPendingSeconds: 600,
        errorRateThreshold: 0.30,
        errorRateWindowSize: 50,
        errorRateMinimumSamples: 10,
        editorUnrecoverableThreshold: 2,
        editorUnrecoverableWindowMinutes: 60,
        webhookURLFromEnvironment: nil
    )

    static func fromEnvironment() -> Self {
        Self(
            enabled: environmentBool("ALERT_ENABLED") ?? false,
            checkIntervalSeconds: TimeInterval(environmentInt("ALERT_CHECK_INTERVAL_SECONDS") ?? 60),
            cooldownSeconds: TimeInterval(environmentInt("ALERT_COOLDOWN_SECONDS") ?? 1800),
            runnerOfflineSeconds: TimeInterval(environmentInt("ALERT_RUNNER_OFFLINE_SECONDS") ?? 300),
            queueDepthThreshold: environmentInt("ALERT_QUEUE_DEPTH_THRESHOLD") ?? 25,
            oldestPendingSeconds: TimeInterval(environmentInt("ALERT_OLDEST_PENDING_SECONDS") ?? 600),
            errorRateThreshold: environmentDouble("ALERT_ERROR_RATE_THRESHOLD") ?? 0.30,
            errorRateWindowSize: environmentInt("ALERT_ERROR_RATE_WINDOW") ?? 50,
            errorRateMinimumSamples: environmentInt("ALERT_ERROR_RATE_MIN_SAMPLES") ?? 10,
            editorUnrecoverableThreshold: environmentInt("ALERT_EDITOR_UNRECOVERABLE_THRESHOLD")
                ?? environmentInt("ALERT_EDITOR_HANG_THRESHOLD") ?? 2,
            editorUnrecoverableWindowMinutes: environmentInt("ALERT_EDITOR_UNRECOVERABLE_WINDOW_MINUTES")
                ?? environmentInt("ALERT_EDITOR_HANG_WINDOW_MINUTES") ?? 60,
            webhookURLFromEnvironment: trimmedEnv("ALERT_WEBHOOK_URL")
        )
    }
}

struct ServerHealthAlertConfigurationKey: StorageKey {
    typealias Value = ServerHealthAlertConfiguration
}

extension Application {
    var serverHealthAlertConfiguration: ServerHealthAlertConfiguration {
        get { storage[ServerHealthAlertConfigurationKey.self] ?? appConfig.alerts }
        set { storage[ServerHealthAlertConfigurationKey.self] = newValue }
    }
}
