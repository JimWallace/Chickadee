import Foundation
import Vapor

/// Counts every request on a `HotPathRoute` in memory: since the process
/// started, and per minute over a rolling window.
///
/// The routine successes on these routes do not persist a `request_metrics`
/// row, because one INSERT per poll is the write load the 2026-07 audit
/// removed. Without this store, the routes with the most traffic have no
/// count and no latency. The counts are per process and start again at zero
/// when the process restarts, for example at each blue-green deploy.
actor HotPathRequestStats {
    static let windowMinutes = 60

    private let startedAt: Date
    private var sinceStart: [HotPathRoute: LatencyHistogram] = [:]
    /// Keyed by the minute since the epoch. Holds at most `windowMinutes`
    /// entries per route.
    private var perMinute: [HotPathRoute: [Int: LatencyHistogram]] = [:]
    private var latestMinute: Int?

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    func record(route: HotPathRoute, durationMs: Int, statusCode: Int, at date: Date) {
        let isError = statusCode >= 400
        sinceStart[route, default: LatencyHistogram()].record(durationMs: durationMs, isError: isError)

        // A request that finished late can carry a minute that is already
        // out of the window. It counts since start, but not per minute.
        let minute = Self.minute(of: date)
        let newestMinute = max(minute, latestMinute ?? minute)
        latestMinute = newestMinute
        let oldestKept = newestMinute - Self.windowMinutes + 1
        guard minute >= oldestKept else { return }

        // Mutate in place: a copy of the per-minute dictionary on each
        // request would cost more than the count itself.
        if perMinute[route]?[minute] == nil {
            let staleMinutes = perMinute[route]?.keys.filter { $0 < oldestKept } ?? []
            for stale in staleMinutes {
                perMinute[route]?.removeValue(forKey: stale)
            }
        }
        perMinute[route, default: [:]][minute, default: LatencyHistogram()]
            .record(durationMs: durationMs, isError: isError)
    }

    func snapshot(now: Date) -> HotPathStatsResponse {
        let oldestKept = Self.minute(of: now) - Self.windowMinutes + 1
        let routes = HotPathRoute.allCases.map { route in
            let window = (perMinute[route] ?? [:]).filter { $0.key >= oldestKept }
            var windowTotal = LatencyHistogram()
            for histogram in window.values {
                windowTotal.merge(histogram)
            }
            return HotPathRouteStatsResponse(
                route: route.rawValue,
                sinceStart: HotPathLatencySummaryResponse(sinceStart[route] ?? LatencyHistogram()),
                lastWindow: HotPathLatencySummaryResponse(windowTotal),
                peakRequestsPerMinute: window.values.map(\.requestCount).max() ?? 0
            )
        }
        return HotPathStatsResponse(
            countingSince: startedAt,
            windowMinutes: Self.windowMinutes,
            routes: routes
        )
    }

    private static func minute(of date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded(.down))
    }
}
