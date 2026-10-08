// Tests/APITests/ClassRecordRecomputeQueueTests.swift
//
// `ClassRecordRecomputeQueue` runs class-record recomputes one at a time per
// assignment (#2468). The test database serializes writes, so an integration
// test cannot show the race it prevents; these tests pin the queue itself.

import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(1)))
struct ClassRecordRecomputeQueueTests {

    /// Counts the runs in progress and the most seen at once.
    private actor Probe {
        private(set) var active = 0
        private(set) var mostActive = 0
        private(set) var runs = 0

        func enter() {
            active += 1
            runs += 1
            mostActive = max(mostActive, active)
        }

        func leave() { active -= 1 }
    }

    @Test func runsForOneAssignmentNeverOverlap() async {
        let queue = ClassRecordRecomputeQueue()
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await queue.run("setup") {
                        await probe.enter()
                        try? await Task.sleep(for: .milliseconds(5))
                        await probe.leave()
                    }
                }
            }
        }
        #expect(await probe.mostActive == 1)
        // Calls that arrive while a run is queued share it, so there are at
        // most as many runs as calls, and at least one.
        let runs = await probe.runs
        #expect(runs >= 1 && runs <= 8)
    }

    /// The run for "a" waits until the run for "b" has started. If the queue
    /// made different assignments wait for each other, this would never end,
    /// and the suite's time limit would fail it.
    @Test func runsForDifferentAssignmentsDoNotWaitForEachOther() async {
        let queue = ClassRecordRecomputeQueue()
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await queue.run("a") {
                    await probe.enter()
                    while await probe.runs < 2 { try? await Task.sleep(for: .milliseconds(1)) }
                    await probe.leave()
                }
            }
            group.addTask {
                await queue.run("b") {
                    await probe.enter()
                    await probe.leave()
                }
            }
        }
        #expect(await probe.runs == 2)
    }
}
