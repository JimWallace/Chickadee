// APIServer/Utilities/AssetLoadStats.swift
//
// Folds the `asset_load` breadcrumbs (Public/kernel-asset-telemetry.js) into
// the cold-load numbers `get_browser_diagnostics` reports: per source and per
// day, how many kernel boots were cold, and how many bytes came over the
// network versus from the browser cache.
//
// A breadcrumb's message is `key=value` pairs joined by `;`:
//   cold=1|0     any kernel boot file came over the network (absent: unknown)
//   net_bytes    bytes of kernel boot files fetched over the network
//   cache_bytes  bytes of kernel boot files read from the HTTP cache
//   shell_net_bytes / shell_cache_bytes
//                the same for the JupyterLite shell (editor only)
//   boot_ms      kernel boot duration (editor: boot_start to idle;
//                grading: worker boot); warm_ms for a pre-warm
// Unknown keys are ignored and a malformed value reads as absent, so an old
// page build never breaks the report.

import Foundation

/// The cold-load totals for one group of `asset_load` breadcrumbs.
struct AssetLoadStats: Encodable, Sendable, Equatable {
    /// "editor" | "grading" | "prewarm", or a day ("2026-11-09") in `byDay`.
    let key: String
    let loads: Int
    let coldLoads: Int
    /// Loads whose page could not tell (the cache probe is unsupported).
    let unknownLoads: Int
    /// coldLoads / (loads − unknownLoads), rounded to 3 places; nil with no
    /// known loads.
    let coldShare: Double?
    let networkBytes: Int
    let cachedBytes: Int
    let shellNetworkBytes: Int
    let shellCachedBytes: Int
    /// Median and 90th-percentile boot duration, over the loads that sent one.
    let bootMsMedian: Int?
    let bootMsP90: Int?

    /// One breadcrumb's fields.
    struct Sample: Sendable, Equatable {
        var cold: Bool?
        var networkBytes = 0
        var cachedBytes = 0
        var shellNetworkBytes = 0
        var shellCachedBytes = 0
        var bootMs: Int?

        init(cold: Bool? = nil, networkBytes: Int = 0, cachedBytes: Int = 0, bootMs: Int? = nil) {
            self.cold = cold
            self.networkBytes = networkBytes
            self.cachedBytes = cachedBytes
            self.bootMs = bootMs
        }

        /// Parses a breadcrumb message. Never fails.
        init(message: String?) {
            var fields: [String: String] = [:]
            for pair in (message ?? "").split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                fields[String(parts[0])] = String(parts[1])
            }
            func count(_ key: String) -> Int? {
                fields[key].flatMap { Int($0) }.map { max(0, $0) }
            }
            switch fields["cold"] {
            case "1": cold = true
            case "0": cold = false
            default: cold = nil
            }
            networkBytes = count("net_bytes") ?? 0
            cachedBytes = count("cache_bytes") ?? 0
            shellNetworkBytes = count("shell_net_bytes") ?? 0
            shellCachedBytes = count("shell_cache_bytes") ?? 0
            bootMs = count("boot_ms") ?? count("warm_ms")
        }
    }

    /// Totals for one group.
    static func fold(key: String, samples: [Sample]) -> AssetLoadStats {
        let known = samples.filter { $0.cold != nil }
        let cold = known.count { $0.cold == true }
        let boots = samples.compactMap(\.bootMs).sorted()
        let share: Double? =
            known.isEmpty ? nil : (Double(cold) / Double(known.count) * 1000).rounded() / 1000
        return AssetLoadStats(
            key: key,
            loads: samples.count,
            coldLoads: cold,
            unknownLoads: samples.count - known.count,
            coldShare: share,
            networkBytes: samples.reduce(0) { $0 + $1.networkBytes },
            cachedBytes: samples.reduce(0) { $0 + $1.cachedBytes },
            shellNetworkBytes: samples.reduce(0) { $0 + $1.shellNetworkBytes },
            shellCachedBytes: samples.reduce(0) { $0 + $1.shellCachedBytes },
            bootMsMedian: percentile(boots, 0.5),
            bootMsP90: percentile(boots, 0.9))
    }

    /// Nearest-rank percentile of an ascending list; nil when empty.
    static func percentile(_ sorted: [Int], _ fraction: Double) -> Int? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// Groups (source, message) breadcrumbs by source, highest load count first.
    static func bySource(_ rows: [(source: String?, message: String?)]) -> [AssetLoadStats] {
        let grouped = Dictionary(grouping: rows) { $0.source ?? "unknown" }
        return grouped.map { fold(key: $0.key, samples: $0.value.map { Sample(message: $0.message) }) }
            .sorted { ($0.loads, $1.key) > ($1.loads, $0.key) }
    }

    /// Groups (day, message) breadcrumbs by day, oldest first. The caller
    /// passes the day already formatted, so the time zone is its choice.
    static func byDay(_ rows: [(day: String, message: String?)]) -> [AssetLoadStats] {
        let grouped = Dictionary(grouping: rows, by: \.day)
        return grouped.map { fold(key: $0.key, samples: $0.value.map { Sample(message: $0.message) }) }
            .sorted { $0.key < $1.key }
    }
}
