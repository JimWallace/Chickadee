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

    static func poll(config: RunnerDaemonConfig = .loadFromEnvironment()) -> Self {
        Self(
            enabled: config.networkRetryEnabled,
            maxAttempts: Int.max,
            baseDelayMs: config.retryBaseDelayMs,
            maxDelayMs: config.retryMaxDelayMs
        )
    }

    static func heartbeat(config: RunnerDaemonConfig = .loadFromEnvironment()) -> Self {
        Self(
            enabled: config.networkRetryEnabled,
            maxAttempts: config.heartbeatRetryMaxAttempts,
            baseDelayMs: config.retryBaseDelayMs,
            maxDelayMs: config.retryMaxDelayMs
        )
    }

    static func resultUpload(config: RunnerDaemonConfig = .loadFromEnvironment()) -> Self {
        Self(
            enabled: config.networkRetryEnabled,
            maxAttempts: config.resultUploadRetryMaxAttempts,
            baseDelayMs: config.retryBaseDelayMs,
            maxDelayMs: config.retryMaxDelayMs
        )
    }

    static func download(config: RunnerDaemonConfig = .loadFromEnvironment()) -> Self {
        Self(
            enabled: config.networkRetryEnabled,
            maxAttempts: config.downloadRetryMaxAttempts,
            baseDelayMs: config.retryBaseDelayMs,
            maxDelayMs: config.retryMaxDelayMs
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
    case 408, 425, 429, 500, 502, 503, 504:
        return .retryable("HTTP \(statusCode): \(body)")
    case 409:
        return .terminal("HTTP 409: \(body)")
    default:
        return .terminal("HTTP \(statusCode): \(body)")
    }
}

func classifyPollHTTPRetry(statusCode: Int, body: String) -> RetryDisposition {
    switch statusCode {
    case 401, 403:
        // Keep polling through auth reconfiguration windows so long-lived
        // runners recover automatically once the server-side state is fixed.
        return .retryable("HTTP \(statusCode): \(body)")
    default:
        return classifyHTTPRetry(statusCode: statusCode, body: body)
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

struct ExponentialBackoff {
    private let initial: Duration
    private let max: Duration
    private var current: Duration

    init(initial: Duration, max: Duration) {
        self.initial = initial
        self.max = max
        self.current = initial
    }

    mutating func next() -> Duration {
        let doubled = min(current.secondsValue * 2, max.secondsValue)
        current = Duration.milliseconds(Int64((doubled * 1000).rounded()))
        // Lower bound is the initial interval so next() never returns zero,
        // which would defeat the purpose of backing off.
        let lo = initial.secondsValue
        let hi = Swift.max(lo, doubled)
        return Duration.milliseconds(Int64((Double.random(in: lo...hi) * 1000).rounded()))
    }

    mutating func reset() {
        current = initial
    }

    fileprivate static func secondsValue(of duration: Duration) -> Double {
        Double(duration.components.seconds) + (Double(duration.components.attoseconds) / 1_000_000_000_000_000_000)
    }
}

private extension Duration {
    var secondsValue: Double {
        ExponentialBackoff.secondsValue(of: self)
    }
}
