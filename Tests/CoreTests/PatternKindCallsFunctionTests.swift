// Tests/CoreTests/PatternKindCallsFunctionTests.swift
//
// `PatternKind.callsFunction` is the one answer to "does this kind call
// `functionName`?" (#2714). The validator, the renderer's existence guard and
// the notebook anchor all read it. It replaced a handler default of `true` and
// a `default:` arm, which gave a new kind that calls no function an identifier
// check and an anchor on a name it never reads.

import Testing

@testable import Core

@Suite struct PatternKindCallsFunctionTests {

    /// The expected answer for every kind, written out. A new kind that is not
    /// in this table fails `everyKindHasAnExplicitAnswer`.
    private static let expected: [PatternKind: Bool] = [
        .boundaryEquality: true,
        .approximateEquality: true,
        .variableEquality: false,
        .returnTypeCheck: true,
        .exceptionExpected: true,
        .performanceThreshold: true,
        .stdoutEquality: true,
        .unorderedEquality: true,
        .differential: true,
        .programIO: false,
    ]

    @Test func everyKindHasAnExplicitAnswer() {
        #expect(Set(Self.expected.keys) == Set(PatternKind.allCases))
    }

    @Test(arguments: PatternKind.allCases)
    func callsFunctionMatchesTheTable(kind: PatternKind) throws {
        let answer = try #require(Self.expected[kind] as Bool?, "\(kind) has no row in the table")
        #expect(kind.callsFunction == answer)
    }

    /// A family anchors on its function only when its kind calls one.
    /// `.variableEquality` anchors on its case's variable, so it is excluded.
    @Test(arguments: PatternKind.allCases.filter { $0 != .variableEquality })
    func familyTargetFollowsCallsFunction(kind: PatternKind) {
        let family = PatternFamily(id: "fam", name: "Family", kind: kind, functionName: "count_days")
        let target = NotebookTestAnchoring.familyTarget(family, script: "test_fam_a.py")
        #expect(target == (kind.callsFunction ? "count_days" : nil))
    }
}
