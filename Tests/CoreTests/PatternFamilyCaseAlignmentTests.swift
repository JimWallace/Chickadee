// Tests/CoreTests/PatternFamilyCaseAlignmentTests.swift
//
// `PatternCase` carries two arrays parallel to `args`: `argsProvided` (false
// means "leave this argument off the call and let the function's own default
// apply") and `argVarRefs` (non-nil means "pass this family variable instead of
// the literal"). Both are optional on the wire — an empty array means "the
// pre-v0.4.94 default for every position" — so the model can only index them
// safely if a NON-empty one is exactly as long as `args`.
//
// Both the memberwise init and `init(from:)` enforce that by discarding a
// mismatched array. The 2026-08-19 sweep (run 32265903112) reported four
// survivors across the two sites — a relational flip and a swapped ternary on
// each — and every one of them inverts the rule: the CORRECTLY sized array is
// the one thrown away, and a wrong-length one is kept for the renderer to index.
//
// The rule is exercised today only through `Tests/APITests`, which the sweep
// does not run. That is why it survived, and it is also why these assertions
// belong here: `PatternCase` is a Core model with a Core invariant, and pinning
// it in an APIServer renderer suite leaves it unpinned for every other consumer.

import Foundation
import Testing

@testable import Core

@Suite struct PatternFamilyCaseAlignmentTests {

    private static let twoArgs: [JSONValue] = [.int(1), .string("x")]

    // MARK: - The memberwise init

    @Test func anAlignedArgsProvidedIsKept() {
        let one = PatternCase(
            key: "01", label: "aligned", args: Self.twoArgs, expected: .bool(true),
            argsProvided: [true, false])
        #expect(one.argsProvided == [true, false])
    }

    @Test func aMisalignedArgsProvidedIsDiscarded() {
        // Short, long, and the empty "all provided" default all land on `[]`,
        // which every consumer reads as "no position is omitted".
        for provided in [[true], [true, false, true], []] {
            let one = PatternCase(
                key: "01", label: "misaligned", args: Self.twoArgs, expected: .bool(true),
                argsProvided: provided)
            #expect(one.argsProvided.isEmpty)
        }
    }

    @Test func anAlignedArgVarRefsIsKept() {
        let one = PatternCase(
            key: "01", label: "aligned", args: Self.twoArgs, expected: .bool(true),
            argVarRefs: ["patients", nil])
        #expect(one.argVarRefs == ["patients", nil])
    }

    @Test func aMisalignedArgVarRefsIsDiscarded() {
        let one = PatternCase(
            key: "01", label: "misaligned", args: Self.twoArgs, expected: .bool(true),
            argVarRefs: ["patients"])
        #expect(one.argVarRefs.isEmpty)
    }

    @Test func aCaseWithNoArgsAcceptsOnlyEmptyParallelArrays() {
        let one = PatternCase(
            key: "01", label: "no args", args: [], expected: .int(0),
            argsProvided: [true], argVarRefs: ["v"])
        #expect(one.argsProvided.isEmpty)
        #expect(one.argVarRefs.isEmpty)
    }

    // MARK: - The decode path

    private func decode(_ json: String) throws -> PatternCase {
        try JSONDecoder().decode(PatternCase.self, from: Data(json.utf8))
    }

    @Test func alignedWireArraysSurviveDecoding() throws {
        let one = try decode(
            """
            {
              "key": "01",
              "label": "aligned",
              "args": [1, "x"],
              "argsProvided": [true, false],
              "argVarRefs": ["patients", null],
              "expected": true
            }
            """)
        #expect(one.argsProvided == [true, false])
        #expect(one.argVarRefs == ["patients", nil])
    }

    @Test func misalignedWireArraysAreDiscardedOnDecoding() throws {
        let one = try decode(
            """
            {
              "key": "01",
              "label": "misaligned",
              "args": [1, "x"],
              "argsProvided": [true],
              "argVarRefs": ["patients", null, "extra"],
              "expected": true
            }
            """)
        #expect(one.argsProvided.isEmpty)
        #expect(one.argVarRefs.isEmpty)
    }

    @Test func absentWireArraysDecodeToTheAllProvidedDefault() throws {
        let one = try decode(
            """
            {"key": "01", "label": "plain", "args": [1, "x"], "expected": true}
            """)
        #expect(one.argsProvided.isEmpty)
        #expect(one.argVarRefs.isEmpty)
    }

    /// The round trip, which is what the suite editor actually performs on
    /// every save: an aligned case must come back aligned, or the renderer
    /// starts passing an argument the instructor asked it to omit.
    @Test func anAlignedCaseRoundTripsThroughJSON() throws {
        let original = PatternCase(
            key: "01", label: "round trip", args: Self.twoArgs, expected: .bool(true),
            argsProvided: [true, false], argVarRefs: [nil, "label"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PatternCase.self, from: data)
        #expect(decoded.argsProvided == [true, false])
        #expect(decoded.argVarRefs == [nil, "label"])
    }
}
