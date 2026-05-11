import Vapor
import Foundation

enum HealthRule: String, CaseIterable, Codable, Sendable {
    case runnerOffline
    case queueBackedUp
    case errorRateSpike
    case databaseUnreachable

    var humanReadable: String {
        switch self {
        case .runnerOffline:       return "Runner offline while jobs queued"
        case .queueBackedUp:       return "Submission queue backed up"
        case .errorRateSpike:      return "System-level failure rate spike"
        case .databaseUnreachable: return "Database unreachable"
        }
    }

    var severity: String {
        switch self {
        case .databaseUnreachable: return "critical"
        case .runnerOffline:       return "warning"
        case .queueBackedUp:       return "warning"
        case .errorRateSpike:      return "warning"
        }
    }
}

struct AlertMessage: Content, Sendable {
    let rule: String
    let severity: String
    let firedAt: String
    let resolved: Bool
    let summary: String
    let details: [String: String]
    let serverURL: String
    /// Slack/Discord/ntfy/Pushover all key off `text`; populated from `summary`.
    let text: String
}

protocol AlertNotifier: Sendable {
    func send(_ alert: AlertMessage, on application: Application) async throws
}

struct NoopNotifier: AlertNotifier {
    func send(_ alert: AlertMessage, on application: Application) async throws {
        application.logger.info("alert_emitted_noop", metadata: [
            "rule": .string(alert.rule),
            "resolved": .stringConvertible(alert.resolved),
            "summary": .string(alert.summary),
        ])
    }
}

struct WebhookNotifier: AlertNotifier {
    let webhookURL: String

    func send(_ alert: AlertMessage, on application: Application) async throws {
        let trimmed = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw WebhookNotifierError.invalidURL(webhookURL)
        }
        let response = try await application.client.post(URI(string: trimmed)) { req in
            try req.content.encode(alert, as: .json)
        }
        guard (200...299).contains(response.status.code) else {
            throw WebhookNotifierError.unexpectedStatus(Int(response.status.code))
        }
    }
}

enum WebhookNotifierError: Error, CustomStringConvertible {
    case invalidURL(String)
    case unexpectedStatus(Int)

    var description: String {
        switch self {
        case .invalidURL(let url):     return "Invalid webhook URL: \(url)"
        case .unexpectedStatus(let s): return "Webhook responded with HTTP \(s)"
        }
    }
}
