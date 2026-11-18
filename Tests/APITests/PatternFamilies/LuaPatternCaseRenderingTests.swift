// Tests/APITests/PatternFamilies/LuaPatternCaseRenderingTests.swift
//
// The per-language parts of the Lua pattern-family renderer that the golden
// and matrix suites do not reach: the type-name table behind
// `return_type_check`, a positional `nil` for an omitted middle argument, a
// case argument bound from a family variable, a case with no arguments, and
// the per-student personalization preamble.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct LuaPatternCaseRenderingTests {

    private func family(
        kind: PatternKind = .boundaryEquality, paramNames: [String] = [], cases: [PatternCase] = []
    ) -> PatternFamily {
        PatternFamily(
            id: "fam", name: "Family", kind: kind, functionName: "target",
            paramNames: paramNames, cases: cases)
    }

    // MARK: - luaTypeCheckExpression

    @Test(arguments: [
        ("int", "math.type(v) == \"integer\""),
        ("Integer", "math.type(v) == \"integer\""),
        ("float", "type(v) == \"number\""),
        ("numeric", "type(v) == \"number\""),
        ("str", "type(v) == \"string\""),
        ("character", "type(v) == \"string\""),
        ("bool", "type(v) == \"boolean\""),
        ("logical", "type(v) == \"boolean\""),
        ("list", "type(v) == \"table\""),
        ("dict", "type(v) == \"table\""),
        ("callable", "type(v) == \"function\""),
        ("None", "v == nil"),
        ("null", "v == nil"),
        ("any", "true"),
        ("object", "true"),
    ])
    func aKnownTypeNameMapsToItsLuaPredicate(typeName: String, expected: String) {
        #expect(luaTypeCheckExpression(typeName: typeName, valueExpr: "v") == expected)
    }

    /// An unknown name is compared against `type()` in lower case, so it
    /// reports a mismatch instead of passing the way `any` does.
    @Test func anUnknownTypeNameIsComparedAgainstTypeInLowerCase() {
        #expect(luaTypeCheckExpression(typeName: "UserData", valueExpr: "r") == "type(r) == \"userdata\"")
    }

    @Test func aReturnTypeCaseEmbedsThePredicateForItsExpectedName() {
        let c = PatternCase(key: "c1", label: "returns an integer", args: [.int(3)], expected: .string("int"))
        let script = renderLuaPatternCase(
            family: family(kind: .returnTypeCheck, paramNames: ["n"], cases: [c]), case: c,
            sectionVariables: [], specHash: "h")
        #expect(script.contains("if not (math.type(result) == \"integer\") then"))
        #expect(script.contains("local expected_type_name = \"int\""))
    }

    // MARK: - luaCallContext

    /// Lua has no keyword arguments, so an omitted middle argument must stay
    /// in place as `nil`, and an omitted trailing argument is dropped.
    @Test func anOmittedMiddleArgumentIsANilAndATrailingOneIsDropped() {
        let c = PatternCase(
            key: "c1", label: "gap", args: [.int(1), .int(2), .int(3)], expected: .int(0),
            argsProvided: [true, false, false])
        let ctx = luaCallContext(for: family(paramNames: ["a", "b", "c"]), case: c)
        #expect(ctx.callArgsSuffix == ", a")
        #expect(ctx.declBlock == "local a = 1\n\n")

        let middle = PatternCase(
            key: "c2", label: "gap", args: [.int(1), .int(2), .int(3)], expected: .int(0),
            argsProvided: [true, false, true])
        let middleCtx = luaCallContext(for: family(paramNames: ["a", "b", "c"]), case: middle)
        #expect(middleCtx.callArgsSuffix == ", a, nil, c")
        #expect(!middleCtx.declBlock.contains("local b"))
    }

    @Test func anArgumentThatReferencesAVariableIsBoundFromThatVariable() {
        let c = PatternCase(
            key: "c1", label: "ref", args: [.string("$limit")], expected: .int(0),
            argVarRefs: ["limit"])
        let ctx = luaCallContext(for: family(paramNames: ["n"]), case: c)
        #expect(ctx.declBlock == "local n = limit\n\n")
        #expect(ctx.callArgsSuffix == ", n")
    }

    @Test func aCaseWithNoArgumentsSaysSoInItsInputLine() {
        let c = PatternCase(key: "c1", label: "none", args: [], expected: .int(0))
        let ctx = luaCallContext(for: family(), case: c)
        #expect(ctx.declBlock.isEmpty)
        #expect(ctx.callArgsSuffix.isEmpty)
        #expect(ctx.inputLine.contains("(no input)"))
    }

    // MARK: - Personalization preamble

    @Test func aPerStudentReferenceGetsAPreambleThatFailsClosed() throws {
        let c = PatternCase(
            key: "c1", label: "personal", args: [.string("$dose")], expected: .int(0),
            argVarRefs: ["dose"], expectedVarRef: "target_value")
        let script = renderLuaPatternCase(
            family: family(paramNames: ["d"], cases: [c]), case: c, sectionVariables: [],
            specHash: "h", perStudentNames: ["dose", "target_value", "unused"])
        #expect(script.contains("local ck_inputs_values = chickadee.inputs()"))
        #expect(script.contains("local dose = ck_inputs_values[\"dose\"]"))
        #expect(script.contains("local target_value = ck_inputs_values[\"target_value\"]"))
        #expect(script.contains("Personalization input 'dose' is unavailable"))
        // Only the names the case uses are bound.
        #expect(!script.contains("ck_inputs_values[\"unused\"]"))
        // The bindings come before the case body that reads them.
        let preamble = try #require(script.range(of: "local dose = ck_inputs_values"))
        let body = try #require(script.range(of: "chickadee.load_student()"))
        #expect(preamble.lowerBound < body.lowerBound)
    }

    @Test func aCaseWithNoPerStudentReferenceHasNoPreamble() {
        let c = PatternCase(key: "c1", label: "plain", args: [.int(1)], expected: .int(1))
        let script = renderLuaPatternCase(
            family: family(paramNames: ["n"], cases: [c]), case: c, sectionVariables: [],
            specHash: "h", perStudentNames: ["dose"])
        #expect(!script.contains("chickadee.inputs()"))
    }
}
