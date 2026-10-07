// APIServer/Routes/Web/AdminAlertsPresentation.swift
//
// What the Health alerts page says about a rule, a webhook and a firing,
// worked out in Swift so the template holds no branching on rule names.

import Foundation

extension HealthRule {
    /// The condition the rule fires on, in one short line, from the live
    /// configuration. Every rule has one: the Rules list shows it under the name.
    func thresholdText(_ config: ServerHealthAlertConfiguration) -> String {
        switch self {
        case .runnerOffline:
            return "no runner heartbeat for \(Int(config.runnerOfflineSeconds))s"
        case .runnerMissing:
            return "a named runner stops polling"
        case .runnerVersionSkew:
            return "a runner is behind the server for \(Int(config.runnerVersionSkewGraceSeconds))s"
        case .queueBackedUp:
            return "≥ \(config.queueDepthThreshold) pending or oldest > \(Int(config.oldestPendingSeconds))s"
        case .errorRateSpike:
            return
                "≥ \(Int((config.errorRateThreshold * 100).rounded()))% errors and timeouts in the last \(config.errorRateWindowSize) jobs"
        case .editorKernelUnrecoverable:
            return
                "≥ \(config.editorUnrecoverableThreshold) kernels fail to recover in \(config.editorUnrecoverableWindowMinutes) min"
        case .databaseUnreachable:
            return "SELECT 1 fails"
        case .brightspaceSyncFailing:
            return
                "≥ \(config.brightspaceSyncFailureThreshold) grade pushes fail in \(config.brightspaceSyncFailureWindowMinutes) min"
        case .outboundEgressFailing:
            return
                "≥ \(config.outboundFailureThreshold) outbound calls fail in \(config.outboundFailureWindowMinutes) min, none succeed"
        case .deployerUnhealthy:
            return "the deploy daemon is stuck, failing, or silent for \(Int(deployerStatusStaleAfterSeconds / 60)) min"
        case .unclaimableJobs:
            return "a job waits \(Int(unclaimableJobsMinimumWaitSeconds / 60)) min and no online runner can grade it"
        case .diskSpaceLow:
            return "less than \(Int((diskSpaceLowFreeFraction * 100).rounded()))% of the data disk is free"
        }
    }
}

/// One firing as the page draws it.
struct AdminAlertFiringRow: Encodable, Sendable {
    let rule: String
    let summary: String
    let firedAt: String
    let resolved: Bool
    /// "Delivered", "advisory, not paged", or "Delivery failed: …".
    let deliveryText: String
    let deliveryFailed: Bool
    /// The instant behind `firedAt`, for grouping by day. Not rendered.
    let occurredAt: Date

    private enum CodingKeys: String, CodingKey {
        case rule, summary, firedAt, resolved, deliveryText, deliveryFailed
    }

    /// The delivery error on one line: an unbounded error would wrap a details
    /// line that should be a phrase.
    static let errorLimit = 120

    private static func cappedError(_ error: String) -> String {
        let flat = error.replacingOccurrences(of: "\n", with: " ")
        return flat.count > errorLimit ? String(flat.prefix(errorLimit - 1)) + "…" : flat
    }

    init(_ record: AlertFiringRecord) {
        rule = record.rule
        summary = record.summary
        firedAt = record.firedAt
        resolved = record.resolved
        occurredAt = ISO8601DateFormatter().date(from: record.firedAt) ?? .distantPast
        if !record.paged {
            deliveryText = "advisory, not paged"
            deliveryFailed = false
        } else if record.delivered {
            deliveryText = "Delivered"
            deliveryFailed = false
        } else {
            deliveryText =
                record.deliveryError.map { "Delivery failed: \(Self.cappedError($0))" } ?? "Delivery failed"
            deliveryFailed = true
        }
    }
}

enum AdminAlertsPresentation {

    /// A webhook URL shortened from the middle so its host and the ends of its
    /// secret path stay readable: `hooks.slack.com/services/T04…/B07…`. The scheme
    /// is dropped. An empty URL reads "Not set".
    static func webhookDisplay(_ url: String, limit: Int = 44) -> String {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "Not set" }
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        guard text.count > limit else { return text }
        let head = limit * 2 / 3
        let tail = limit - head - 1
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    /// The most recent firing that was actually paged: when it went out and
    /// whether it arrived. Advisory firings never page, so they say nothing
    /// about the webhook.
    static func lastDelivery(
        _ firings: [AdminAlertFiringRow], records: [AlertFiringRecord]
    ) -> (
        iso: String, result: String
    )? {
        let paged = zip(firings, records).filter { $0.1.paged }
        guard let latest = paged.max(by: { $0.0.occurredAt < $1.0.occurredAt }) else { return nil }
        return (latest.0.firedAt, latest.0.deliveryFailed ? "Failed" : "Delivered")
    }
}
