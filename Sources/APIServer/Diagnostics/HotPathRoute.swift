/// The request routes with the most traffic. The server does not persist a
/// `request_metrics` row for their routine successes (see
/// `shouldCaptureRequest`), so `HotPathRequestStats` counts them in memory.
///
/// The raw value is the normalized route shape. It holds no identifier, so
/// the admin surfaces can report it as is.
enum HotPathRoute: String, CaseIterable, Codable, Sendable {
    /// Each runner slot polls for a job. An idle slot's poll is held for up
    /// to 20 s (`WorkerLongPoll`); its timing leaves the hold out.
    case workerPoll = "POST /api/v1/worker/request"
    /// Each runner sends a heartbeat while it runs a job.
    case workerHeartbeat = "POST /api/v1/worker/heartbeat"
    /// The result view polls every 2 s while a submission is pending.
    case submissionStatusPoll = "GET /api/v1/submissions/:id"
    /// A live class activity's board: every viewer and the projector refresh
    /// it every 5 s, so a lecture of 150 sends about 30 a second
    /// (docs/live-board-cache.md). The page load shares the path, and only a
    /// 304 is routine.
    case leaderboardRefresh = "GET /testsetups/:id/leaderboard"

    init?(method: String, path: String) {
        switch (method, path) {
        case ("POST", "/api/v1/worker/request"):
            self = .workerPoll
        case ("POST", "/api/v1/worker/heartbeat"):
            self = .workerHeartbeat
        case ("GET", _):
            if Self.isLeaderboardPath(path) {
                self = .leaderboardRefresh
                return
            }
            let prefix = "/api/v1/submissions/"
            guard path.hasPrefix(prefix) else { return nil }
            let remainder = path.dropFirst(prefix.count)
            guard !remainder.isEmpty, !remainder.contains("/") else { return nil }
            self = .submissionStatusPoll
        default:
            return nil
        }
    }

    /// True for the responses that do not persist a `request_metrics` row:
    /// an idle poll (204, no job), a healthy heartbeat, a successful status
    /// poll and a board refresh answered 304. A real dispatch (200), a board
    /// that was built (200) and every error still persist one.
    func isRoutineSuccess(statusCode: Int) -> Bool {
        switch self {
        case .workerPoll: return statusCode == 204
        case .workerHeartbeat, .submissionStatusPoll: return statusCode < 400
        // A board that was built (200) still persists its row, so a slow
        // build of any board kind, and the page load, stay in the request
        // metrics. The 304s are the bulk of a lecture's refreshes.
        case .leaderboardRefresh: return statusCode == 304
        }
    }

    /// `/testsetups/<id>/leaderboard` and nothing below it.
    private static func isLeaderboardPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0].isEmpty && parts[1] == "testsetups" && !parts[2].isEmpty
            && parts[3] == "leaderboard"
    }
}
