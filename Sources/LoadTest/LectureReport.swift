// LoadTest/LectureReport.swift
//
// Formats a lecture run: one block per stream, then each target in the
// table of docs/load-testing.md ("Read the report"), with PASS or FAIL. A target the tool cannot measure from the client is named as
// such, so the report never reads as a pass it did not check.

struct LectureTotals: Sendable, Equatable {
    var serverErrors = 0
    var transportErrors = 0
    var signInRedirects = 0
}

enum LectureReport {
    /// The warm join target: p95 of a student's whole join.
    static let warmJoinTargetMs = 5_000.0
    /// A result visible after submit.
    static let resultVisibleTargetMs = 10_000.0

    static func streamLines(
        _ stream: LectureStream,
        summary: LatencySummary,
        byteCount: Int,
        durationSeconds: Double
    ) -> [String] {
        var lines = [stream.rawValue]
        if stream.isSpan {
            lines.append("  students:  \(summary.requestCount)")
        } else {
            let rate = Double(summary.requestCount) / max(1, durationSeconds)
            let statuses = summary.statusCounts.keys.sorted()
                .map { "\($0): \(summary.statusCounts[$0] ?? 0)" }
                .joined(separator: ", ")
            lines.append("  requests:  \(summary.requestCount) (\(LoadReport.format(rate)) per second)")
            lines.append("  statuses:  \(statuses.isEmpty ? "none" : statuses)")
            lines.append("  no reply:  \(summary.transportErrors)")
            if byteCount > 0 {
                lines.append("  received:  \(formatBytes(byteCount))")
            }
        }
        lines.append(
            "  latency:   p50 \(LoadReport.format(summary.p50Ms)) ms, p95 \(LoadReport.format(summary.p95Ms)) ms, "
                + "p99 \(LoadReport.format(summary.p99Ms)) ms, max \(LoadReport.format(summary.maxMs)) ms")
        return lines
    }

    static func targetLines(
        joinMode: JoinMode,
        join: LatencySummary,
        resultVisible: LatencySummary,
        totals: LectureTotals
    ) -> [String] {
        var lines = ["Targets"]
        switch joinMode {
        case .warm:
            lines.append(verdict("Warm join, p95 under 5 s", value: join.p95Ms, limit: warmJoinTargetMs))
        case .cold:
            lines.append(
                "  -     Warm join, p95 under 5 s: not checked, this run joined cold "
                    + "(p95 \(LoadReport.format(join.p95Ms)) ms). Run again with --join warm.")
        case .page:
            lines.append("  -     Warm join, p95 under 5 s: not checked, this run fetched no kernel files")
        }
        lines.append(
            verdict(
                "Result visible after submit, p95 under 10 s", value: resultVisible.p95Ms, limit: resultVisibleTargetMs)
        )
        let errors = totals.serverErrors + totals.transportErrors
        lines.append(
            "  \(errors == 0 ? "PASS" : "FAIL")  No server errors: \(totals.serverErrors) 5xx, "
                + "\(totals.transportErrors) with no reply")
        if totals.signInRedirects > 0 {
            lines.append(
                "  NOTE  \(totals.signInRedirects) requests were redirected: a session is not signed in "
                    + "or not enrolled. Delete the sessions file and run again.")
        }
        lines.append("  -     A change reaches the projector within 5 s: not measured by this tool")
        lines.append("  -     Database CPU under 50% while the board is watched: read it on the server host")
        return lines
    }

    static func verdict(_ name: String, value: Double?, limit: Double) -> String {
        guard let value else { return "  -     \(name): no samples" }
        let pass = value < limit
        return "  \(pass ? "PASS" : "FAIL")  \(name) (p95 \(LoadReport.format(value)) ms)"
    }

    static func formatBytes(_ bytes: Int) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes >= 1_000 { return "\(LoadReport.format(megabytes / 1_000)) GB" }
        if megabytes >= 1 { return "\(LoadReport.format(megabytes)) MB" }
        return "\(bytes) bytes"
    }
}
