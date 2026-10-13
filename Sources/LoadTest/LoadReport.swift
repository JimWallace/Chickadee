// LoadTest/LoadReport.swift
//
// Formats one scenario's summary for the terminal.

enum LoadReport {
    static func lines(for scenario: LoadScenario, summary: LatencySummary, durationSeconds: Int) -> [String] {
        let rate = Double(summary.requestCount) / Double(max(1, durationSeconds))
        let statuses = summary.statusCounts.keys.sorted()
            .map { "\($0): \(summary.statusCounts[$0] ?? 0)" }
            .joined(separator: ", ")
        var lines = [
            scenario.rawValue,
            "  requests:  \(summary.requestCount) (\(format(rate)) per second)",
            "  statuses:  \(statuses.isEmpty ? "none" : statuses)",
            "  no reply:  \(summary.transportErrors)",
            "  latency:   p50 \(format(summary.p50Ms)) ms, p95 \(format(summary.p95Ms)) ms, "
                + "p99 \(format(summary.p99Ms)) ms, max \(format(summary.maxMs)) ms",
        ]
        if scenario == .runnerPoll, let claimed = summary.statusCounts[200], claimed > 0 {
            lines.append(
                "  WARNING:   \(claimed) polls claimed a real job. That job stays assigned to a "
                    + "simulated runner until the server times it out.")
        }
        if let unauthorized = summary.statusCounts[401], unauthorized > 0 {
            lines.append(
                scenario == .runnerPoll
                    ? "  NOTE:      401 means the runner secret does not match the server."
                    : "  NOTE:      401 means the session cookie is not signed in.")
        }
        return lines
    }

    static func format(_ value: Double?) -> String {
        guard let value else { return "-" }
        return format(value)
    }

    static func format(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        return tenths == tenths.rounded() ? String(Int(tenths)) : String(tenths)
    }
}
