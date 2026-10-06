// Tests/APITests/AsyncCountingSemaphoreTests.swift
//
// `withPermit` gives back its slot on every exit path (#2303). Before it, the
// personalization evaluator released the slot by hand in three branches.

import Testing

@testable import APIServer

@Suite struct AsyncCountingSemaphoreTests {
    private struct Failure: Error {}

    @Test func withPermitReleasesTheSlotWhenTheBodyThrows() async throws {
        let gate = AsyncCountingSemaphore(width: 1)
        await #expect(throws: Failure.self) {
            try await gate.withPermit { throw Failure() }
        }
        // With the slot leaked, this call would wait for ever.
        let value = try await gate.withPermit { 42 }
        #expect(value == 42)
    }

    @Test func oneSlotRunsTheBodiesOneAtATime() async throws {
        let gate = AsyncCountingSemaphore(width: 1)
        let log = Log()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<5 {
                group.addTask {
                    try await gate.withPermit {
                        await log.append("start \(index)")
                        try await Task.sleep(for: .milliseconds(5))
                        await log.append("end \(index)")
                    }
                }
            }
            try await group.waitForAll()
        }
        let entries = await log.entries
        #expect(entries.count == 10)
        for pair in stride(from: 0, to: entries.count, by: 2) {
            let index = entries[pair].dropFirst("start ".count)
            #expect(entries[pair + 1] == "end \(index)")
        }
    }

    private actor Log {
        private(set) var entries: [String] = []
        func append(_ entry: String) { entries.append(entry) }
    }
}
