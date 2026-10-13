// LoadTest/LoadRun.swift
//
// One load run: the deadline, the HTTP client and the recorder that every
// simulated client shares.

import AsyncHTTPClient
import Foundation

struct LoadRun: Sendable {
    let deadline: ContinuousClock.Instant
    let client: HTTPClient
    let recorder: LatencyRecorder

    /// Sends one request each `interval` seconds until the deadline. The
    /// offset spreads the clients over one interval, so they do not all
    /// send at the same moment.
    func drive(
        _ scenario: LoadScenario,
        interval: Double,
        offsetFraction: Double,
        makeRequest: @Sendable () throws -> PlannedRequest
    ) async {
        let clock = ContinuousClock()
        let period = Duration.milliseconds(Int64(interval * 1_000))
        try? await Task.sleep(for: period * offsetFraction)

        while clock.now < deadline, !Task.isCancelled {
            let started = clock.now
            do {
                let statusCode = try await send(try makeRequest())
                let elapsed = started.duration(to: clock.now)
                await recorder.record(scenario, statusCode: statusCode, durationMs: Self.milliseconds(elapsed))
            } catch {
                await recorder.recordTransportError(scenario)
            }
            try? await Task.sleep(until: started + period, clock: clock)
        }
    }

    private func send(_ planned: PlannedRequest) async throws -> Int {
        var request = HTTPClientRequest(url: planned.url)
        request.method = planned.method == "POST" ? .POST : .GET
        for header in planned.headers {
            request.headers.add(name: header.name, value: header.value)
        }
        if let body = planned.body {
            request.body = .bytes(body)
        }
        let response = try await client.execute(request, timeout: .seconds(30))
        _ = try await response.body.collect(upTo: 1 << 20)
        return Int(response.status.code)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
