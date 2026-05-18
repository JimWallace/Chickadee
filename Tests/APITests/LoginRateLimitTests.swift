import Fluent
import Foundation
import Testing

@testable import chickadee_server

@Suite struct LoginRateLimitTests {

    @Test func ipRateLimitTrips429AfterCap() async throws {
        let store = LoginAttemptStore()
        let now = Date()
        let max = 3

        let allowed1 = await store.recordAndCheckIP(ip: "1.2.3.4", now: now, windowSeconds: 60, max: max)
        let allowed2 = await store.recordAndCheckIP(ip: "1.2.3.4", now: now, windowSeconds: 60, max: max)
        let allowed3 = await store.recordAndCheckIP(ip: "1.2.3.4", now: now, windowSeconds: 60, max: max)
        let allowed4 = await store.recordAndCheckIP(ip: "1.2.3.4", now: now, windowSeconds: 60, max: max)

        #expect(allowed1)
        #expect(allowed2)
        #expect(allowed3)
        #expect(!allowed4)
    }

    @Test func ipRateLimitResetsAfterWindow() async throws {
        let store = LoginAttemptStore()
        let start = Date()
        let later = start.addingTimeInterval(61)

        _ = await store.recordAndCheckIP(ip: "1.2.3.4", now: start, windowSeconds: 60, max: 1)
        let blocked = await store.recordAndCheckIP(ip: "1.2.3.4", now: start, windowSeconds: 60, max: 1)
        #expect(!blocked)

        let allowedLater = await store.recordAndCheckIP(ip: "1.2.3.4", now: later, windowSeconds: 60, max: 1)
        #expect(allowedLater)
    }

    @Test func usernameLockoutAfterThreshold() async throws {
        let store = LoginAttemptStore()
        let now = Date()

        for _ in 0..<5 {
            await store.recordFailure(username: "alice", now: now, windowSeconds: 900)
        }

        let locked = await store.isLocked(username: "alice", now: now, windowSeconds: 900, threshold: 5)
        #expect(locked)
    }

    @Test func usernameLockoutNotTrippedBelowThreshold() async throws {
        let store = LoginAttemptStore()
        let now = Date()

        for _ in 0..<3 {
            await store.recordFailure(username: "alice", now: now, windowSeconds: 900)
        }

        let locked = await store.isLocked(username: "alice", now: now, windowSeconds: 900, threshold: 5)
        #expect(!locked)
    }

    @Test func clearFailuresResetsLockout() async throws {
        let store = LoginAttemptStore()
        let now = Date()

        for _ in 0..<5 {
            await store.recordFailure(username: "alice", now: now, windowSeconds: 900)
        }
        let lockedBefore = await store.isLocked(
            username: "alice", now: now, windowSeconds: 900, threshold: 5
        )
        #expect(lockedBefore)

        await store.clearFailures(username: "alice")
        let lockedAfter = await store.isLocked(
            username: "alice", now: now, windowSeconds: 900, threshold: 5
        )
        #expect(!lockedAfter)
    }

    @Test func failuresExpireAfterWindow() async throws {
        let store = LoginAttemptStore()
        let start = Date()
        let later = start.addingTimeInterval(901)

        for _ in 0..<5 {
            await store.recordFailure(username: "alice", now: start, windowSeconds: 900)
        }
        let lockedLater = await store.isLocked(
            username: "alice", now: later, windowSeconds: 900, threshold: 5
        )
        #expect(!lockedLater)
    }
}
