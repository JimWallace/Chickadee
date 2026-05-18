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

import XCTest

@testable import chickadee_runner

final class RunnerNetworkResilienceTests: XCTestCase {

    // MARK: - classifyHTTPRetry

    func testClassifyHTTPRetryMarksGatewayErrorsRetryable() {
        for code in [500, 502, 503, 504] {
            XCTAssertEqual(
                classifyHTTPRetry(statusCode: code, body: "x"),
                .retryable("HTTP \(code): x"),
                "expected \(code) to be retryable")
        }
    }

    func testClassifyHTTPRetryMarksRateLimitAndTimeoutCodesRetryable() {
        for code in [408, 425, 429] {
            XCTAssertEqual(
                classifyHTTPRetry(statusCode: code, body: "rl"),
                .retryable("HTTP \(code): rl"),
                "expected \(code) to be retryable")
        }
    }

    func testClassifyHTTPRetryTerminatesOnAuthFailures() {
        XCTAssertEqual(
            classifyHTTPRetry(statusCode: 401, body: "unauth"),
            .terminal("HTTP 401: unauth"))
        XCTAssertEqual(
            classifyHTTPRetry(statusCode: 403, body: "forbidden"),
            .terminal("HTTP 403: forbidden"))
    }

    func testClassifyHTTPRetryTerminatesOnConflict() {
        // 409 — duplicate worker ID claim — is terminal so the worker
        // can re-roll its ID rather than spin.
        XCTAssertEqual(
            classifyHTTPRetry(statusCode: 409, body: "duplicate worker"),
            .terminal("HTTP 409: duplicate worker"))
    }

    func testClassifyHTTPRetryTerminatesOnUnknownClientErrors() {
        // 400-range responses other than the explicitly retryable codes
        // are treated as client bugs — no point retrying.
        for code in [400, 404, 422] {
            XCTAssertEqual(
                classifyHTTPRetry(statusCode: code, body: "bad"),
                .terminal("HTTP \(code): bad"),
                "expected \(code) to be terminal")
        }
    }

    // MARK: - classifyPollHTTPRetry

    func testClassifyPollHTTPRetryUpgrades401And403ToRetryable() {
        // Poll-path-specific: long-lived runners should recover through
        // server-side auth reconfiguration windows rather than terminating.
        XCTAssertEqual(
            classifyPollHTTPRetry(statusCode: 401, body: "rotating-secret"),
            .retryable("HTTP 401: rotating-secret"))
        XCTAssertEqual(
            classifyPollHTTPRetry(statusCode: 403, body: "tmp"),
            .retryable("HTTP 403: tmp"))
    }

    func testClassifyPollHTTPRetryDelegatesNonAuthCodesToBaseClassifier() {
        // Everything except 401/403 falls through to the standard
        // classifier — confirm by spot-checking a retryable and a terminal.
        XCTAssertEqual(
            classifyPollHTTPRetry(statusCode: 503, body: "down"),
            .retryable("HTTP 503: down"))
        XCTAssertEqual(
            classifyPollHTTPRetry(statusCode: 409, body: "dup"),
            .terminal("HTTP 409: dup"))
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

    func testWithRunnerRetryReturnsImmediatelyOnSuccess() async throws {
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

        XCTAssertEqual(result, 42)
        let n = await calls.n
        XCTAssertEqual(n, 1, "operation should run exactly once on success")
    }

    func testWithRunnerRetryRetriesUntilSuccess() async throws {
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

        XCTAssertEqual(result, 7)
        let n = await calls.n
        XCTAssertEqual(n, 3, "operation should run until the 3rd attempt succeeds")
    }

    func testWithRunnerRetryShortCircuitsOnTerminalDisposition() async {
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
            XCTFail("expected StubError to be thrown")
        } catch is StubError {
            // expected
        } catch {
            XCTFail("expected StubError, got \(error)")
        }

        let n = await calls.n
        XCTAssertEqual(n, 1, "terminal disposition must not trigger a retry")
    }

    func testWithRunnerRetryRespectsMaxAttemptsAndRethrows() async {
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
            XCTFail("expected the operation to exhaust its retries")
        } catch is StubError {
            // expected
        } catch {
            XCTFail("expected StubError, got \(error)")
        }

        let n = await calls.n
        XCTAssertEqual(n, 3, "operation should run exactly maxAttempts times")
    }

    func testWithRunnerRetryThrowsImmediatelyWhenPolicyDisabled() async {
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
            XCTFail("expected throw")
        } catch is StubError {
            // expected
        } catch {
            XCTFail("expected StubError, got \(error)")
        }

        let n = await calls.n
        XCTAssertEqual(n, 1, "policy.enabled=false should disable retry entirely")
    }

    func testWithRunnerRetryInvokesOnRetryForEachRetryButNotForFinalThrow() async {
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
            XCTFail("expected throw")
        } catch is StubError {
            // expected
        } catch {
            XCTFail("expected StubError, got \(error)")
        }

        let recorded = await log.snapshot()
        // 3 attempts total → 2 retries scheduled before the final throw.
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded.map(\.attempt), [1, 2])
        XCTAssertEqual(recorded.map(\.stage), [.resultUpload, .resultUpload])
        XCTAssertEqual(recorded.map(\.message), ["try again", "try again"])
        XCTAssertTrue(recorded.allSatisfy(\.retryable))
    }

    // MARK: - ExponentialBackoff

    // Note: there is no "monotonic non-decreasing" test for ExponentialBackoff.
    // `next()` returns a value in `[initial, currentCappedDoubled]` — the
    // *upper bound* grows on each call (until it hits the cap), but the
    // jittered return value can be smaller than the previous draw.  The
    // tests below pin what callers actually rely on: bounded delay,
    // never-zero so the loop doesn't spin, and a working reset.

    func testExponentialBackoffStaysWithinCap() {
        var backoff = ExponentialBackoff(
            initial: .milliseconds(10),
            max: .milliseconds(50)
        )
        // Burn enough iterations that any unbounded doubling would blow past
        // the cap.
        for _ in 0..<20 {
            let next = backoff.next()
            XCTAssertLessThanOrEqual(
                seconds(next), 0.050 + 0.001,
                "next must respect the cap")
        }
    }

    func testExponentialBackoffNeverReturnsZero() {
        // Regression: an early version returned a zero-duration delay when
        // jitter bottomed out, defeating the purpose of backing off.
        var backoff = ExponentialBackoff(
            initial: .milliseconds(5),
            max: .milliseconds(50)
        )
        for _ in 0..<10 {
            let next = backoff.next()
            XCTAssertGreaterThan(seconds(next), 0, "next must never return zero")
        }
    }

    func testExponentialBackoffResetReturnsToInitial() {
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
        XCTAssertLessThanOrEqual(
            seconds(first), 0.020 + 0.001,
            "first draw after reset should be within 2× initial")
    }

    // MARK: - Helpers

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds)
            + Double(d.components.attoseconds) / 1_000_000_000_000_000_000
    }
}
