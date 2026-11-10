// APIServer/Services/RunnerMissingRule.swift
//
import Core
import Fluent
import Foundation
import Logging
import SQLKit

// The runner-missing rule: one named runner stopped polling.
//
// `runnerOffline` answers a different question — "is ANY runner checking in?" —
// and reads the in-memory activity store, which forgets a runner after an hour
// and forgets every runner when the server restarts. In Sept 2026 the runner on
// `sparrow` lost its network for several days: other runners kept polling, so
// `runnerOffline` stayed green, and daily deploys erased the server's memory of
// `sparrow` long before anyone looked. This rule reads the persisted
// `runner_snapshots` table instead, so a runner is remembered across restarts
// for `runnerMissingRememberSeconds`.

/// How long the runner-missing rule remembers a runner after its last check-in.
/// A runner retired on purpose stops firing the rule after this time.
let runnerMissingRememberSeconds: TimeInterval = 7 * 24 * 3600

/// True for the ID the bundled `docker-compose.yml` gives a runner when
/// `RUNNER_WORKER_ID` is not set: `runner-` plus the 12-hex container hostname.
/// That ID changes each time the container is created again, so the old ID
/// going quiet is a replacement, not an outage. The rule ignores these IDs.
func isGeneratedRunnerID(_ runnerID: String) -> Bool {
    let prefix = "runner-"
    guard runnerID.hasPrefix(prefix) else { return false }
    let suffix = runnerID.dropFirst(prefix.count)
    return suffix.count == 12 && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }
}

/// Decides the runner-missing rule from each runner's last check-in. Fires when
/// a runner with a stable ID was seen within `rememberSeconds` but not within
/// `offlineSeconds`.
func decideRunnersMissing(
    lastSeenByRunner: [String: Date],
    offlineSeconds: TimeInterval,
    rememberSeconds: TimeInterval = runnerMissingRememberSeconds,
    now: Date
) -> RuleEvaluation {
    let missing =
        lastSeenByRunner
        .filter { runnerID, lastSeen in
            let age = now.timeIntervalSince(lastSeen)
            return !isGeneratedRunnerID(runnerID) && age > offlineSeconds && age <= rememberSeconds
        }
        .sorted { $0.key < $1.key }
    guard !missing.isEmpty else { return .ok }

    let described = missing.map { runnerID, lastSeen in
        "\(runnerID) for \(formatQuietDuration(now.timeIntervalSince(lastSeen)))"
    }
    let summary = "Runners not polling: \(described.joined(separator: ", "))"
    // The absolute time, beside the relative one in the summary: a quiet time
    // that grows by exactly the cooldown on every page means the sender reads a
    // FIXED last-seen time, and only the absolute value can be compared against
    // what the live server's database says.
    let lastSeen = missing.map { runnerID, lastSeen in "\(runnerID) \(iso8601String(lastSeen))" }
    return RuleEvaluation(
        isFiring: true,
        summary: summary,
        details: [
            "missing_runners": missing.map(\.key).joined(separator: ", "),
            "last_seen": lastSeen.joined(separator: ", "),
            "runner_offline_threshold_seconds": String(Int(offlineSeconds)),
        ]
    )
}

/// The rule as the sweep runs it. A failed read stays green, but it is logged:
/// `try?` alone made "the query failed" and "every runner polled" the same
/// silent answer. The loader is a parameter so a test can make it throw.
func evaluateRunnerMissing(
    loadLastSeen: () async throws -> [String: Date],
    offlineSeconds: TimeInterval,
    now: Date,
    logger: Logger
) async -> RuleEvaluation {
    do {
        return decideRunnersMissing(
            lastSeenByRunner: try await loadLastSeen(),
            offlineSeconds: offlineSeconds,
            now: now
        )
    } catch {
        logger.warning(
            "health_rule_evaluation_failed",
            metadata: [
                "rule": .string(HealthRule.runnerMissing.rawValue),
                "error": .string(String(describing: error)),
            ])
        return .ok
    }
}

/// "45m", "3h 20m", "5d 13h": short enough for an alert summary line.
func formatQuietDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds) / 60
    let hours = minutes / 60
    let days = hours / 24
    if days > 0 { return "\(days)d \(hours % 24)h" }
    if hours > 0 { return "\(hours)h \(minutes % 60)m" }
    return "\(minutes)m"
}

/// The newest `runner_snapshots.recorded_at` per runner, for runners with a
/// row inside the remember window. Empty when diagnostics are disabled (no
/// rows are written), which keeps the rule green rather than guessing.
func loadRunnerLastSeen(on db: any Database, now: Date) async throws -> [String: Date] {
    let cutoff = now.addingTimeInterval(-runnerMissingRememberSeconds)
    guard let sql = db as? (any SQLDatabase) else {
        let rows = try await RunnerSnapshot.query(on: db)
            .filter(\.$recordedAt >= cutoff)
            .all()
        return rows.reduce(into: [:]) { result, row in
            result[row.runnerID] = max(result[row.runnerID] ?? row.recordedAt, row.recordedAt)
        }
    }
    // A loose index scan over `idx_runner_snapshots_runner_recorded_at`: the
    // recursive part steps from one runner ID to the next, and each runner's
    // newest row is one probe. A GROUP BY over the window reads every
    // snapshot of the last week (one row per runner per 30 s) to answer one
    // row per runner, and Postgres 16 has no skip scan. A runner has a row at
    // or after the cutoff exactly when its newest row is, and that row is then
    // the newest in the window, so the answer is the one that
    // `MAX(recorded_at) ... WHERE recorded_at >= cutoff GROUP BY runner_id`
    // gives.
    let rows = try await sql.raw(
        """
        WITH RECURSIVE runners(runner_id) AS (
            (SELECT runner_id FROM \(unsafeRaw: RunnerSnapshot.schema) ORDER BY runner_id LIMIT 1)
            UNION ALL
            SELECT (
                SELECT s.runner_id FROM \(unsafeRaw: RunnerSnapshot.schema) s
                WHERE s.runner_id > runners.runner_id
                ORDER BY s.runner_id LIMIT 1
            )
            FROM runners WHERE runners.runner_id IS NOT NULL
        )
        SELECT runner_id, last_seen FROM (
            SELECT runners.runner_id, (
                SELECT MAX(s.recorded_at) FROM \(unsafeRaw: RunnerSnapshot.schema) s
                WHERE s.runner_id = runners.runner_id
            ) AS last_seen
            FROM runners WHERE runners.runner_id IS NOT NULL
        ) newest
        WHERE last_seen >= \(bind: cutoff)
        """
    ).all(decoding: RunnerLastSeenRow.self)
    return rows.reduce(into: [:]) { $0[$1.runnerID] = $1.lastSeen }
}

private struct RunnerLastSeenRow: Decodable {
    let runnerID: String
    let lastSeen: Date

    enum CodingKeys: String, CodingKey {
        case runnerID = "runner_id"
        case lastSeen = "last_seen"
    }
}
