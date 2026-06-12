// Tests/WorkerTests/RunnerNetworkResilienceTests.swift
//
// Unit tests for the retry-classification + backoff helpers in
// `Sources/Worker/RunnerNetworkResilience.swift`.  Coverage prior to
// this file was indirect — the Reporter and JobPoller suites exercise
// the helpers through the full HTTP stack, but the classifier itself
// (the heart of the runner's retry policy) only had two sanity cases
// in WorkerTests.  This file closes that gap with pure-function unit
// tests so individual status-code behaviours don't have to be inferred
// from end-to-end HTTP stubs.

import Testing

@testable import chickadee_runner

@Suite struct RunnerNetworkResilienceTests {

    // MARK: - classifyHTTPRetry

    @Test func classifyHTTPRetryMarksGatewayErrorsRetryable() {
        for code in [500, 502, 503, 504] {
            #expect(
                classifyHTTPRetry(statusCode: code, body: "x") == .retryable("HTTP \(code): x"),
                "expected \(code) to be retryable")
        }
    }

    @Test func classifyHTTPRetryMarksRateLimitAndTimeoutCodesRetryable() {
        for code in [408, 425, 429] {
            #expect(
                classifyHTTPRetry(statusCode: code, body: "rl") == .retryable("HTTP \(code): rl"),
                "expected \(code) to be retryable")
        }
    }

    @Test func classifyHTTPRetryTerminatesOnAuthFailures() {
        #expect(classifyHTTPRetry(statusCode: 401, body: "unauth") == .terminal("HTTP 401: unauth"))
        #expect(classifyHTTPRetry(statusCode: 403, body: "forbidden") == .terminal("HTTP 403: forbidden"))
    }

    @Test func classifyHTTPRetryTerminatesOnConflict() {
        // 409 — duplicate worker ID claim — is terminal so the worker
        // can re-roll its ID rather than spin.
        #expect(classifyHTTPRetry(statusCode: 409, body: "duplicate worker") == .terminal("HTTP 409: duplicate worker"))
    }

    @Test func classifyHTTPRetryTerminatesOnUnknownClientErrors() {
        // 400-range responses other than the explicitly retryable codes
        // are treated as client bugs — no point retrying.
        for code in [400, 404, 422] {
            #expect(
                classifyHTTPRetry(statusCode: code, body: "bad") == .terminal("HTTP \(code): bad"),
                "expected \(code) to be terminal")
        }
    }

    // MARK: - classifyPollHTTPRetry

    @Test func classifyPollHTTPRetryUpgrades401And403ToRetryable() {
        // Poll-path-specific: long-lived runners should recover through
        // server-side auth reconfiguration windows rather than terminating.
        #expect(
            classifyPollHTTPRetry(statusCode: 401, body: "rotating-secret") == .retryable("HTTP 401: rotating-secret"))
        #expect(classifyPollHTTPRetry(statusCode: 403, body: "tmp") == .retryable("HTTP 403: tmp"))
    }

    @Test func classifyPollHTTPRetryDelegatesNonAuthCodesToBaseClassifier() {
        // Everything except 401/403 falls through to the standard
        // classifier — confirm by spot-checking a retryable and a terminal.
        #expect(classifyPollHTTPRetry(statusCode: 503, body: "down") == .retryable("HTTP 503: down"))
        #expect(classifyPollHTTPRetry(statusCode: 409, body: "dup") == .terminal("HTTP 409: dup"))
    }

    // MARK: - withRunnerRetry

    /// Fast policy with no real wall-clock sleeping: 1 ms base, 2 ms cap.
    /// Tests using this policy still cost a few ms per retry, which is
    /// acceptable for ≤ 4 retries.
    private func fastPolicy(maxAttempts: Int = 3, enabled: Bool = true) -> RunnerRetryPolicy {
        RunnerRetryPolicy(
            enabled: enabled,
            maxAttempts: maxAttempts,
            baseDelayMs: 1,
            maxDelayMs: 2
        )
    }

    private struct StubError: Error {}

    @Test func withRunnerRetryReturnsImmediatelyOnSuccess() async throws {
        actor Counter { var n = 0; func incr() { n += 1 } }
        let calls = Counter()

        let result: Int = try await withRunnerRetry(
            stage: .heartbeat,
            policy: fastPolicy(),
            shouldRetry: { _ in .retryable("never reached") },
            operation: {
                await calls.incr()
                return 42
            }
        )

        #expect(result == 42)
        let n = await calls.n
        #expect(n == 1, "operation should run exactly once on success")
    }

    @Test func withRunnerRetryRetriesUntilSuccess() async throws {
        actor Counter { var n = 0; func incr() { n += 1 }; func value() -> Int { n } }
        let calls = Counter()

        let result: Int = try await withRunnerRetry(
            stage: .heartbeat,
            policy: fastPolicy(maxAttempts: 5),
            shouldRetry: { _ in .retryable("transient") },
            operation: {
                await calls.incr()
                if await calls.value() < 3 { throw StubError() }
                return 7
            }
        )

        #expect(result == 7)
        let n = await calls.n
        #expect(n == 3, "operation should run until the 3rd attempt succeeds")
    }

    @Test func withRunnerRetryShortCircuitsOnTerminalDisposition() async {
        actor Counter { var n = 0; func incr() { n += 1 } }
        let calls = Counter()

        do {
            let _: Int = try await withRunnerRetry(
                stage: .heartbeat,
                policy: fastPolicy(maxAttempts: 5),
                shouldRetry: { _ in .terminal("never retry") },
                operation: {
                    await calls.incr()
                    throw StubError()
                }
            )
            Issue.record("expected StubError to be thrown")
        } catch is StubError {
            // expected
        } catch {
            Issue.record("expected StubError, got \(error)")
        }

        let n = await calls.n
        #expect(n == 1, "terminal disposition must not trigger a retry")
    }

    @Test func withRunnerRetryRespectsMaxAttemptsAndRethrows() async {
        actor Counter { var n = 0; func incr() { n += 1 } }
        let calls = Counter()

        do {
            let _: Int = try await withRunnerRetry(
                stage: .heartbeat,
                policy: fastPolicy(maxAttempts: 3),
                shouldRetry: { _ in .retryable("forever") },
                operation: {
                    await calls.incr()
                    throw StubError()
                }
            )
            Issue.record("expected the operation to exhaust its retries")
        } catch is StubError {
            // expected
        } catch {
            Issue.record("expected StubError, got \(error)")
        }

        let n = await calls.n
        #expect(n == 3, "operation should run exactly maxAttempts times")
    }

    @Test func withRunnerRetryThrowsImmediatelyWhenPolicyDisabled() async {
        actor Counter { var n = 0; func incr() { n += 1 } }
        let calls = Counter()

        do {
            let _: Int = try await withRunnerRetry(
                stage: .heartbeat,
                policy: fastPolicy(maxAttempts: 5, enabled: false),
                shouldRetry: { _ in .retryable("transient") },
                operation: {
                    await calls.incr()
                    throw StubError()
                }
            )
            Issue.record("expected throw")
        } catch is StubError {
            // expected
        } catch {
            Issue.record("expected StubError, got \(error)")
        }

        let n = await calls.n
        #expect(n == 1, "policy.enabled=false should disable retry entirely")
    }

    @Test func withRunnerRetryInvokesOnRetryForEachRetryButNotForFinalThrow() async {
        actor RetryLog {
            var contexts: [RunnerRetryContext] = []
            func append(_ c: RunnerRetryContext) { contexts.append(c) }
            func snapshot() -> [RunnerRetryContext] { contexts }
        }
        let log = RetryLog()

        do {
            let _: Int = try await withRunnerRetry(
                stage: .resultUpload,
                policy: fastPolicy(maxAttempts: 3),
                shouldRetry: { _ in .retryable("try again") },
                onRetry: { ctx in await log.append(ctx) },
                operation: { throw StubError() }
            )
            Issue.record("expected throw")
        } catch is StubError {
            // expected
        } catch {
            Issue.record("expected StubError, got \(error)")
        }

        let recorded = await log.snapshot()
        // 3 attempts total → 2 retries scheduled before the final throw.
        #expect(recorded.count == 2)
        #expect(recorded.map(\.attempt) == [1, 2])
        #expect(recorded.map(\.stage) == [.resultUpload, .resultUpload])
        #expect(recorded.map(\.message) == ["try again", "try again"])
        let allRetryable = recorded.allSatisfy(\.retryable)
        #expect(allRetryable)
    }

    // MARK: - ExponentialBackoff

    // Note: there is no "monotonic non-decreasing" test for ExponentialBackoff.
    // `next()` returns a value in `[initial, currentCappedDoubled]` — the
    // *upper bound* grows on each call (until it hits the cap), but the
    // jittered return value can be smaller than the previous draw.  The
    // tests below pin what callers actually rely on: bounded delay,
    // never-zero so the loop doesn't spin, and a working reset.

    @Test func exponentialBackoffStaysWithinCap() {
        var backoff = ExponentialBackoff(
            initial: .milliseconds(10),
            max: .milliseconds(50)
        )
        // Burn enough iterations that any unbounded doubling would blow past
        // the cap.
        for _ in 0..<20 {
            let next = backoff.next()
            #expect(seconds(next) <= 0.050 + 0.001, "next must respect the cap")
        }
    }

    @Test func exponentialBackoffNeverReturnsZero() {
        // Regression: an early version returned a zero-duration delay when
        // jitter bottomed out, defeating the purpose of backing off.
        var backoff = ExponentialBackoff(
            initial: .milliseconds(5),
            max: .milliseconds(50)
        )
        for _ in 0..<10 {
            let next = backoff.next()
            #expect(seconds(next) > 0, "next must never return zero")
        }
    }

    @Test func exponentialBackoffResetReturnsToInitial() {
        var backoff = ExponentialBackoff(
            initial: .milliseconds(10),
            max: .milliseconds(1000)
        )
        // Climb a few steps.
        for _ in 0..<5 { _ = backoff.next() }
        backoff.reset()
        // After reset, the next draw should be in roughly the initial
        // band (jitter spans [initial, doubled-from-initial]).
        let first = backoff.next()
        #expect(seconds(first) <= 0.020 + 0.001, "first draw after reset should be within 2× initial")
    }

    // MARK: - Helpers

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds)
            + Double(d.components.attoseconds) / 1_000_000_000_000_000_000
    }
}
