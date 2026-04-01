import Foundation

enum RunnerRetryStage: String, Sendable {
    case poll
    case heartbeat
    case downloadSubmission = "download_submission"
    case downloadTestSetup = "download_testsetup"
    case resultUpload = "result_upload"
}

enum RetryDisposition: Equatable, Sendable {
    case retryable(String)
    case terminal(String)
}

struct RunnerRetryPolicy: Sendable {
    let enabled: Bool
    let maxAttempts: Int
    let baseDelayMs: Int
    let maxDelayMs: Int

    static func poll() -> Self {
        Self(
            enabled: runnerEnvironmentBool("RUNNER_NETWORK_RETRY_ENABLED", default: true),
            maxAttempts: Int.max,
            baseDelayMs: runnerEnvironmentInt("RUNNER_RETRY_BASE_DELAY_MS", default: 1000),
            maxDelayMs: runnerEnvironmentInt("RUNNER_RETRY_MAX_DELAY_MS", default: 30_000)
        )
    }

    static func heartbeat() -> Self {
        Self(
            enabled: runnerEnvironmentBool("RUNNER_NETWORK_RETRY_ENABLED", default: true),
            maxAttempts: runnerEnvironmentInt("RUNNER_HEARTBEAT_RETRY_MAX_ATTEMPTS", default: 4),
            baseDelayMs: runnerEnvironmentInt("RUNNER_RETRY_BASE_DELAY_MS", default: 1000),
            maxDelayMs: runnerEnvironmentInt("RUNNER_RETRY_MAX_DELAY_MS", default: 30_000)
        )
    }

    static func resultUpload() -> Self {
        Self(
            enabled: runnerEnvironmentBool("RUNNER_NETWORK_RETRY_ENABLED", default: true),
            maxAttempts: runnerEnvironmentInt("RUNNER_RESULT_UPLOAD_RETRY_MAX_ATTEMPTS", default: 8),
            baseDelayMs: runnerEnvironmentInt("RUNNER_RETRY_BASE_DELAY_MS", default: 1000),
            maxDelayMs: runnerEnvironmentInt("RUNNER_RETRY_MAX_DELAY_MS", default: 30_000)
        )
    }

    static func download() -> Self {
        Self(
            enabled: runnerEnvironmentBool("RUNNER_NETWORK_RETRY_ENABLED", default: true),
            maxAttempts: runnerEnvironmentInt("RUNNER_DOWNLOAD_RETRY_MAX_ATTEMPTS", default: 6),
            baseDelayMs: runnerEnvironmentInt("RUNNER_RETRY_BASE_DELAY_MS", default: 1000),
            maxDelayMs: runnerEnvironmentInt("RUNNER_RETRY_MAX_DELAY_MS", default: 30_000)
        )
    }

    func delay(forAttempt attempt: Int) -> Duration {
        guard enabled else { return .zero }
        let exponent = max(0, attempt - 1)
        let scaled = min(
            maxDelayMs,
            max(baseDelayMs, baseDelayMs * Int(pow(2.0, Double(min(exponent, 8)))))
        )
        let jitterUpperBound = max(1, scaled / 4)
        let jitter = Int.random(in: 0..<jitterUpperBound)
        return .milliseconds(min(maxDelayMs, scaled + jitter))
    }
}

struct RunnerRetryContext: Sendable {
    let stage: RunnerRetryStage
    let attempt: Int
    let maxAttempts: Int
    let retryInSeconds: Int?
    let message: String
    let retryable: Bool
}

func classifyHTTPRetry(statusCode: Int, body: String) -> RetryDisposition {
    switch statusCode {
    case 401, 403:
        return .terminal("HTTP \(statusCode): \(body)")
    case 409:
        return .terminal("HTTP 409: \(body)")
    case 502, 503, 504:
        return .retryable("HTTP \(statusCode): \(body)")
    default:
        return .terminal("HTTP \(statusCode): \(body)")
    }
}

func withRunnerRetry<T>(
    stage: RunnerRetryStage,
    policy: RunnerRetryPolicy,
    shouldRetry: @escaping @Sendable (Error) -> RetryDisposition,
    onRetry: @escaping @Sendable (RunnerRetryContext) async -> Void = { _ in },
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    var lastError: Error?

    for attempt in 1...max(1, policy.maxAttempts) {
        do {
            return try await operation()
        } catch {
            lastError = error
            let disposition = shouldRetry(error)
            switch disposition {
            case .terminal:
                throw error
            case .retryable(let message):
                guard policy.enabled, attempt < policy.maxAttempts else {
                    throw error
                }
                let delay = policy.delay(forAttempt: attempt)
                let retrySeconds = max(1, Int(delay.components.seconds))
                await onRetry(
                    RunnerRetryContext(
                        stage: stage,
                        attempt: attempt,
                        maxAttempts: policy.maxAttempts,
                        retryInSeconds: retrySeconds,
                        message: message,
                        retryable: true
                    )
                )
                try await Task.sleep(for: delay)
            }
        }
    }

    throw lastError ?? CancellationError()
}

func runnerEnvironmentInt(_ key: String, default defaultValue: Int) -> Int {
    guard let raw = ProcessInfo.processInfo.environment[key]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        let value = Int(raw) else {
        return defaultValue
    }
    return value
}
