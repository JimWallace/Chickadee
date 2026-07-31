// Tests/CoreTests/SlipDayPolicyTests.swift
//
// SlipDayPolicy.resolve: nullable course columns → effective policy.
// Nil means "never configured" (disabled, defaults pre-filled); stored
// values are clamped so a hand-edited row can't produce a negative budget
// or a zero-length day.

import Foundation
import Testing

@testable import Core

struct SlipDayPolicyTests {

    @Test func nilColumnsResolveToDisabledDefaults() {
        let policy = SlipDayPolicy.resolve(
            enabled: nil, daysPerStudent: nil, extensionHours: nil)
        #expect(policy.enabled == false)
        #expect(policy.daysPerStudent == SlipDayPolicy.defaultDaysPerStudent)
        #expect(policy.extensionHours == SlipDayPolicy.defaultExtensionHours)
    }

    @Test func storedValuesPassThrough() {
        let policy = SlipDayPolicy.resolve(
            enabled: true, daysPerStudent: 5, extensionHours: 48)
        #expect(policy.enabled)
        #expect(policy.daysPerStudent == 5)
        #expect(policy.extensionHours == 48)
    }

    @Test func negativeDaysClampToZero() {
        let policy = SlipDayPolicy.resolve(
            enabled: true, daysPerStudent: -3, extensionHours: 24)
        #expect(policy.daysPerStudent == 0)
    }

    @Test func zeroHoursClampToOne() {
        let policy = SlipDayPolicy.resolve(
            enabled: true, daysPerStudent: 2, extensionHours: 0)
        #expect(policy.extensionHours == 1)
    }
}
