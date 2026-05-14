import Fluent
import XCTVapor
import XCTest

@testable import chickadee_server

final class LoginRateLimitTests: XCTestCase {

    func testIPRateLimitTrips429AfterCap() async throws {
        let store = LoginAttemptStore()
        let now = Date()
        let max = 3

        let allowed1 = await store.recordAndCheckIP(ip: "1.2.3.4", now: now, windowSeconds: 60, max: max)
        let allowed2 = await store.recordAndCheckIP(ip: "1.2.3.4", now: now, windowSeconds: 60, max: max)
        let allowed3 = await store.recordAndCheckIP(ip: "1.2.3.4", now: now, windowSeconds: 60, max: max)
        let allowed4 = await store.recordAndCheckIP(ip: "1.2.3.4", now: now, windowSeconds: 60, max: max)

        XCTAssertTrue(allowed1)
        XCTAssertTrue(allowed2)
        XCTAssertTrue(allowed3)
        XCTAssertFalse(allowed4)
    }

    func testIPRateLimitResetsAfterWindow() async throws {
        let store = LoginAttemptStore()
        let start = Date()
        let later = start.addingTimeInterval(61)

        _ = await store.recordAndCheckIP(ip: "1.2.3.4", now: start, windowSeconds: 60, max: 1)
        let blocked = await store.recordAndCheckIP(ip: "1.2.3.4", now: start, windowSeconds: 60, max: 1)
        XCTAssertFalse(blocked)

        let allowedLater = await store.recordAndCheckIP(ip: "1.2.3.4", now: later, windowSeconds: 60, max: 1)
        XCTAssertTrue(allowedLater)
    }

    func testUsernameLockoutAfterThreshold() async throws {
        let store = LoginAttemptStore()
        let now = Date()

        for _ in 0..<5 {
            await store.recordFailure(username: "alice", now: now, windowSeconds: 900)
        }

        let locked = await store.isLocked(username: "alice", now: now, windowSeconds: 900, threshold: 5)
        XCTAssertTrue(locked)
    }

    func testUsernameLockoutNotTrippedBelowThreshold() async throws {
        let store = LoginAttemptStore()
        let now = Date()

        for _ in 0..<3 {
            await store.recordFailure(username: "alice", now: now, windowSeconds: 900)
        }

        let locked = await store.isLocked(username: "alice", now: now, windowSeconds: 900, threshold: 5)
        XCTAssertFalse(locked)
    }

    func testClearFailuresResetsLockout() async throws {
        let store = LoginAttemptStore()
        let now = Date()

        for _ in 0..<5 {
            await store.recordFailure(username: "alice", now: now, windowSeconds: 900)
        }
        let lockedBefore = await store.isLocked(
            username: "alice", now: now, windowSeconds: 900, threshold: 5
        )
        XCTAssertTrue(lockedBefore)

        await store.clearFailures(username: "alice")
        let lockedAfter = await store.isLocked(
            username: "alice", now: now, windowSeconds: 900, threshold: 5
        )
        XCTAssertFalse(lockedAfter)
    }

    func testFailuresExpireAfterWindow() async throws {
        let store = LoginAttemptStore()
        let start = Date()
        let later = start.addingTimeInterval(901)

        for _ in 0..<5 {
            await store.recordFailure(username: "alice", now: start, windowSeconds: 900)
        }
        let lockedLater = await store.isLocked(
            username: "alice", now: later, windowSeconds: 900, threshold: 5
        )
        XCTAssertFalse(lockedLater)
    }
}
