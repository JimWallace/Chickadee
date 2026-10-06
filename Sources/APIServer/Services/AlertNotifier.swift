// APIServer/Services/AlertNotifier.swift
//
import Foundation
import Vapor

enum HealthRule: String, CaseIterable, Codable, Sendable {
    case runnerOffline
    case runnerMissing
    case runnerVersionSkew
    case queueBackedUp
    case errorRateSpike
    case editorKernelUnrecoverable
    case databaseUnreachable
    case brightspaceSyncFailing
    case outboundEgressFailing
    case deployerUnhealthy
    case unclaimableJobs

    var humanReadable: String {
        switch self {
        case .runnerOffline: return "Runner offline"
        case .runnerMissing: return "Named runner not polling"
        case .runnerVersionSkew: return "Runner version skew"
        case .queueBackedUp: return "Submission queue backed up"
        case .errorRateSpike: return "System-level failure rate spike"
        case .editorKernelUnrecoverable: return "Editor kernel unrecoverable"
        case .databaseUnreachable: return "Database unreachable"
        case .brightspaceSyncFailing: return "BrightSpace grade sync failing"
        case .outboundEgressFailing: return "Outbound network unreachable"
        case .deployerUnhealthy: return "Auto-deploy not healthy"
        case .unclaimableJobs: return "Jobs no runner can grade"
        }
    }

    var severity: String {
        switch self {
        case .databaseUnreachable: return "critical"
        // Critical because it is an outage the running process hides: the
        // server keeps serving on established connections while every new
        // outbound call fails, so nothing else here goes red.
        case .outboundEgressFailing: return "critical"
        case .runnerOffline: return "warning"
        // Warning, not info: one runner down while others poll is exactly the
        // outage nothing else reports (Sept 2026, sparrow, several days).
        case .runnerMissing: return "warning"
        // Warning, not info: the #1210 minimum-runner-version gate keeps a stale
        // runner from mis-grading, but nothing keeps it from running without a
        // sandbox fix, such as the capability drop of #2274.
        case .runnerVersionSkew: return "warning"
        // Warning: prod stays on an old release, or stops receiving releases at
        // all, until someone acts on the host.
        case .deployerUnhealthy: return "warning"
        case .unclaimableJobs: return "warning"
        case .queueBackedUp: return "warning"
        case .errorRateSpike: return "warning"
        case .editorKernelUnrecoverable: return "warning"
        case .brightspaceSyncFailing: return "warning"
        }
    }

    /// Whether a firing of this rule pages the operator webhook. Informational
    /// rules (`info` severity) still surface on `/admin/alerts` and via the
    /// `get_health_alerts` admin tool, but they are advisory and do not page — so
    /// a low-stakes signal like a runner being a release behind never reads as an
    /// outage.
    var pagesOperator: Bool { severity != "info" }
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
        application.logger.info(
            "alert_emitted_noop",
            metadata: [
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
        case .invalidURL(let url): return "Invalid webhook URL: \(url)"
        case .unexpectedStatus(let s): return "Webhook responded with HTTP \(s)"
        }
    }
}
