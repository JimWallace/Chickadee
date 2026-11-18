// Tests/APITests/PatternFamilies/RacketCallContextPersonalizationTests.swift
//
// The parts of the Racket pattern-family renderer that the Racket execution
// suite reaches only where `racket` is installed: the call context for an
// argument bound from a variable, for a parameter with no value and for an
// omitted argument, and the per-student personalization preamble. These tests
// read the generated source. They do not run Racket.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct RacketCallContextPersonalizationTests {

    private func family(paramNames: [String], cases: [PatternCase] = []) -> PatternFamily {
        PatternFamily(
            id: "fam", name: "Family", kind: .boundaryEquality, functionName: "target",
            paramNames: paramNames, cases: cases)
    }

    // MARK: - racketCallContext

    @Test func anArgumentThatReferencesAVariableIsBoundFromThatVariable() {
        let c = PatternCase(
            key: "c1", label: "ref", args: [.string("$limit"), .int(2)], expected: .int(0),
            argVarRefs: ["limit", nil])
        let ctx = racketCallContext(for: family(paramNames: ["n", "m"]), case: c)
        #expect(ctx.declBlock == "(define n limit)\n(define m 2)")
        #expect(ctx.argList == "(list n m)")
    }

    /// Racket has no optional parameters, so an omitted argument is not
    /// passed at all, in the middle as at the end.
    @Test func anOmittedArgumentIsNotPassed() {
        let c = PatternCase(
            key: "c1", label: "gap", args: [.int(1), .int(2), .int(3)], expected: .int(0),
            argsProvided: [true, false, true])
        let ctx = racketCallContext(for: family(paramNames: ["a", "b", "c"]), case: c)
        #expect(ctx.argList == "(list a c)")
        #expect(!ctx.declBlock.contains("(define b"))
    }

    /// A declared parameter with no authored value and no reference has
    /// nothing to bind, so it is neither defined nor passed.
    @Test func aParameterWithNoValueIsNeitherDefinedNorPassed() {
        let c = PatternCase(key: "c1", label: "short", args: [.int(1)], expected: .int(0))
        let ctx = racketCallContext(for: family(paramNames: ["a", "b"]), case: c)
        #expect(ctx.declBlock == "(define a 1)")
        #expect(ctx.argList == "(list a)")
        #expect(ctx.inputPreview.contains("a="))
        #expect(!ctx.inputPreview.contains("b="))
    }

    @Test func aCaseWithNoArgumentsHasAnEmptyListAndSaysSo() {
        let c = PatternCase(key: "c1", label: "none", args: [], expected: .int(0))
        let ctx = racketCallContext(for: family(paramNames: []), case: c)
        #expect(ctx.declBlock.isEmpty)
        #expect(ctx.argList == "(list)")
        #expect(ctx.inputPreview == "\"(no arguments)\"")
    }

    // MARK: - Personalization preamble

    @Test func perStudentReferencesAreBoundOnceFromTheInputs() throws {
        let c = PatternCase(
            key: "c1", label: "personal", args: [.string("$dose"), .string("$dose")], expected: .int(0),
            argVarRefs: ["dose", "dose"], expectedVarRef: "target-value")
        let script = renderRacketPatternCase(
            family: family(paramNames: ["d", "e"], cases: [c]), case: c, sectionVariables: [],
            specHash: "h", perStudentNames: ["dose", "target-value", "unused"])

        let doseBinding = #"(define dose (hash-ref (chickadee-inputs) "dose" #f))"#
        #expect(script.contains(doseBinding))
        #expect(script.contains(#"(define target-value (hash-ref (chickadee-inputs) "target-value" #f))"#))
        // A name the case uses twice is bound once.
        #expect(script.components(separatedBy: doseBinding).count == 2)
        // Only the names the case uses are bound.
        #expect(!script.contains("\"unused\""))
        // The expected value reads the per-student binding.
        #expect(script.contains("(define expected target-value)"))
        // The bindings come before the case body that reads them.
        let preamble = try #require(script.range(of: doseBinding))
        let body = try #require(script.range(of: "(define d dose)"))
        #expect(preamble.lowerBound < body.lowerBound)
    }

    /// A reference to a family variable that is not per-student gets no
    /// binding from the inputs.
    @Test func aReferenceThatIsNotPerStudentHasNoPreamble() {
        let c = PatternCase(
            key: "c1", label: "plain", args: [.string("$limit")], expected: .int(1),
            argVarRefs: ["limit"])
        let script = renderRacketPatternCase(
            family: family(paramNames: ["n"], cases: [c]), case: c, sectionVariables: [],
            specHash: "h", perStudentNames: ["dose"])
        #expect(!script.contains("chickadee-inputs"))
        #expect(script.contains("(define n limit)"))
    }
}
