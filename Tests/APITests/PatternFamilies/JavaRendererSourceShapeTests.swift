// Tests/APITests/PatternFamilies/JavaRendererSourceShapeTests.swift
//
// Source-level tests for the branches of the Java pattern-family renderer that
// the execution suite (`JavaRendererExecutionTests`) does not reach: the
// existence guard for an unqualified target, the family and section variables
// as static fields, per-student references, an omitted argument and
// `expectedVarRef`. These need no JDK, so they also run on a host without
// javac.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct JavaRendererSourceShapeTests {

    private static func family(
        function: String = "Solution.f", paramNames: [String] = ["x"],
        cases: [PatternCase], variables: [FamilyVariable] = []
    ) -> PatternFamily {
        PatternFamily(
            id: "fam", name: "Family", kind: .boundaryEquality,
            functionName: function, paramNames: paramNames,
            defaults: PatternDefaults(tier: .pub, points: 1),
            cases: cases, variables: variables)
    }

    private static func render(
        _ family: PatternFamily, sectionVariables: [FamilyVariable] = [], perStudent: Set<String> = []
    ) -> String {
        renderJavaPatternCase(
            family: family, case: family.cases[0], sectionVariables: sectionVariables,
            specHash: "h", perStudentNames: perStudent)
    }

    // MARK: - Existence guard

    @Test func guardForAnUnqualifiedTargetErrorsInsteadOfReflecting() {
        let family = Self.family(
            function: "f", cases: [PatternCase(key: "01", label: "", args: [.int(1)], expected: .int(2))])
        let script = renderJavaExistenceGuard(family: family, specHash: "h")

        #expect(script.contains("ck.errored(\"`f` is not a qualified Java Class.method name.\");"))
        #expect(!script.contains("getDeclaredMethods"), "an unqualified target has no class to reflect on")
        #expect(script.contains("public class CkTest_fam_exists"))
        // The ordinary compile step (exit 2), not the guard's compile-failure-is-a-fail step.
        #expect(script.contains("exit 2"))
        #expect(!script.contains("does not compile"))
    }

    @Test func guardForAQualifiedTargetReflectsOnTheClass() {
        let family = Self.family(
            function: "Solution.f", cases: [PatternCase(key: "01", label: "", args: [.int(1)], expected: .int(2))])
        let script = renderJavaExistenceGuard(family: family, specHash: "h")

        #expect(script.contains("Class<?> ckClass = Solution.class;"))
        #expect(script.contains("ckM.getName().equals(\"f\")"))
        #expect(!script.contains("is not a qualified Java Class.method name"))
    }

    // MARK: - Variables

    @Test func familyVariableShadowsTheSectionVariableOfTheSameName() {
        let family = Self.family(
            cases: [PatternCase(key: "01", label: "", args: [.int(1)], expected: .int(2))],
            variables: [FamilyVariable(name: "limit", value: .int(10))])
        let script = Self.render(
            family,
            sectionVariables: [
                FamilyVariable(name: "limit", value: .int(99)),
                FamilyVariable(name: "label", value: .string("Ann")),
            ])

        #expect(script.contains("static final int limit = 10;"))
        #expect(!script.contains("limit = 99"), "Java forbids a second declaration of one name")
        #expect(script.contains("static final String label = \"Ann\";"))
        #expect(script.components(separatedBy: "static final int limit").count == 2)
    }

    @Test func variableTypesFollowTheirLiterals() {
        let family = Self.family(
            cases: [PatternCase(key: "01", label: "", args: [.int(1)], expected: .int(2))],
            variables: [
                FamilyVariable(name: "rate", value: .double(0.5)),
                FamilyVariable(name: "flag", value: .bool(true)),
                FamilyVariable(name: "big", value: .int(Int(Int32.max) + 1)),
            ])
        let script = Self.render(family)

        #expect(script.contains("static final double rate = "))
        #expect(script.contains("static final boolean flag = true;"))
        #expect(script.contains("static final long big = \(Int(Int32.max) + 1)L;"))
    }

    // MARK: - Arguments

    @Test func perStudentArgumentReadsFromTheInputsClass() {
        let family = Self.family(
            cases: [
                PatternCase(key: "01", label: "", args: [.int(0)], expected: .int(2), argVarRefs: ["age"])
            ])

        let personal = Self.render(family, perStudent: ["age"])
        #expect(personal.contains("var x = _ck_inputs.age;"))

        // The same reference to an ordinary (static field) variable stays bare.
        let shared = Self.render(family)
        #expect(shared.contains("var x = age;"))
        #expect(!shared.contains("_ck_inputs.age"))
    }

    @Test func expectedVarRefReplacesTheLiteral() {
        let family = Self.family(
            cases: [
                PatternCase(key: "01", label: "", args: [.int(3)], expected: .int(0), expectedVarRef: "score")
            ])

        let personal = Self.render(family, perStudent: ["score"])
        #expect(personal.contains("var expected = _ck_inputs.score;"))

        let shared = Self.render(family)
        #expect(shared.contains("var expected = score;"))
    }

    @Test func anOmittedArgumentEndsTheCallList() {
        let family = Self.family(
            paramNames: ["x", "y"],
            cases: [
                PatternCase(
                    key: "01", label: "", args: [.int(1), .int(2)], expected: .int(3),
                    argsProvided: [false, true])
            ])
        let script = Self.render(family)

        // Java has no keyword arguments, so nothing after the gap is passed.
        #expect(script.contains("var result = Solution.f();"))
        #expect(!script.contains("var x ="))
        #expect(!script.contains("var y ="))
        #expect(script.contains("\"\(GeneratedMessage.input)(no input)\\n\""))
    }

    @Test func aNullArgumentBindsAsObject() {
        let family = Self.family(
            cases: [PatternCase(key: "01", label: "", args: [.null], expected: .int(0))])
        let script = Self.render(family)

        #expect(script.contains("Object x = null;"))
        #expect(!script.contains("var x = null;"))
    }

    @Test func anUnqualifiedTargetRendersAsAnUndefinedIdentifier() {
        #expect(javaTargetCall("Solution.f") == "Solution.f")
        #expect(javaTargetCall("f") == "CK_UNQUALIFIED_JAVA_TARGET_f")
        #expect(javaTargetCall("a.b.c") == "CK_UNQUALIFIED_JAVA_TARGET_a.b.c")
    }
}
