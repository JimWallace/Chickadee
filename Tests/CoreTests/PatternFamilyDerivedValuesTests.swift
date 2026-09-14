// Tests/CoreTests/PatternFamilyDerivedValuesTests.swift
//
// The two per-case / per-family values every language renderer reads. They
// were re-derived in fourteen and seven places respectively; six of the
// seven tolerance sites hardcoded the constant, so a change to the named
// default would have desynchronised Python from the other languages.

import Core
import Testing

@Suite struct PatternFamilyDerivedValuesTests {
    @Test func expectedNameReadsAStringAndFallsBackOtherwise() {
        let named = PatternCase(key: "01", label: "l", args: [], expected: .string("ValueError"))
        #expect(named.expectedName(fallback: "Exception") == "ValueError")
        let other = PatternCase(key: "02", label: "l", args: [], expected: .int(4))
        #expect(other.expectedName(fallback: "Exception") == "Exception")
    }

    @Test func effectiveToleranceUsesTheAuthoredValueElseTheDefault() {
        let authored = PatternFamily(
            id: "f", name: "F", kind: .approximateEquality, functionName: "f",
            defaults: PatternDefaults(tolerance: 0.5))
        #expect(authored.effectiveTolerance == 0.5)
        let bare = PatternFamily(id: "g", name: "G", kind: .approximateEquality, functionName: "g")
        #expect(bare.effectiveTolerance == PatternDefaults.approximateTolerance)
        #expect(PatternDefaults.approximateTolerance == 1e-6)
    }
}
