import Core
import Foundation

/// Which server process sent an alert.
///
/// An alert's `serverURL` is the same for every process on a host, so it
/// cannot tell the live blue-green color from a server nginx sends no traffic
/// to. In Sept 2026 a `runnerMissing` page named two runners that the live
/// server saw polling every 30 seconds, and nothing in the message said which
/// process had sent it. Every alert now carries the sender's container
/// hostname, version and boot time, in `details` and in the Slack `text`.
struct AlertSender: Sendable, Equatable {
    let host: String
    let version: String
    let startedAt: Date

    /// This process.
    static func current(startedAt: Date) -> Self {
        Self(host: ProcessInfo.processInfo.hostName, version: ChickadeeVersion.current, startedAt: startedAt)
    }

    var details: [String: String] {
        [
            "server_host": host,
            "server_version": version,
            "server_started_at": ISO8601DateFormatter().string(from: startedAt),
        ]
    }

    /// The one line Slack, Discord, ntfy and Pushover show.
    func text(summary: String) -> String {
        "[Chickadee] \(summary) (from \(host), v\(version))"
    }
}
