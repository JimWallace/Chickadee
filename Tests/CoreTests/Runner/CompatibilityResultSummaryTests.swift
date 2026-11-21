// Tests/CoreTests/Runner/CompatibilityResultSummaryTests.swift
//
// `CompatibilityResult.summaryDescription`: the fixed words with no reasons,
// and the reasons joined when there are some.
// Split by subject out of the former `CoreCodableTests`.

import Foundation
import Testing

@testable import Core

@Suite struct CompatibilityResultSummaryTests {

    @Test func compatibilityResultSummaryCompatibleNoReasons() {
        let r = CompatibilityResult(isCompatible: true)
        #expect(r.summaryDescription == "compatible")
    }

    @Test func compatibilityResultSummaryIncompatibleNoReasons() {
        let r = CompatibilityResult(isCompatible: false)
        #expect(r.summaryDescription == "incompatible")
    }

    @Test func compatibilityResultSummaryJoinsReasons() {
        let r = CompatibilityResult(isCompatible: false, reasons: ["needs python 3.10", "needs jupyter"])
        #expect(r.summaryDescription == "needs python 3.10; needs jupyter")
    }
}
