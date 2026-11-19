// Tests/APITests/PatternFamilies/OctaveCallContextTests.swift
//
// `octaveCallContext` builds the argument part of every generated Octave
// test. Octave passes arguments by position only, so the first omitted
// argument ends the list: the callee then sees a shorter `nargin`. This suite
// pins that rule, an argument bound from a variable, and the input line of a
// case with no arguments. The tests read the generated source. They do not
// run Octave.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct OctaveCallContextTests {

    private func family(paramNames: [String]) -> PatternFamily {
        PatternFamily(
            id: "fam", name: "Family", kind: .boundaryEquality, functionName: "target",
            paramNames: paramNames)
    }

    @Test func allProvidedArgumentsAreDeclaredAndPassedInOrder() {
        let c = PatternCase(key: "c1", label: "all", args: [.int(1), .int(2)], expected: .int(0))
        let ctx = octaveCallContext(for: family(paramNames: ["a", "b"]), case: c)
        #expect(ctx.declBlock == "a = 1;\nb = 2;\n\n")
        #expect(ctx.callArgs == "a, b")
    }

    /// An omission in the middle ends the list. The later argument is not
    /// passed, even though it is provided.
    @Test func theFirstOmittedArgumentEndsTheArgumentList() {
        let c = PatternCase(
            key: "c1", label: "gap", args: [.int(1), .int(2), .int(3)], expected: .int(0),
            argsProvided: [true, false, true])
        let ctx = octaveCallContext(for: family(paramNames: ["a", "b", "c"]), case: c)
        #expect(ctx.callArgs == "a")
        #expect(ctx.declBlock == "a = 1;\n\n")
        #expect(ctx.inputLine.contains("\"a=\""))
        #expect(!ctx.inputLine.contains("\"c=\""))
    }

    @Test func anArgumentThatReferencesAVariableIsBoundFromThatVariable() {
        let c = PatternCase(
            key: "c1", label: "ref", args: [.string("$limit")], expected: .int(0),
            argVarRefs: ["limit"])
        let ctx = octaveCallContext(for: family(paramNames: ["n"]), case: c)
        #expect(ctx.declBlock == "n = limit;\n\n")
        #expect(ctx.callArgs == "n")
        #expect(ctx.inputLine.contains("\"n=\" chickadee.format(n)"))
    }

    @Test func aCaseWithNoArgumentsSaysSoInItsInputLine() {
        let c = PatternCase(key: "c1", label: "none", args: [], expected: .int(0))
        let ctx = octaveCallContext(for: family(paramNames: []), case: c)
        #expect(ctx.declBlock.isEmpty)
        #expect(ctx.callArgs.isEmpty)
        #expect(ctx.inputLine.contains("(no input)"))
    }
}
