import Foundation
import Vapor

struct ServerHealthAlertConfiguration: Sendable {
    let enabled: Bool
    let checkIntervalSeconds: TimeInterval
    let cooldownSeconds: TimeInterval
    let runnerOfflineSeconds: TimeInterval
    let queueDepthThreshold: Int
    let oldestPendingSeconds: TimeInterval
    let errorRateThreshold: Double
    let errorRateWindowSize: Int
    let errorRateMinimumSamples: Int
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
        webhookURLFromEnvironment: nil
    )

    static func fromEnvironment() -> Self {
        Self(
            enabled: environmentBool("ALERT_ENABLED") ?? false,
            checkIntervalSeconds: TimeInterval(alertEnvironmentInt("ALERT_CHECK_INTERVAL_SECONDS") ?? 60),
            cooldownSeconds: TimeInterval(alertEnvironmentInt("ALERT_COOLDOWN_SECONDS") ?? 1800),
            runnerOfflineSeconds: TimeInterval(alertEnvironmentInt("ALERT_RUNNER_OFFLINE_SECONDS") ?? 300),
            queueDepthThreshold: alertEnvironmentInt("ALERT_QUEUE_DEPTH_THRESHOLD") ?? 25,
            oldestPendingSeconds: TimeInterval(alertEnvironmentInt("ALERT_OLDEST_PENDING_SECONDS") ?? 600),
            errorRateThreshold: alertEnvironmentDouble("ALERT_ERROR_RATE_THRESHOLD") ?? 0.30,
            errorRateWindowSize: alertEnvironmentInt("ALERT_ERROR_RATE_WINDOW") ?? 50,
            errorRateMinimumSamples: alertEnvironmentInt("ALERT_ERROR_RATE_MIN_SAMPLES") ?? 10,
            webhookURLFromEnvironment: trimmedEnv("ALERT_WEBHOOK_URL")
        )
    }
}

private func alertEnvironmentInt(_ key: String) -> Int? {
    guard let raw = trimmedEnv(key), let value = Int(raw) else { return nil }
    return value
}

private func alertEnvironmentDouble(_ key: String) -> Double? {
    guard let raw = trimmedEnv(key), let value = Double(raw) else { return nil }
    return value
}

private func trimmedEnv(_ key: String) -> String? {
    let raw = Environment.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw, !raw.isEmpty else { return nil }
    return raw
}

struct ServerHealthAlertConfigurationKey: StorageKey {
    typealias Value = ServerHealthAlertConfiguration
}

extension Application {
    var serverHealthAlertConfiguration: ServerHealthAlertConfiguration {
        get {
            if let existing = storage[ServerHealthAlertConfigurationKey.self] { return existing }
            let created = ServerHealthAlertConfiguration.fromEnvironment()
            storage[ServerHealthAlertConfigurationKey.self] = created
            return created
        }
        set { storage[ServerHealthAlertConfigurationKey.self] = newValue }
    }
}
