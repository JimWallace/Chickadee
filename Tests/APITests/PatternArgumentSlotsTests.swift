// Tests/APITests/PatternArgumentSlotsTests.swift
//
// Pins the per-parameter view every language renderer walks. Seven
// renderers used to compute this by hand; one wrong pad here would misalign
// a case's arguments in every generated test at once.

import Core
import Testing

@testable import APIServer

@Suite struct PatternArgumentSlotsTests {
    private func family(paramNames: [String]) -> PatternFamily {
        PatternFamily(id: "f", name: "F", kind: .boundaryEquality, functionName: "f", paramNames: paramNames)
    }

    @Test func declaredParameterNamesWin() {
        let c = PatternCase(key: "01", label: "one", args: [.int(1), .int(2)], expected: .int(3))
        let slots = PatternArgumentSlots(family: family(paramNames: ["a", "b"]), case: c)
        #expect(slots.names == ["a", "b"])
        #expect(slots.provided == [true, true])
        #expect(slots.varRefs == [nil, nil])
    }

    @Test func positionalPlaceholdersFollowTheLanguage() {
        let c = PatternCase(key: "01", label: "one", args: [.int(1), .int(2)], expected: .int(3))
        let underscore = PatternArgumentSlots(family: family(paramNames: []), case: c)
        #expect(underscore.names == ["arg_1", "arg_2"])
        let hyphen = PatternArgumentSlots(family: family(paramNames: []), case: c, placeholder: { "arg-\($0 + 1)" })
        #expect(hyphen.names == ["arg-1", "arg-2"])
    }

    @Test func providedAndVarRefsAreCarriedWhenAligned() {
        let c = PatternCase(
            key: "01", label: "one", args: [.int(1), .null], expected: .int(3),
            argsProvided: [true, false], argVarRefs: [nil, "limit"])
        let slots = PatternArgumentSlots(family: family(paramNames: ["a", "b"]), case: c)
        #expect(slots.provided == [true, false])
        #expect(slots.varRefs == [nil, "limit"])
    }

    /// `paramNames` longer than the case's arrays pads with "provided, no
    /// ref" rather than trapping on an index.
    @Test func shortArraysPadToTheParameterCount() {
        let c = PatternCase(
            key: "01", label: "one", args: [.int(1)], expected: .int(3),
            argsProvided: [false], argVarRefs: ["x"])
        let slots = PatternArgumentSlots(family: family(paramNames: ["a", "b", "c"]), case: c)
        #expect(slots.provided == [false, true, true])
        #expect(slots.varRefs == ["x", nil, nil])
    }
}
