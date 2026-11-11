// APIServer/Utilities/AssignmentTypeRules.swift
//
// The rules of each declared assignment type, in the words every surface
// shows: MCP `get_server_info`, the edit page's Type block and the new
// assignment page's hint (docs/assignment-types.md). Each sentence is built
// from the `AssignmentType` properties that the code enforces, so the prose
// cannot promise a rule the code does not keep.

import Core

enum AssignmentTypeRules {
    /// One sentence per rule of `type`, in a fixed order.
    static func rules(for type: AssignmentType) -> [String] {
        var rules: [String] = []
        rules.append(
            type.defaultGradingMode == .browser
                ? "Graded in the student browser by default."
                : "Graded by the native worker by default.")
        rules.append(
            type.allowsBrowserGrading
                ? "Browser grading is allowed, where the language and the activity allow it."
                : "Browser grading is refused, because it would deliver the release and secret tests to "
                    + "every student.")
        if type.requiresActivity {
            rules.append("Requires an activity block.")
        }
        rules.append(
            type.pushesGradesToLMS
                ? "Grades go to the LMS (BrightSpace or LTI)."
                : "Grades stay in Chickadee for the leaderboard and achievements, and are not sent to the "
                    + "LMS.")
        rules.append(
            type.allowsSlipDays
                ? "Students may spend slip days."
                : "Slip days do not apply.")
        return rules
    }

    /// One sentence a form note shows for `type` (the UI copy budget is one
    /// sentence; `rules(for:)` and docs/assignment-types.md hold the rest).
    static func summary(for type: AssignmentType) -> String {
        switch type {
        case .assignment: "Graded by the native worker, so its secret tests stay hidden."
        case .lab: "Graded in the student browser, for a participation grade."
        case .classActivity: "Live work whose points stay in Chickadee; add its activity on the edit page."
        }
    }

    /// The Type select's options, `selected` marked.
    static func options(selected: AssignmentType?) -> [SelectOption] {
        AssignmentType.allCases.map {
            SelectOption(value: $0.rawValue, label: $0.displayName, selected: $0 == selected)
        }
    }
}
