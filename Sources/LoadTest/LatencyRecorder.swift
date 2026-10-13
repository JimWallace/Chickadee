// LoadTest/LatencyRecorder.swift
//
// Collects every measured request from the concurrent clients.

actor LatencyRecorder {
    private var durationsMs: [LoadScenario: [Double]] = [:]
    private var statusCounts: [LoadScenario: [Int: Int]] = [:]
    private var transportErrors: [LoadScenario: Int] = [:]

    func record(_ scenario: LoadScenario, statusCode: Int, durationMs: Double) {
        durationsMs[scenario, default: []].append(durationMs)
        statusCounts[scenario, default: [:]][statusCode, default: 0] += 1
    }

    func recordTransportError(_ scenario: LoadScenario) {
        transportErrors[scenario, default: 0] += 1
    }

    func summary(for scenario: LoadScenario) -> LatencySummary {
        LatencySummary(
            durationsMs: durationsMs[scenario] ?? [],
            statusCounts: statusCounts[scenario] ?? [:],
            transportErrors: transportErrors[scenario] ?? 0
        )
    }
}
