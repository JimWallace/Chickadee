// Tests/APITests/PatternFamilies/CppCallContextTests.swift
//
// The C++ call context builds the argument part of every generated C++ test.
// C++ passes arguments by position only, so the first omitted argument ends
// the list and the callee's default parameters take over. This suite pins that
// rule, an argument bound from a plain variable, the input line of a case with
// no arguments, and the file-scope variable declarations, where a family
// variable hides a section variable of the same name. The tests read the
// generated source. They do not run g++.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct CppCallContextTests {

    private func family(
        paramNames: [String], variables: [FamilyVariable] = []
    ) -> PatternFamily {
        PatternFamily(
            id: "fam", name: "Family", kind: .boundaryEquality, functionName: "target",
            paramNames: paramNames, variables: variables)
    }

    private func render(
        _ fam: PatternFamily, _ c: PatternCase, sectionVariables: [FamilyVariable] = [],
        perStudentNames: Set<String> = []
    ) -> String {
        renderCppPatternCase(
            family: fam, case: c, sectionVariables: sectionVariables, specHash: "hash",
            perStudentNames: perStudentNames)
    }

    @Test func allProvidedArgumentsAreDeclaredAndPassedInOrder() throws {
        let c = PatternCase(key: "c1", label: "all", args: [.int(1), .int(2)], expected: .int(0))
        let source = render(family(paramNames: ["a", "b"]), c)
        let first = try #require(source.range(of: "auto a = 1;"))
        let second = try #require(source.range(of: "auto b = 2;"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(source.contains("auto result = target(a, b);"))
    }

    /// An omission in the middle ends the list. The later argument is not
    /// declared and not passed, even though it is provided.
    @Test func theFirstOmittedArgumentEndsTheArgumentList() {
        let c = PatternCase(
            key: "c1", label: "gap", args: [.int(1), .int(2), .int(3)], expected: .int(0),
            argsProvided: [true, false, true])
        let source = render(family(paramNames: ["a", "b", "c"]), c)
        #expect(source.contains("auto a = 1;"))
        #expect(!source.contains("auto b ="))
        #expect(!source.contains("auto c ="))
        #expect(source.contains("auto result = target(a);"))
        #expect(source.contains("\"a=\" + ck::format(a)"))
        #expect(!source.contains("\"c=\""))
    }

    /// A reference to a name that is not per-student binds the argument from
    /// the file-scope variable, and does not read the per-student namespace.
    @Test func anArgumentThatReferencesAVariableIsBoundFromThatVariable() {
        let c = PatternCase(
            key: "c1", label: "ref", args: [.string("$limit")], expected: .int(0),
            argVarRefs: ["limit"])
        let fam = family(
            paramNames: ["n"], variables: [FamilyVariable(name: "limit", value: .int(5))])
        let source = render(fam, c)
        #expect(source.contains("auto n = limit;"))
        #expect(!source.contains("ck_inputs::"))
    }

    /// The same reference to a per-student name reads it from `ck_inputs`.
    @Test func aPerStudentReferenceReadsTheInputsNamespace() {
        let c = PatternCase(
            key: "c1", label: "ref", args: [.string("$limit")], expected: .int(0),
            argVarRefs: ["limit"])
        let source = render(family(paramNames: ["n"]), c, perStudentNames: ["limit"])
        #expect(source.contains("auto n = ck_inputs::limit;"))
    }

    @Test func aCaseWithNoArgumentsSaysSoInItsInputLine() {
        let c = PatternCase(key: "c1", label: "none", args: [], expected: .int(0))
        let source = render(family(paramNames: []), c)
        #expect(source.contains("(no input)"))
        #expect(source.contains("auto result = target();"))
    }

    /// C++ cannot define one name twice in a scope. The family value is
    /// declared, and the section variable with the same name is left out. A
    /// section variable with another name is still declared.
    @Test func aFamilyVariableHidesASectionVariableOfTheSameName() {
        let c = PatternCase(key: "c1", label: "vars", args: [.int(1)], expected: .int(0))
        let fam = family(
            paramNames: ["n"], variables: [FamilyVariable(name: "limit", value: .int(5))])
        let source = render(
            fam, c,
            sectionVariables: [
                FamilyVariable(name: "limit", value: .int(9)),
                FamilyVariable(name: "rows", value: .int(2)),
            ])
        #expect(source.contains("inline const auto limit = 5;"))
        #expect(!source.contains("inline const auto limit = 9;"))
        #expect(source.contains("inline const auto rows = 2;"))
        #expect(source.components(separatedBy: "inline const auto limit").count == 2)
    }
}
