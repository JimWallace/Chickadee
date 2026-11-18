// Tests/CoreTests/FHIRCodeOrderTieBreakTests.swift
//
// The Data page lists a FHIR file's codes most used first, then by resource
// type, then by system, then by code, "so the order never depends on
// dictionary iteration" (`FHIRNdjsonProfile`, `codeOrder`). The existing
// feed's codes differ in count or share type and system, so no test reached
// the type or system tie-breaks, and the 2026-11-13 sweep (#3015) saw both
// `!=` guards flipped to `==` survive. Each flip lets a later key decide the
// order: the code text instead of the resource type, or instead of the
// system. Each case below makes the later key disagree with the one that
// should decide.
//
// The system flip is also caught by `FHIRNdjsonProfileTests`, but only by
// chance. Under it, two LOINC Observations with one use each compare equal
// both ways, so their order is the Dictionary's, which Swift seeds per
// process. Measured: that suite failed in 5 of 10 runs, and this one in 10
// of 10.

import Core
import Testing

@Suite struct FHIRCodeOrderTieBreakTests {

    private static func resource(_ id: String, type: String, system: String, code: String) -> String {
        #"{"resourceType":""# + type + #"","id":""# + id + #"","code":{"coding":[{"system":""# + system
            + #"","code":""# + code + #""}]}}"#
    }

    /// Equal counts: the resource type decides, not the code. `Condition`
    /// sorts before `Observation`, although its code `b` sorts after `a`.
    @Test func theResourceTypeBreaksACountTie() throws {
        let text =
            [
                Self.resource("o1", type: "Observation", system: "http://loinc.org", code: "a"),
                Self.resource("c1", type: "Condition", system: "http://loinc.org", code: "b"),
            ].joined(separator: "\n") + "\n"
        let codes = try FHIRNdjsonProfile.profile(text).codes
        #expect(codes.map(\.resourceType) == ["Condition", "Observation"])
        #expect(codes.map(\.code) == ["b", "a"])
    }

    /// Equal counts and type: the system decides, not the code. LOINC sorts
    /// before SNOMED CT, although its code `z` sorts after `a`.
    @Test func theSystemBreaksATypeTie() throws {
        let text =
            [
                Self.resource("o1", type: "Observation", system: "http://snomed.info/sct", code: "a"),
                Self.resource("o2", type: "Observation", system: "http://loinc.org", code: "z"),
            ].joined(separator: "\n") + "\n"
        let codes = try FHIRNdjsonProfile.profile(text).codes
        #expect(codes.map(\.system) == ["http://loinc.org", "http://snomed.info/sct"])
        #expect(codes.map(\.code) == ["z", "a"])
    }
}
