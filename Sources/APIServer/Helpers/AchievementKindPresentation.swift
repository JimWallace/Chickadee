// APIServer/Helpers/AchievementKindPresentation.swift
//
// Single source of truth for how the editor UI presents each authorable
// `AchievementKind`.  The assignment editor's kind dropdown renders from
// `AchievementKindPresentation.all`, and `achievements-editor.js` derives its
// table labels from those rendered options — so the Swift enum, the dropdown,
// and the JS labels can't drift.  The switch is exhaustive on purpose: adding
// a kind fails to compile until it gets a label here, instead of rendering
// blank in the editor.

import Core

/// One kind as the editor presents it.
struct AchievementKindOption: Encodable {
    /// Raw `AchievementKind` value, the row's `kind` field.
    let value: String
    /// Short label shown in the editor table's Kind column.
    let label: String
    /// One-line explanation; the dropdown shows "label — detail".
    let detail: String
}

enum AchievementKindPresentation {

    static var all: [AchievementKindOption] {
        AchievementKind.allCases.map(option(for:))
    }

    private static func option(for kind: AchievementKind) -> AchievementKindOption {
        switch kind {
        case .classGoal:
            return .init(
                value: kind.rawValue, label: "Class Goal", detail: "collaborative grade bonus")
        case .thresholdBadge:
            return .init(value: kind.rawValue, label: "Score Badge", detail: "grade threshold")
        case .testBadge:
            return .init(value: kind.rawValue, label: "Test Badge", detail: "a test passes")
        case .firstTryPerfect:
            return .init(value: kind.rawValue, label: "First-Try", detail: "perfect on attempt 1")
        case .comeback:
            return .init(value: kind.rawValue, label: "Comeback", detail: "big grade jump")
        case .persistence:
            return .init(
                value: kind.rawValue, label: "Persistence", detail: "perfect after many tries")
        case .speedRun:
            return .init(value: kind.rawValue, label: "Speed", detail: "fast perfect run")
        case .classRecord:
            return .init(value: kind.rawValue, label: "Class Record", detail: "one holder")
        }
    }
}
