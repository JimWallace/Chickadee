// APIServer/Helpers/AchievementSignalPresentation.swift
//
// Single source of truth for how the achievements editor presents each
// condition `AchievementSignal`.  The editor's condition-builder renders its
// signal dropdown from `AchievementSignalPresentation.all`, and
// `achievements-editor.js` reads each rendered option's data attributes (its
// unit, and whether it targets a test) so the Swift enum, the dropdown, and the
// JS can't drift.  The switch is exhaustive on purpose: adding a signal fails to
// compile until it gets a presentation here, instead of rendering blank.

import Core

/// One condition signal as the editor presents it.
struct AchievementSignalOption: Encodable {
    /// Raw `AchievementSignal` value, the condition's `signal` field.
    let value: String
    /// Short label shown in the signal dropdown.
    let label: String
    /// One-line explanation; the dropdown shows "label — detail".
    let detail: String
    /// Unit suffix shown next to the value input ("%", "ms", "pts", or "").
    let unit: String
    /// True for a `testPass` signal — the editor swaps the comparator/value
    /// inputs for a single test-filename field.
    let isTest: Bool
}

enum AchievementSignalPresentation {

    static var all: [AchievementSignalOption] {
        AchievementSignal.allCases.map(option(for:))
    }

    private static func option(for signal: AchievementSignal) -> AchievementSignalOption {
        switch signal {
        case .grade:
            return .init(
                value: signal.rawValue, label: "Grade", detail: "assignment grade",
                unit: "%", isTest: false)
        case .attempts:
            return .init(
                value: signal.rawValue, label: "Attempts", detail: "attempt number",
                unit: "", isTest: false)
        case .executionTimeMs:
            return .init(
                value: signal.rawValue, label: "Run time", detail: "total execution time",
                unit: "ms", isTest: false)
        case .gradeJumpPercent:
            return .init(
                value: signal.rawValue, label: "Grade jump", detail: "gain vs the previous attempt",
                unit: "pts", isTest: false)
        case .testPass:
            return .init(
                value: signal.rawValue, label: "Test passes", detail: "a specific test passes",
                unit: "", isTest: true)
        }
    }
}
