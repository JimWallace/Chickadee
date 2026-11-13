// Tests/CoreTests/AssignmentTypeRuleTableTests.swift
//
// The five rules each `AssignmentType` carries (docs/assignment-types.md,
// "What the type controls"). They are Core properties, but their only
// assertions lived in APITests (`AssignmentTypeRulesTests`), which the
// mutation sweep skips. So the 2026-11-13 sweep (#3015) saw six mutants
// survive here: `self == .lab` flipped to `!=` and its ternary swapped in
// `defaultGradingMode`, and each `==` / `!=` flipped in `allowsBrowserGrading`,
// `requiresActivity`, `pushesGradesToLMS` and `allowsSlipDays`. A flip
// inverts the rule for every type: an Assignment would grade in the browser
// and ship its secret tests, or a Class activity would push points to the LMS.
// The table pins every rule for every type, where the sweep can see it.

import Core
import Testing

@Suite struct AssignmentTypeRuleTableTests {

    /// One row per type: the rules docs/assignment-types.md states.
    struct Rules: Sendable, CustomTestStringConvertible {
        let type: AssignmentType
        let defaultGradingMode: GradingMode
        let allowsBrowserGrading: Bool
        let requiresActivity: Bool
        let pushesGradesToLMS: Bool
        let allowsSlipDays: Bool

        var testDescription: String { type.rawValue }
    }

    static let table: [Rules] = [
        Rules(
            type: .assignment, defaultGradingMode: .worker, allowsBrowserGrading: false,
            requiresActivity: false, pushesGradesToLMS: true, allowsSlipDays: true),
        Rules(
            type: .lab, defaultGradingMode: .browser, allowsBrowserGrading: true,
            requiresActivity: false, pushesGradesToLMS: true, allowsSlipDays: true),
        Rules(
            type: .classActivity, defaultGradingMode: .worker, allowsBrowserGrading: true,
            requiresActivity: true, pushesGradesToLMS: false, allowsSlipDays: false),
    ]

    @Test func theTableCoversEveryType() {
        #expect(Self.table.map(\.type) == AssignmentType.allCases)
    }

    @Test(arguments: table)
    func eachTypeCarriesItsRules(_ rules: Rules) {
        let type = rules.type
        #expect(type.defaultGradingMode == rules.defaultGradingMode)
        #expect(type.allowsBrowserGrading == rules.allowsBrowserGrading)
        #expect(type.requiresActivity == rules.requiresActivity)
        #expect(type.pushesGradesToLMS == rules.pushesGradesToLMS)
        #expect(type.allowsSlipDays == rules.allowsSlipDays)
    }
}
