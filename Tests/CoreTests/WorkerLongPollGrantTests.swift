// Tests/CoreTests/WorkerLongPollGrantTests.swift
//
// `WorkerLongPoll.grantedHoldSeconds` is a Core rule shared by the server and
// the runner, but its only assertions lived in APITests, which the mutation
// sweep skips, so the 2026-11-10 sweep (#2970) saw `requested >= 1` survive.
// The rule is pinned here at its boundary: below one second grants nothing,
// one second and up is granted, capped at the server maximum.

import Core
import Testing

@Suite struct WorkerLongPollGrantTests {

    @Test(arguments: [nil, Int.min, -1, 0])
    func aRequestBelowOneSecondGrantsNoHold(requested: Int?) {
        #expect(WorkerLongPoll.grantedHoldSeconds(requested: requested) == nil)
    }

    @Test(arguments: [1, 2, 5, WorkerLongPoll.maxHoldSeconds])
    func aRequestFromOneSecondToTheMaximumIsGrantedAsAsked(requested: Int) {
        #expect(WorkerLongPoll.grantedHoldSeconds(requested: requested) == requested)
    }

    @Test(arguments: [WorkerLongPoll.maxHoldSeconds + 1, 3_600, Int.max])
    func aRequestPastTheMaximumIsCapped(requested: Int) {
        #expect(WorkerLongPoll.grantedHoldSeconds(requested: requested) == WorkerLongPoll.maxHoldSeconds)
    }
}
