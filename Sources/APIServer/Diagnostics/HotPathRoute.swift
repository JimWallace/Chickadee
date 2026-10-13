/// The request routes with the most traffic. The server does not persist a
/// `request_metrics` row for their routine successes (see
/// `shouldCaptureRequest`), so `HotPathRequestStats` counts them in memory.
///
/// The raw value is the normalized route shape. It holds no identifier, so
/// the admin surfaces can report it as is.
enum HotPathRoute: String, CaseIterable, Codable, Sendable {
    /// Each runner slot polls for a job, with a backoff of up to 30 s.
    case workerPoll = "POST /api/v1/worker/request"
    /// Each runner sends a heartbeat while it runs a job.
    case workerHeartbeat = "POST /api/v1/worker/heartbeat"
    /// The result view polls every 2 s while a submission is pending.
    case submissionStatusPoll = "GET /api/v1/submissions/:id"

    init?(method: String, path: String) {
        switch (method, path) {
        case ("POST", "/api/v1/worker/request"):
            self = .workerPoll
        case ("POST", "/api/v1/worker/heartbeat"):
            self = .workerHeartbeat
        case ("GET", _):
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
    /// an idle poll (204, no job), a healthy heartbeat and a successful
    /// status poll. A real dispatch (200) and every error still persist one.
    func isRoutineSuccess(statusCode: Int) -> Bool {
        switch self {
        case .workerPoll: return statusCode == 204
        case .workerHeartbeat, .submissionStatusPoll: return statusCode < 400
        }
    }
}
