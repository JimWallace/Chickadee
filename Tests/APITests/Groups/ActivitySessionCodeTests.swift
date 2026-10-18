// Tests/APITests/Groups/ActivitySessionCodeTests.swift
//
// The changing join code of a per-group session (docs/lab-groups.md,
// "Presence"): its alphabet, that it changes every period, that a join takes
// the code before the current one and no older code, and the countdown.

import Foundation
import Testing

@testable import APIServer

@Suite struct ActivitySessionCodeTests {

    private let secret = ActivitySessionCode.newSecret()
    /// The first instant of a period.
    private let periodStart = Date(timeIntervalSince1970: 30 * 60_000)

    @Test func aCodeIsFiveCharactersWithNoLookAlikes() {
        for offset in 0..<200 {
            let code = ActivitySessionCode.code(
                secret: secret, at: periodStart.addingTimeInterval(Double(offset) * ActivitySessionCode.period))
            #expect(code.count == 5)
            #expect(code.allSatisfy(ActivitySessionCode.alphabet.contains))
        }
        for confusable in "0O1IL2Z5S8B" {
            #expect(!ActivitySessionCode.alphabet.contains(confusable))
        }
    }

    @Test func theCodeHoldsForOnePeriodThenChanges() {
        let first = ActivitySessionCode.code(secret: secret, at: periodStart)
        #expect(ActivitySessionCode.code(secret: secret, at: periodStart.addingTimeInterval(29.9)) == first)
        let next = ActivitySessionCode.code(secret: secret, at: periodStart.addingTimeInterval(30))
        // Two periods in a row could draw one code by chance; over ten they
        // cannot all match.
        let later = (1...10).map {
            ActivitySessionCode.code(secret: secret, at: periodStart.addingTimeInterval(Double($0) * 30))
        }
        #expect(later.contains { $0 != first })
        #expect(next == later[0])
    }

    @Test func aJoinTakesTheCodeBeforeTheCurrentOneAndNoOlder() {
        let shown = ActivitySessionCode.code(secret: secret, at: periodStart)
        #expect(ActivitySessionCode.matches(shown, secret: secret, at: periodStart.addingTimeInterval(10)))
        #expect(
            ActivitySessionCode.matches(shown, secret: secret, at: periodStart.addingTimeInterval(45)),
            "a student who was typing when the code changed is not refused")
        // Two periods back. It joins only if it happens to equal one of the
        // two accepted codes.
        let now = periodStart.addingTimeInterval(10)
        let older = ActivitySessionCode.code(secret: secret, at: periodStart.addingTimeInterval(-60))
        let accepted = [
            ActivitySessionCode.code(secret: secret, at: now),
            ActivitySessionCode.code(secret: secret, at: periodStart.addingTimeInterval(-30)),
        ]
        #expect(ActivitySessionCode.matches(older, secret: secret, at: now) == accepted.contains(older))
    }

    @Test func letterCaseSpacesAndDashesDoNotCount() {
        let shown = ActivitySessionCode.code(secret: secret, at: periodStart)
        let typed = " \(shown.prefix(2).lowercased())-\(shown.dropFirst(2)) "
        #expect(ActivitySessionCode.matches(typed, secret: secret, at: periodStart))
    }

    @Test func anotherSessionsSecretGivesAnotherCode() {
        let other = ActivitySessionCode.newSecret()
        #expect(other != secret)
        let codes = (0..<10).map { offset in
            let date = periodStart.addingTimeInterval(Double(offset) * 30)
            return ActivitySessionCode.code(secret: secret, at: date)
                == ActivitySessionCode.code(secret: other, at: date)
        }
        #expect(codes.contains(false))
    }

    @Test func theCountdownRunsFromThePeriodToOne() {
        #expect(ActivitySessionCode.secondsLeft(at: periodStart) == 30)
        #expect(ActivitySessionCode.secondsLeft(at: periodStart.addingTimeInterval(0.5)) == 30)
        #expect(ActivitySessionCode.secondsLeft(at: periodStart.addingTimeInterval(29.5)) == 1)
    }
}
